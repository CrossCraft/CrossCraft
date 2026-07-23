const std = @import("std");
const ae = @import("aether");
const Util = ae.Util;

const World = @import("game").World;
const Options = @import("../../Options.zig");
const Camera = @import("../../player/Camera.zig");
const TextureAtlas = @import("../../graphics/TextureAtlas.zig").TextureAtlas;

const Chunk = @import("Chunk.zig");
const ChunkStore = @import("ChunkStore.zig");
const Scheduler = @import("Scheduler.zig");
const mesher = @import("mesher.zig");
const ChunkCoord = @import("ChunkCoord.zig").ChunkCoord;

const SlotIndex = ChunkStore.SlotIndex;
const log = std.log.scoped(.chunk_compiler);
const MAX_INDEXED_QUADS: u32 =
    (@as(u32, std.math.maxInt(ae.Rendering.mesh.Index)) + 1) / 4;

/// One executor on every platform in this change. PSP has a compile-time
/// maximum of one executor and therefore exactly one compiler context; a
/// future desktop worker count allocates exactly one context per actual
/// worker.
pub const WORKER_COUNT: u32 = 1;
const WORKER_ID: Chunk.WorkerId = 0;

/// step() reports progress, never an error. Chunk allocation failures are
/// consumed internally by the OOM containment path.
pub const Status = enum {
    /// No queued work.
    idle,
    /// The claimed phase did not fit the frame budget estimate; the job was
    /// requeued unchanged. The driver should stop for this frame.
    deferred,
    /// A phase finished and the job advanced or restarted.
    phase_complete,
    /// A chunk published new GPU geometry.
    built,
    /// mesh_alloc exhausted memory or mesh handles; the job is blocked and
    /// one deterministic matching victim reclaim was attempted.
    oom_blocked,
};

/// Everything a phase needs beyond the compiler's own state. All of it is
/// render-thread owned; with WORKER_COUNT = 1, world mutation and
/// compilation stay serialized on the main/render thread.
pub const Drive = struct {
    store: *ChunkStore,
    scheduler: *Scheduler,
    allocator: std.mem.Allocator,
    atlas: *const TextureAtlas,
    io: std.Io,
};

const BlockedJob = struct {
    slot: SlotIndex,
    generation: u32,
    priority: Scheduler.Priority,
    frame: u64,
};

ctx: mesher.CompilerContext = undefined,
pack_est: Util.Estimator,
alloc_est: Util.Estimator,
emit_est: Util.Estimator,
/// Bumped by every real free (retirement with meshes, eviction, shrink).
/// A blocked job must not call the allocator again while its recorded
/// epoch equals this value.
reclaim_epoch: u32 = 0,
blocked: []BlockedJob,
blocked_count: u32 = 0,
frame_index: u64 = 0,
last_phase_ns: i64 = 0,
last_failure_log_frame: ?u64 = null,

const Self = @This();

pub fn init(allocator: std.mem.Allocator, capacity: u32) !Self {
    return .{
        .pack_est = Util.Estimator.init(),
        .alloc_est = Util.Estimator.init(),
        .emit_est = Util.Estimator.init(),
        .blocked = try allocator.alloc(BlockedJob, capacity),
    };
}

pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
    allocator.free(self.blocked);
}

pub fn begin_frame(self: *Self) void {
    self.frame_index += 1;
}

pub fn warming(self: *const Self) bool {
    return self.pack_est.is_warming_up() or
        self.alloc_est.is_warming_up() or
        self.emit_est.is_warming_up();
}

fn estimator_for(self: *Self, phase: Chunk.State) *Util.Estimator {
    return switch (phase) {
        .pack => &self.pack_est,
        .mesh_alloc => &self.alloc_est,
        .emit => &self.emit_est,
        else => unreachable,
    };
}

/// Retirement of a chunk that held meshes is a real free. Expire older
/// eviction suppressions immediately instead of waiting for residency sync.
pub fn note_external_free(self: *Self, d: *const Drive) void {
    d.scheduler.lock();
    defer d.scheduler.unlock();
    self.advance_reclaim_epoch_unlocked(d, null);
}

/// Claim at most one job and complete at most one phase. A phase is
/// indivisible: the scheduler may pause a job after pack, mesh_alloc, or
/// emit, never in the middle of one.
pub fn step(self: *Self, d: *const Drive, remaining_ns: i64) Status {
    self.unblock_eligible(d);

    // Claim loop: stale or already-built entries are discarded until a
    // runnable job is found.
    var job: Scheduler.Job = undefined;
    var phase: Chunk.State = undefined;
    var found = false;
    var claims_left: u32 = d.store.capacity() + 1;
    while (claims_left > 0) : (claims_left -= 1) {
        d.scheduler.lock();
        job = d.scheduler.claim_unlocked(d.store) orelse {
            d.scheduler.unlock();
            break;
        };
        const chunk = d.store.chunk(job.slot);
        switch (chunk.state) {
            .unbuilt, .dirty => {
                // Claiming records settings and revision, assigns the sole
                // current owner, and changes state to pack.
                chunk.build_revision = chunk.source_revision;
                chunk.build_near_lod = chunk.near_lod;
                chunk.build_ao = chunk.ao_enabled;
                chunk.owner = WORKER_ID;
                chunk.state = .pack;
                phase = .pack;
                found = true;
            },
            .mesh_alloc, .emit => {
                chunk.owner = WORKER_ID;
                phase = chunk.state;
                found = true;
            },
            else => {
                // built, or a pack state that cannot be queued: skip.
            },
        }
        d.scheduler.unlock();
        if (found) break;
    }
    if (!found) return .idle;

    // Budget gate: start a phase only when its estimate fits, except during
    // the bounded estimator warmup. A deferred job is requeued unchanged.
    const est = self.estimator_for(phase);
    if (!est.is_warming_up() and est.estimate_cost(.p75) > remaining_ns) {
        d.scheduler.lock();
        const chunk = d.store.chunk(job.slot);
        chunk.owner = null;
        if (chunk.revision_stale() or chunk.restart_requested) {
            chunk.discard_pending();
            chunk.state = if (chunk.geometry_valid) .dirty else .unbuilt;
        } else if (phase == .pack) {
            chunk.state = if (chunk.geometry_valid) .dirty else .unbuilt;
        }
        d.scheduler.requeue_unlocked(d.store, job);
        d.scheduler.unlock();
        return .deferred;
    }

    // Heavy work runs without the lifecycle mutex.
    const clock_before: i64 = @intCast(std.Io.Clock.boot.now(d.io).toNanoseconds());
    est.begin(d.io);
    const status = switch (phase) {
        .pack => self.run_pack(d, job),
        .mesh_alloc => self.run_mesh_alloc(d, job),
        .emit => self.run_emit(d, job),
        else => unreachable,
    };
    est.end(d.io);
    self.last_phase_ns = @as(i64, @intCast(std.Io.Clock.boot.now(d.io).toNanoseconds())) - clock_before;
    return status;
}

/// Phase boundary helper: on any revision mismatch or explicit restart
/// request, discard uncommitted output, rest at dirty (old committed
/// geometry still drawable) or unbuilt, release ownership, and enqueue one
/// restart. Caller holds the mutex. Returns true when a restart happened.
fn boundary_restart_if_stale(self: *Self, d: *const Drive, job: Scheduler.Job) bool {
    _ = self;
    const chunk = d.store.chunk(job.slot);
    if (!chunk.revision_stale() and !chunk.restart_requested) return false;
    chunk.discard_pending();
    chunk.state = if (chunk.geometry_valid) .dirty else .unbuilt;
    chunk.owner = null;
    d.scheduler.requeue_unlocked(d.store, job);
    return true;
}

fn run_pack(self: *Self, d: *const Drive, job: Scheduler.Job) Status {
    const counts = blk: {
        const chunk = d.store.chunk(job.slot);
        const coord = chunk.coord;
        // All-air chunks have no visible faces: skip classification.
        if (World.data.is_chunk_all_air(coord.x, coord.y, coord.z)) {
            break :blk mesher.SectionCounts{ .opaque_verts = 0, .transparent_verts = 0, .fluid_verts = 0 };
        }
        break :blk mesher.stream_pack(&self.ctx.stream, coord.x, coord.y, coord.z, chunk.build_near_lod);
    };

    d.scheduler.lock();
    defer d.scheduler.unlock();
    if (self.boundary_restart_if_stale(d, job)) return .phase_complete;
    const chunk = d.store.chunk(job.slot);
    chunk.counts = counts;
    chunk.state = .mesh_alloc;
    chunk.owner = null;
    d.scheduler.requeue_unlocked(d.store, job);
    return .phase_complete;
}

/// Absolute-capacity fit check: emit clears the lists before filling, so
/// what matters is whether the retained capacity covers the counts.
fn data_fits(data: *const Chunk.BatchMeshData, quads: u32) bool {
    const cap: u32 = @intCast(data.vertices.capacity);
    if (ae.Rendering.mesh.indexing_enabled) {
        const icap: u32 = @intCast(data.indices.capacity);
        return quads * 4 <= cap and quads * 6 <= icap;
    }
    return quads * 6 <= cap;
}

/// mesh_alloc outcome: success, a concrete resource failure (one matching
/// victim reclaim may be attempted), or an epoch-prohibited retry.
const AllocOutcome = enum {
    ok,
    index_overflow,
    out_of_memory,
    out_of_meshes,
    epoch_blocked,
};

const ReclaimKind = enum {
    memory,
    mesh_handles,
};

fn run_mesh_alloc(self: *Self, d: *const Drive, job: Scheduler.Job) Status {
    const outcome = self.mesh_alloc_work(d, job.slot);

    d.scheduler.lock();
    defer d.scheduler.unlock();
    if (self.boundary_restart_if_stale(d, job)) return .phase_complete;
    const chunk = d.store.chunk(job.slot);

    switch (outcome) {
        .ok => {
            chunk.state = .emit;
            chunk.owner = null;
            d.scheduler.requeue_unlocked(d.store, job);
            return .phase_complete;
        },
        .index_overflow => {
            // The source is legal but cannot fit one indexed batch. Reject
            // this revision without touching retained buffers, evicting
            // another chunk, or repeatedly retrying the same counts.
            chunk.invalidate_geometry();
            chunk.discard_pending();
            chunk.state = .rejected;
            chunk.owner = null;
            self.log_index_overflow(chunk);
            return .phase_complete;
        },
        .out_of_memory, .out_of_meshes, .epoch_blocked => {
            // Resource containment: record the settled epoch and requested
            // capacities, release ownership, and park in the blocked set.
            chunk.blocked_epoch = self.reclaim_epoch;
            chunk.prohibited_epoch = self.reclaim_epoch;
            chunk.owner = null;
            self.add_blocked(job);
            var victim_coord: ?ChunkCoord = null;
            if (outcome != .epoch_blocked) {
                // One deterministic reclaim per concrete failure, never
                // repeated within a step. Allocator OOM releases CPU storage;
                // handle exhaustion must destroy GPU handles.
                const kind: ReclaimKind = if (outcome == .out_of_meshes)
                    .mesh_handles
                else
                    .memory;
                if (self.pick_victim(d, job.slot, kind)) |victim| {
                    victim_coord = d.store.chunk(victim).coord;
                    self.evict(d, victim, kind);
                    self.advance_reclaim_epoch_unlocked(d, victim);
                }
            }
            self.log_resource_failure(d, chunk, outcome, victim_coord);
            return .oom_blocked;
        },
    }
}

/// mesh_alloc heavy work: lazy mesh-handle creation and exact CPU
/// capacities. Runs without the mutex. Nothing is retried here.
fn mesh_alloc_work(self: *Self, d: *const Drive, slot: SlotIndex) AllocOutcome {
    const chunk = d.store.chunk(slot);
    const counts = chunk.counts;
    const req = [3]u32{
        counts.opaque_verts / 6,
        counts.transparent_verts / 6,
        counts.fluid_verts / 6,
    };
    chunk.req_opaque_quads = req[0];
    chunk.req_trans_quads = req[1];
    chunk.req_fluid_quads = req[2];

    if (ae.Rendering.mesh.indexing_enabled) {
        inline for (req) |quads| {
            if (quads > MAX_INDEXED_QUADS) return .index_overflow;
        }
    }

    // A job whose prohibition epoch has not changed must not call the
    // allocator again; pack for a new revision may still succeed below
    // when the new counts fit existing capacity.
    const alloc_allowed = chunk.prohibited_epoch == null or chunk.prohibited_epoch.? != self.reclaim_epoch;

    if (chunk.meshes == null and req[0] + req[1] + req[2] == 0) return .ok;
    if (chunk.meshes == null) {
        if (!alloc_allowed) return .epoch_blocked;
        chunk.create_meshes(d.allocator) catch |err| return switch (err) {
            error.OutOfMemory => .out_of_memory,
            error.OutOfMeshes => .out_of_meshes,
        };
    }
    const set = &chunk.meshes.?;
    const datas = [3]*Chunk.BatchMeshData{ &set.opaque_data, &set.trans_data, &set.fluid_data };

    var needs_growth = false;
    inline for (0..3) |i| {
        if (!data_fits(datas[i], req[i])) needs_growth = true;
    }
    if (!needs_growth) return .ok;
    if (!alloc_allowed) return .epoch_blocked;

    // Borrowed-source mesh handles may still point into these lists. Stop
    // drawing before clear/reallocation can change or release that storage.
    d.scheduler.lock();
    chunk.invalidate_geometry();
    d.scheduler.unlock();

    // Capacity checks are done and the published geometry is no longer
    // drawable; only now may CPU list lengths be cleared or reallocated.
    inline for (0..3) |i| datas[i].clear_retaining_capacity();
    inline for (0..3) |i| {
        if (!data_fits(datas[i], req[i])) {
            datas[i].ensure_quad_capacity(d.allocator, req[i]) catch |err| switch (err) {
                error.IndexOverflow => return .index_overflow,
                error.OutOfMemory => return .out_of_memory,
            };
        }
    }
    return .ok;
}

fn run_emit(self: *Self, d: *const Drive, job: Scheduler.Job) Status {
    if (!self.prepare_emit(d, job)) return .phase_complete;

    blk: {
        const chunk = d.store.chunk(job.slot);
        const counts = chunk.counts;
        if (counts.opaque_verts + counts.transparent_verts + counts.fluid_verts == 0) break :blk;
        const set = &chunk.meshes.?;
        set.opaque_data.clear_retaining_capacity();
        set.trans_data.clear_retaining_capacity();
        set.fluid_data.clear_retaining_capacity();
        const coord = chunk.coord;
        mesher.stream_emit(&self.ctx.stream, coord.x, coord.y, coord.z, chunk.build_near_lod, .{
            .@"opaque" = &set.opaque_data,
            .transparent = &set.trans_data,
            .fluid = &set.fluid_data,
        }, d.atlas, chunk.build_ao);
    }

    // Publication: recheck the revision, then publish all mesh handles
    // together. An invalidator happens wholly before or after this block
    // and cannot lose a dirty event.
    d.scheduler.lock();
    defer d.scheduler.unlock();
    if (self.boundary_restart_if_stale(d, job)) return .phase_complete;
    const chunk = d.store.chunk(job.slot);
    if (chunk.meshes) |*set| {
        inline for (.{
            .{ &set.opaque_data, &set.@"opaque" },
            .{ &set.trans_data, &set.trans },
            .{ &set.fluid_data, &set.fluid },
        }) |pair| {
            if (pair[0].vertices.items.len > 0) pair[1].update(pair[0]);
        }
    }
    chunk.committed = chunk.counts;
    chunk.built_revision = chunk.build_revision;
    chunk.geometry_valid = true;
    chunk.state = .built;
    chunk.owner = null;
    // First build kicks the bouncy-rise animation when enabled.
    if (chunk.first_build) {
        chunk.first_build = false;
        if (Options.current.bouncy_chunks) chunk.anim_progress = 0.0;
    }
    return .built;
}

fn prepare_emit(self: *Self, d: *const Drive, job: Scheduler.Job) bool {
    // Revoke borrowed buffers under the lifecycle lock before emit can
    // overwrite them. An invalidator after this point sees non-drawable
    // geometry; one before it can restart without losing the old mesh.
    d.scheduler.lock();
    defer d.scheduler.unlock();
    if (self.boundary_restart_if_stale(d, job)) {
        return false;
    }
    const pending = d.store.chunk(job.slot).counts;
    if (pending.opaque_verts + pending.transparent_verts + pending.fluid_verts != 0) {
        d.store.chunk(job.slot).invalidate_geometry();
    }
    return true;
}

// --- OOM blocked set and reclamation ---

/// Caller must hold the mutex.
fn add_blocked(self: *Self, job: Scheduler.Job) void {
    std.debug.assert(self.blocked_count < self.blocked.len);
    self.blocked[self.blocked_count] = .{
        .slot = job.slot,
        .generation = job.generation,
        .priority = job.priority,
        .frame = self.frame_index,
    };
    self.blocked_count += 1;
}

/// Remove a slot from the blocked set and clear its matching lifecycle
/// metadata. No-op when membership is absent. Caller holds the scheduler
/// mutex and the slot is active.
pub fn remove_blocked(self: *Self, store: *ChunkStore, slot: SlotIndex) void {
    store.chunk(slot).blocked_epoch = null;
    var i: u32 = 0;
    while (i < self.blocked_count) : (i += 1) {
        if (self.blocked[i].slot == slot) {
            self.blocked_count -= 1;
            self.blocked[i] = self.blocked[self.blocked_count];
            return;
        }
    }
}

/// Requeue blocked jobs whose recorded epoch no longer matches the global
/// epoch. Camera movement, priority changes, dirty marks, and frame passage
/// do not qualify; only a real free observed as an epoch change does.
fn unblock_eligible(self: *Self, d: *const Drive) void {
    if (self.blocked_count == 0) return;
    d.scheduler.lock();
    defer d.scheduler.unlock();
    var i: u32 = 0;
    while (i < self.blocked_count) {
        const b = self.blocked[i];
        if (d.store.validate(b.slot, b.generation)) {
            const chunk = d.store.chunk(b.slot);
            if (chunk.blocked_epoch != null and chunk.blocked_epoch.? == self.reclaim_epoch) {
                i += 1;
                continue;
            }
            chunk.blocked_epoch = null;
            d.scheduler.requeue_unlocked(d.store, .{
                .slot = b.slot,
                .generation = b.generation,
                .priority = b.priority,
            });
        }
        self.blocked_count -= 1;
        self.blocked[i] = self.blocked[self.blocked_count];
    }
}

/// Advance the global free epoch and make every older eviction victim
/// runnable again. The newly reclaimed victim, when present, is tagged with
/// the new epoch and remains suppressed. Caller holds the scheduler mutex.
fn advance_reclaim_epoch_unlocked(
    self: *Self,
    d: *const Drive,
    new_victim: ?SlotIndex,
) void {
    self.reclaim_epoch +%= 1;
    if (new_victim) |slot| {
        d.store.chunk(slot).suppressed_epoch = self.reclaim_epoch;
    }

    for (d.store.slots, 0..) |*slot, i| {
        if (!slot.active) continue;
        const chunk = &slot.chunk;
        const epoch = chunk.suppressed_epoch orelse continue;
        if (epoch == self.reclaim_epoch) continue;
        chunk.suppressed_epoch = null;
        if (chunk.state != .unbuilt) continue;
        if (chunk.queue_index != null or chunk.owner != null) continue;
        if (chunk.blocked_epoch != null) continue;
        d.scheduler.append_unlocked(
            d.store,
            @intCast(i),
            d.scheduler.classify_snapshot(chunk),
        );
    }
}

/// One deterministic reclaim victim: a non-owned chunk holding mesh
/// storage, preferring invalid or off-frustum geometry, then farthest from
/// the camera snapshot. Never the requester itself: freeing the requester's
/// last valid geometry to manufacture its own retry epoch is prohibited.
/// Caller must hold the mutex.
fn pick_victim(self: *Self, d: *const Drive, requester: SlotIndex, kind: ReclaimKind) ?SlotIndex {
    _ = self;
    var best: ?SlotIndex = null;
    var best_tier: u8 = 2;
    var best_dist: f32 = -1.0;
    for (d.store.slots, 0..) |*slot, i| {
        if (!slot.active or i == requester) continue;
        const chunk = &slot.chunk;
        if (chunk.owner != null or chunk.meshes == null) continue;
        // Memory reclaim needs retained storage. Handle reclaim may select a
        // metadata-only mesh set because its three handles are the resource.
        if (kind == .memory) {
            const retained = chunk.retained_quads();
            if (!chunk.geometry_valid and retained[0] + retained[1] + retained[2] == 0) continue;
        }
        const visible = d.scheduler.visible_snapshot(chunk.coord);
        const tier: u8 = if (!chunk.geometry_valid or !visible) 0 else 1;
        const dist = d.scheduler.dist_sq_snapshot(chunk.coord);
        if (tier < best_tier or (tier == best_tier and dist > best_dist)) {
            best = @intCast(i);
            best_tier = tier;
            best_dist = dist;
        }
    }
    return best;
}

/// Evict one victim: cancel queue membership, leave the blocked set, and
/// release its committed geometry. The victim becomes unbuilt.
/// Caller must hold the mutex.
fn evict(self: *Self, d: *const Drive, slot: SlotIndex, kind: ReclaimKind) void {
    d.scheduler.cancel_unlocked(d.store, slot);
    self.remove_blocked(d.store, slot);
    const chunk = d.store.chunk(slot);
    switch (kind) {
        .memory => chunk.release_geometry(d.allocator),
        .mesh_handles => chunk.release_meshes(d.allocator),
    }
}

/// Rate-limited structured resource diagnostics. Exhaustion is serious and
/// observable even though it never bubbles out of the scheduler.
fn log_resource_failure(
    self: *Self,
    d: *const Drive,
    chunk: *const Chunk,
    outcome: AllocOutcome,
    victim: ?ChunkCoord,
) void {
    if (!self.failure_log_ready()) return;

    const retained = chunk.retained_quads();
    var frames_blocked: u64 = 0;
    for (self.blocked[0..self.blocked_count]) |b| {
        if (d.store.chunk(b.slot).coord.eql(chunk.coord)) {
            frames_blocked = self.frame_index - b.frame;
            break;
        }
    }
    const vx: u32 = if (victim) |v| v.x else 0;
    const vy: u32 = if (victim) |v| v.y else 0;
    const vz: u32 = if (victim) |v| v.z else 0;
    log.warn(
        "mesh_alloc {s} at ({d},{d},{d}): req quads o={d} t={d} f={d}, retained o={d} t={d} f={d}, epoch {d}, victim {}({d},{d},{d}), blocked {d}, frames_blocked {d}",
        .{
            @tagName(outcome),
            chunk.coord.x,
            chunk.coord.y,
            chunk.coord.z,
            chunk.req_opaque_quads,
            chunk.req_trans_quads,
            chunk.req_fluid_quads,
            retained[0],
            retained[1],
            retained[2],
            self.reclaim_epoch,
            victim != null,
            vx,
            vy,
            vz,
            self.blocked_count,
            frames_blocked,
        },
    );
}

fn log_index_overflow(self: *Self, chunk: *const Chunk) void {
    if (!self.failure_log_ready()) return;
    log.warn(
        "mesh_alloc index_overflow at ({d},{d},{d}): req quads o={d} t={d} f={d}, indexed max={d}; revision rejected",
        .{
            chunk.coord.x,
            chunk.coord.y,
            chunk.coord.z,
            chunk.req_opaque_quads,
            chunk.req_trans_quads,
            chunk.req_fluid_quads,
            MAX_INDEXED_QUADS,
        },
    );
}

fn failure_log_ready(self: *Self) bool {
    if (self.last_failure_log_frame) |last| {
        if (self.frame_index - last < 30) return false;
    }
    self.last_failure_log_frame = self.frame_index;
    return true;
}

// --- Tests ---
//
// All tests are headless, so GPU handle creation and upload are no-ops.
// Revision and phase-flow tests use all-air chunks (zero counts skip mesh
// creation); OOM tests use a failing allocator so the flow never reaches
// emit/publication of real geometry.

const TestRig = struct {
    store: ChunkStore,
    scheduler: Scheduler,
    compiler: Self,
    camera: Camera,
    atlas: TextureAtlas,

    fn init(alloc: std.mem.Allocator, capacity: u32) !TestRig {
        var rig: TestRig = .{
            .store = try ChunkStore.init(alloc, capacity),
            .scheduler = try Scheduler.init(alloc, capacity),
            .compiler = try Self.init(alloc, capacity),
            .camera = Camera.init(8, 8, 8),
            .atlas = .init(256, 256, 16, 16),
        };
        rig.camera.frustum = ae.Math.Frustum.fromViewProjection(ae.Math.Mat4.identity());
        rig.scheduler.set_camera(&rig.store, &rig.camera);
        return rig;
    }

    /// Free CPU mesh storage of every chunk without touching GPU handles,
    /// then tear down. Tests never create real GPU handles.
    fn deinit(rig: *TestRig, alloc: std.mem.Allocator) void {
        for (rig.store.slots) |*slot| {
            if (!slot.active) continue;
            if (slot.chunk.meshes) |*set| {
                set.opaque_data.deinit(alloc);
                set.trans_data.deinit(alloc);
                set.fluid_data.deinit(alloc);
                slot.chunk.meshes = null;
            }
        }
        rig.compiler.deinit(alloc);
        rig.scheduler.deinit(alloc);
        rig.store.deinit();
    }

    fn drive(rig: *TestRig, alloc: std.mem.Allocator) Drive {
        return .{
            .store = &rig.store,
            .scheduler = &rig.scheduler,
            .allocator = alloc,
            .atlas = &rig.atlas,
            .io = std.testing.io,
        };
    }

    fn enqueue(rig: *TestRig, coord: @import("ChunkCoord.zig").ChunkCoord) SlotIndex {
        return rig.enqueue_class(coord, null);
    }

    fn enqueue_class(
        rig: *TestRig,
        coord: @import("ChunkCoord.zig").ChunkCoord,
        class_override: ?Scheduler.PriorityClass,
    ) SlotIndex {
        const slot = rig.store.ensure(coord).?;
        rig.scheduler.lock();
        const class = class_override orelse
            rig.scheduler.classify_snapshot(rig.store.chunk(slot));
        rig.scheduler.append_unlocked(&rig.store, slot, class);
        rig.scheduler.unlock();
        return slot;
    }

    /// Mirror of the renderer's invalidation routing.
    fn invalidate(rig: *TestRig, slot: SlotIndex) void {
        rig.scheduler.lock();
        defer rig.scheduler.unlock();
        const action = rig.store.chunk(slot).invalidate();
        const chunk = rig.store.chunk(slot);
        const class = rig.scheduler.classify_snapshot(chunk);
        if (action == .unblock_enqueue) rig.compiler.remove_blocked(&rig.store, slot);
        rig.scheduler.append_unlocked(&rig.store, slot, class);
    }
};

fn setup_test_world() !void {
    @import("common").BlockRegistry.init();
    try World.data.init_in_place(std.testing.allocator, 0);
    // Blocks start all-air with zeroed counters; settle them before any
    // apply_block transition.
    settle_test_world();
}

fn settle_test_world() void {
    World.data.compute_chunk_counts();
    World.data.compute_light_map();
}

fn test_all_air_world() !void {
    try setup_test_world();
    for (0..16) |x| {
        for (0..64) |y| {
            for (0..16) |z| {
                World.data.apply_block(@intCast(x), @intCast(y), @intCast(z), .{ .id = .air });
            }
        }
    }
    settle_test_world();
}

test "all-air chunk flows through every phase to built" {
    try test_all_air_world();
    defer World.data.deinit();

    var rig = try TestRig.init(std.testing.allocator, 4);
    defer rig.deinit(std.testing.allocator);
    const alloc = std.testing.allocator;

    const slot = rig.enqueue(.init(2, 1, 2));
    const chunk = rig.store.chunk(slot);

    try std.testing.expectEqual(Status.phase_complete, rig.compiler.step(&rig.drive(alloc), 1_000_000));
    try std.testing.expectEqual(Chunk.State.mesh_alloc, chunk.state);
    try std.testing.expectEqual(@as(?Chunk.WorkerId, null), chunk.owner);

    try std.testing.expectEqual(Status.phase_complete, rig.compiler.step(&rig.drive(alloc), 1_000_000));
    try std.testing.expectEqual(Chunk.State.emit, chunk.state);
    // All-air: no meshes were ever created.
    try std.testing.expectEqual(@as(?Chunk.MeshSet, null), chunk.meshes);

    try std.testing.expectEqual(Status.built, rig.compiler.step(&rig.drive(alloc), 1_000_000));
    try std.testing.expectEqual(Chunk.State.built, chunk.state);
    try std.testing.expect(chunk.geometry_valid);
    try std.testing.expectEqual(chunk.source_revision, chunk.built_revision);
    try std.testing.expect(!chunk.first_build);

    try std.testing.expectEqual(Status.idle, rig.compiler.step(&rig.drive(alloc), 1_000_000));
}

test "interactive priority survives every compile phase" {
    try test_all_air_world();
    defer World.data.deinit();

    var rig = try TestRig.init(std.testing.allocator, 4);
    defer rig.deinit(std.testing.allocator);
    const alloc = std.testing.allocator;

    const far = rig.enqueue_class(.init(10, 1, 10), .interactive);
    const near = rig.enqueue_class(.init(0, 1, 0), .interactive);

    try std.testing.expectEqual(Status.phase_complete, rig.compiler.step(&rig.drive(alloc), 1_000_000));
    try std.testing.expectEqual(Chunk.State.mesh_alloc, rig.store.chunk(far).state);
    try std.testing.expectEqual(Chunk.State.unbuilt, rig.store.chunk(near).state);
    try std.testing.expectEqual(Status.phase_complete, rig.compiler.step(&rig.drive(alloc), 1_000_000));
    try std.testing.expectEqual(Chunk.State.emit, rig.store.chunk(far).state);
    try std.testing.expectEqual(Chunk.State.unbuilt, rig.store.chunk(near).state);
    try std.testing.expectEqual(Status.built, rig.compiler.step(&rig.drive(alloc), 1_000_000));
    try std.testing.expectEqual(Chunk.State.built, rig.store.chunk(far).state);
    try std.testing.expectEqual(Chunk.State.unbuilt, rig.store.chunk(near).state);
}

test "deferred interactive phase retains its original sequence" {
    var rig = try TestRig.init(std.testing.allocator, 4);
    defer rig.deinit(std.testing.allocator);
    const alloc = std.testing.allocator;

    const first = rig.enqueue_class(.init(10, 1, 10), .interactive);
    _ = rig.enqueue_class(.init(0, 1, 0), .interactive);
    for (0..64) |_| rig.compiler.pack_est.record(100);

    try std.testing.expectEqual(Status.deferred, rig.compiler.step(&rig.drive(alloc), 0));
    try std.testing.expectEqual(first, rig.scheduler.claim(&rig.store).?.slot);
}

test "blocked interactive phase resumes with its original sequence" {
    var rig = try TestRig.init(std.testing.allocator, 4);
    defer rig.deinit(std.testing.allocator);
    const alloc = std.testing.allocator;

    const first = rig.enqueue_class(.init(10, 1, 10), .interactive);
    const second = rig.enqueue_class(.init(0, 1, 0), .interactive);
    const job = rig.scheduler.claim(&rig.store).?;
    try std.testing.expectEqual(first, job.slot);

    rig.scheduler.lock();
    const chunk = rig.store.chunk(first);
    chunk.state = .mesh_alloc;
    chunk.blocked_epoch = rig.compiler.reclaim_epoch;
    rig.compiler.add_blocked(job);
    rig.scheduler.unlock();
    var drive = rig.drive(alloc);
    rig.compiler.note_external_free(&drive);

    try std.testing.expectEqual(Status.phase_complete, rig.compiler.step(&rig.drive(alloc), 1_000_000));
    try std.testing.expectEqual(Chunk.State.emit, rig.store.chunk(first).state);
    try std.testing.expectEqual(Chunk.State.unbuilt, rig.store.chunk(second).state);
}

test "invalidation between phases restarts and never publishes stale work" {
    try test_all_air_world();
    defer World.data.deinit();

    var rig = try TestRig.init(std.testing.allocator, 4);
    defer rig.deinit(std.testing.allocator);
    const alloc = std.testing.allocator;

    const slot = rig.enqueue(.init(2, 1, 2));
    const chunk = rig.store.chunk(slot);

    // Complete pack, then invalidate while the job is paused in the queue.
    _ = rig.compiler.step(&rig.drive(alloc), 1_000_000);
    try std.testing.expectEqual(Chunk.State.mesh_alloc, chunk.state);
    rig.invalidate(slot);
    try std.testing.expectEqual(Chunk.State.unbuilt, chunk.state);

    // Run to completion; then invalidate between mesh_alloc and emit.
    _ = rig.compiler.step(&rig.drive(alloc), 1_000_000); // pack again
    _ = rig.compiler.step(&rig.drive(alloc), 1_000_000); // mesh_alloc
    try std.testing.expectEqual(Chunk.State.emit, chunk.state);
    rig.invalidate(slot);
    // No committed geometry yet: the restart rests at unbuilt.
    try std.testing.expectEqual(Chunk.State.unbuilt, chunk.state);

    var status = Status.idle;
    var guard: u32 = 16;
    while (guard > 0) : (guard -= 1) {
        status = rig.compiler.step(&rig.drive(alloc), 1_000_000);
        if (status == .idle) break;
    }
    try std.testing.expectEqual(Chunk.State.built, chunk.state);
    // The publication is for the latest revision: no stale output survived.
    try std.testing.expectEqual(chunk.source_revision, chunk.built_revision);
    try std.testing.expectEqual(chunk.source_revision, chunk.build_revision);
}

test "built chunk invalidated before publication boundary stays drawable" {
    try test_all_air_world();
    defer World.data.deinit();

    var rig = try TestRig.init(std.testing.allocator, 4);
    defer rig.deinit(std.testing.allocator);
    const alloc = std.testing.allocator;

    const slot = rig.enqueue(.init(2, 1, 2));
    const chunk = rig.store.chunk(slot);
    var guard: u32 = 8;
    while (guard > 0) : (guard -= 1) {
        if (rig.compiler.step(&rig.drive(alloc), 1_000_000) == .idle) break;
    }
    try std.testing.expectEqual(Chunk.State.built, chunk.state);

    // dirty: valid committed geometry exists but is stale; the chunk keeps
    // drawing (geometry_valid) through the recompile.
    rig.invalidate(slot);
    try std.testing.expectEqual(Chunk.State.dirty, chunk.state);
    try std.testing.expect(chunk.geometry_valid);

    _ = rig.compiler.step(&rig.drive(alloc), 1_000_000); // pack
    try std.testing.expectEqual(Chunk.State.mesh_alloc, chunk.state);
    try std.testing.expect(chunk.geometry_valid);
    _ = rig.compiler.step(&rig.drive(alloc), 1_000_000); // mesh_alloc
    _ = rig.compiler.step(&rig.drive(alloc), 1_000_000); // emit + publish
    try std.testing.expectEqual(Chunk.State.built, chunk.state);
    try std.testing.expectEqual(chunk.source_revision, chunk.built_revision);
}

test "indexed glass-water checkerboard is rejected without OOM churn" {
    if (!ae.Rendering.mesh.indexing_enabled) return;

    try setup_test_world();
    defer World.data.deinit();

    const coord = ChunkCoord.init(5, 1, 5);
    for (0..16) |lx| {
        for (0..16) |ly| {
            for (0..16) |lz| {
                const id: @import("common").consts.Block.Type =
                    if ((lx + ly + lz) % 2 == 0) .glass else .still_water;
                World.data.apply_block(
                    @intCast(@as(u32, coord.x) * 16 + lx),
                    @intCast(@as(u32, coord.y) * 16 + ly),
                    @intCast(@as(u32, coord.z) * 16 + lz),
                    .{ .id = id },
                );
            }
        }
    }
    settle_test_world();

    var rig = try TestRig.init(std.testing.allocator, 4);
    defer rig.deinit(std.testing.allocator);
    const alloc = std.testing.allocator;

    const slot = rig.enqueue(coord);
    const chunk = rig.store.chunk(slot);
    chunk.meshes = try Chunk.MeshSet.create_cpu(alloc);
    const retained_before = chunk.retained_quads();
    chunk.geometry_valid = true;
    chunk.committed = .{ .opaque_verts = 24, .transparent_verts = 0, .fluid_verts = 0 };

    try std.testing.expectEqual(Status.phase_complete, rig.compiler.step(&rig.drive(alloc), 1_000_000));
    try std.testing.expectEqual(@as(u32, 25_856), chunk.counts.fluid_verts / 6);
    try std.testing.expectEqual(Status.phase_complete, rig.compiler.step(&rig.drive(alloc), 1_000_000));

    try std.testing.expectEqual(Chunk.State.rejected, chunk.state);
    try std.testing.expect(!chunk.geometry_valid);
    try std.testing.expectEqual(@as(u32, 25_856), chunk.req_fluid_quads);
    try std.testing.expectEqual(retained_before, chunk.retained_quads());
    try std.testing.expectEqual(@as(u32, 0), rig.compiler.blocked_count);
    try std.testing.expectEqual(@as(u32, 0), rig.compiler.reclaim_epoch);
    try std.testing.expectEqual(@as(?u16, null), chunk.queue_index);
    try std.testing.expectEqual(Status.idle, rig.compiler.step(&rig.drive(alloc), 1_000_000));

    rig.invalidate(slot);
    try std.testing.expectEqual(Chunk.State.unbuilt, chunk.state);
    try std.testing.expect(chunk.queue_index != null);
}

test "emit preparation invalidates fitting borrowed geometry before overwrite" {
    try setup_test_world();
    defer World.data.deinit();
    World.data.apply_block(8, 8, 8, .{ .id = .stone });
    settle_test_world();

    var rig = try TestRig.init(std.testing.allocator, 4);
    defer rig.deinit(std.testing.allocator);
    const alloc = std.testing.allocator;

    const slot = rig.enqueue(.init(0, 0, 0));
    const chunk = rig.store.chunk(slot);
    chunk.meshes = try Chunk.MeshSet.create_cpu(alloc);
    try chunk.meshes.?.opaque_data.ensure_quad_capacity(alloc, 6);
    chunk.geometry_valid = true;
    chunk.committed = .{ .opaque_verts = 24, .transparent_verts = 0, .fluid_verts = 0 };

    _ = rig.compiler.step(&rig.drive(alloc), 1_000_000); // pack
    _ = rig.compiler.step(&rig.drive(alloc), 1_000_000); // fitting mesh_alloc
    try std.testing.expectEqual(Chunk.State.emit, chunk.state);
    try std.testing.expect(chunk.geometry_valid);

    const job = rig.scheduler.claim(&rig.store).?;
    chunk.owner = WORKER_ID;
    var drive = rig.drive(alloc);
    try std.testing.expect(rig.compiler.prepare_emit(&drive, job));
    try std.testing.expect(!chunk.geometry_valid);
    try std.testing.expectEqual(@as(u32, 0), chunk.committed.opaque_verts);

    // A packet invalidation during the unlocked emit work cannot restore or
    // publish the overwritten source; the publication boundary restarts it.
    rig.invalidate(slot);
    rig.scheduler.lock();
    try std.testing.expect(rig.compiler.boundary_restart_if_stale(&drive, job));
    rig.scheduler.unlock();
    try std.testing.expectEqual(Chunk.State.unbuilt, chunk.state);
    try std.testing.expect(!chunk.geometry_valid);
    try std.testing.expect(chunk.queue_index != null);
}

test "stale emit preparation preserves borrowed geometry" {
    var rig = try TestRig.init(std.testing.allocator, 2);
    defer rig.deinit(std.testing.allocator);
    const alloc = std.testing.allocator;

    const slot = rig.enqueue(.init(0, 0, 0));
    const job = rig.scheduler.claim(&rig.store).?;
    const chunk = rig.store.chunk(slot);
    chunk.state = .emit;
    chunk.owner = WORKER_ID;
    chunk.build_revision = 1;
    chunk.source_revision = 2;
    chunk.geometry_valid = true;
    chunk.committed = .{ .opaque_verts = 24, .transparent_verts = 0, .fluid_verts = 0 };

    var drive = rig.drive(alloc);
    try std.testing.expect(!rig.compiler.prepare_emit(&drive, job));
    try std.testing.expect(chunk.geometry_valid);
    try std.testing.expectEqual(Chunk.State.dirty, chunk.state);
    try std.testing.expectEqual(@as(u32, 24), chunk.committed.opaque_verts);
}

test "OOM at mesh creation blocks, reclaims one victim, and never escapes" {
    try setup_test_world();
    defer World.data.deinit();
    // Single stone block: the owning chunk has nonzero counts.
    World.data.apply_block(8, 8, 8, .{ .id = .stone });
    settle_test_world();

    var rig = try TestRig.init(std.testing.allocator, 4);
    defer rig.deinit(std.testing.allocator);
    const alloc = std.testing.allocator;

    // Victim: a resident chunk holding real CPU storage, invalid geometry.
    const victim_slot = rig.enqueue(.init(5, 0, 5));
    const victim = rig.store.chunk(victim_slot);
    victim.meshes = try Chunk.MeshSet.create_cpu(alloc);
    try victim.meshes.?.opaque_data.ensure_quad_capacity(alloc, 64);
    victim.state = .unbuilt;
    rig.scheduler.cancel(&rig.store, victim_slot);

    const slot = rig.enqueue(.init(0, 0, 0));
    const chunk = rig.store.chunk(slot);
    // Committed geometry from an earlier build must survive the OOM.
    chunk.geometry_valid = true;
    chunk.committed = .{ .opaque_verts = 24, .transparent_verts = 0, .fluid_verts = 0 };

    // pack with the good allocator: counts are recorded.
    try std.testing.expectEqual(Status.phase_complete, rig.compiler.step(&rig.drive(alloc), 1_000_000));
    try std.testing.expect(chunk.counts.opaque_verts > 0);

    // mesh_alloc with a failing allocator: creation fails, OOM is contained.
    var failing = std.testing.FailingAllocator.init(alloc, .{ .fail_index = 0 });
    const epoch_before = rig.compiler.reclaim_epoch;
    try std.testing.expectEqual(Status.oom_blocked, rig.compiler.step(&rig.drive(failing.allocator()), 1_000_000));
    try std.testing.expectEqual(Chunk.State.mesh_alloc, chunk.state);
    try std.testing.expectEqual(epoch_before, chunk.blocked_epoch.?);
    try std.testing.expectEqual(epoch_before, chunk.prohibited_epoch.?);
    try std.testing.expectEqual(@as(?Chunk.WorkerId, null), chunk.owner);
    try std.testing.expectEqual(@as(u32, 1), rig.compiler.blocked_count);
    // Old geometry retained; nothing was published or freed on the requester.
    try std.testing.expect(chunk.geometry_valid);
    try std.testing.expectEqual(@as(u32, 24), chunk.committed.opaque_verts);
    // One victim was reclaimed: storage freed, unbuilt, rebuild suppressed.
    try std.testing.expectEqual(epoch_before + 1, rig.compiler.reclaim_epoch);
    try std.testing.expectEqual(Chunk.State.unbuilt, victim.state);
    try std.testing.expectEqual(rig.compiler.reclaim_epoch, victim.suppressed_epoch.?);
    try std.testing.expectEqual(@as(usize, 0), victim.meshes.?.opaque_data.vertices.capacity);

    // The victim's free changed the epoch, so the job retries the allocator
    // (still failing) and returns to the blocked set with the new epoch.
    // The spent victim has nothing left to give: no further epoch bump.
    try std.testing.expectEqual(Status.oom_blocked, rig.compiler.step(&rig.drive(failing.allocator()), 1_000_000));
    try std.testing.expectEqual(epoch_before + 1, chunk.blocked_epoch.?);
    try std.testing.expectEqual(epoch_before + 1, rig.compiler.reclaim_epoch);
    try std.testing.expectEqual(@as(u32, 1), rig.compiler.blocked_count);

    // No retry while the epoch is unchanged, even with a healthy allocator.
    try std.testing.expectEqual(Status.idle, rig.compiler.step(&rig.drive(alloc), 1_000_000));
    try std.testing.expectEqual(Chunk.State.mesh_alloc, chunk.state);
    try std.testing.expectEqual(@as(u32, 1), rig.compiler.blocked_count);

    // An external free changes the epoch and permits exactly one more try.
    var drive = rig.drive(alloc);
    rig.compiler.note_external_free(&drive);
    try std.testing.expectEqual(Status.oom_blocked, rig.compiler.step(&rig.drive(failing.allocator()), 1_000_000));
    try std.testing.expectEqual(rig.compiler.reclaim_epoch, chunk.blocked_epoch.?);
    try std.testing.expectEqual(epoch_before + 2, rig.compiler.reclaim_epoch);
    try std.testing.expectEqual(@as(u32, 1), rig.compiler.blocked_count);
    try std.testing.expect(chunk.geometry_valid);
}

test "partial capacity growth invalidates borrowed geometry and stays contained" {
    try setup_test_world();
    defer World.data.deinit();
    // Fill chunk (0,0,0) with stone so the counts far exceed the initial
    // 32-vertex mesh capacity and growth is required.
    for (0..16) |x| {
        for (0..16) |y| {
            for (0..16) |z| {
                World.data.apply_block(@intCast(x), @intCast(y), @intCast(z), .{ .id = .stone });
            }
        }
    }
    settle_test_world();

    var rig = try TestRig.init(std.testing.allocator, 4);
    defer rig.deinit(std.testing.allocator);
    const alloc = std.testing.allocator;

    const slot = rig.enqueue(.init(0, 0, 0));
    const chunk = rig.store.chunk(slot);
    chunk.meshes = try Chunk.MeshSet.create_cpu(alloc);
    chunk.geometry_valid = true;
    chunk.committed = .{ .opaque_verts = 48, .transparent_verts = 0, .fluid_verts = 0 };

    _ = rig.compiler.step(&rig.drive(alloc), 1_000_000); // pack
    try std.testing.expect(chunk.counts.opaque_verts > 0);

    // Indexed growth has separate vertex/index allocations, so fail the
    // second one to cover partial growth. Non-indexed growth has one
    // allocation; fail it directly. Both paths must already be non-drawable.
    const fail_index: usize = if (ae.Rendering.mesh.indexing_enabled) 1 else 0;
    var failing = std.testing.FailingAllocator.init(alloc, .{ .fail_index = fail_index });
    try std.testing.expectEqual(Status.oom_blocked, rig.compiler.step(&rig.drive(failing.allocator()), 1_000_000));
    try std.testing.expectEqual(Chunk.State.mesh_alloc, chunk.state);
    try std.testing.expectEqual(rig.compiler.reclaim_epoch, chunk.blocked_epoch.?);
    try std.testing.expect(!chunk.geometry_valid);
    try std.testing.expectEqual(@as(u32, 0), chunk.committed.opaque_verts);
}

test "successful capacity growth is non-drawable until emit publishes" {
    try setup_test_world();
    defer World.data.deinit();
    for (0..16) |x| {
        for (0..16) |y| {
            for (0..16) |z| {
                World.data.apply_block(@intCast(x), @intCast(y), @intCast(z), .{ .id = .stone });
            }
        }
    }
    settle_test_world();

    var rig = try TestRig.init(std.testing.allocator, 4);
    defer rig.deinit(std.testing.allocator);
    const alloc = std.testing.allocator;

    const slot = rig.enqueue(.init(0, 0, 0));
    const chunk = rig.store.chunk(slot);
    chunk.meshes = try Chunk.MeshSet.create_cpu(alloc);
    chunk.geometry_valid = true;
    chunk.committed = .{ .opaque_verts = 24, .transparent_verts = 0, .fluid_verts = 0 };

    _ = rig.compiler.step(&rig.drive(alloc), 1_000_000); // pack
    try std.testing.expectEqual(Status.phase_complete, rig.compiler.step(&rig.drive(alloc), 1_000_000));
    try std.testing.expectEqual(Chunk.State.emit, chunk.state);
    try std.testing.expect(!chunk.geometry_valid);
    try std.testing.expectEqual(@as(u32, 0), chunk.committed.opaque_verts);
}

test "mesh-handle reclaim releases handles and clears blocked metadata" {
    var rig = try TestRig.init(std.testing.allocator, 4);
    defer rig.deinit(std.testing.allocator);
    const alloc = std.testing.allocator;

    const requester = rig.enqueue(.init(0, 0, 0));
    const victim_slot = rig.enqueue(.init(5, 0, 5));
    const victim = rig.store.chunk(victim_slot);
    try victim.create_meshes(alloc);
    victim.meshes.?.opaque_data.clear_and_free(alloc);
    victim.meshes.?.trans_data.clear_and_free(alloc);
    victim.meshes.?.fluid_data.clear_and_free(alloc);
    victim.state = .mesh_alloc;
    victim.blocked_epoch = rig.compiler.reclaim_epoch;

    var drive = rig.drive(alloc);
    rig.scheduler.lock();
    rig.compiler.add_blocked(.{
        .slot = victim_slot,
        .generation = rig.store.generation(victim_slot),
        .priority = .{ .class = .non_visible, .seq = 0 },
    });
    try std.testing.expectEqual(victim_slot, rig.compiler.pick_victim(&drive, requester, .mesh_handles).?);
    rig.compiler.evict(&drive, victim_slot, .mesh_handles);
    rig.scheduler.unlock();

    try std.testing.expectEqual(@as(u32, 0), rig.compiler.blocked_count);
    try std.testing.expectEqual(@as(?u32, null), victim.blocked_epoch);
    try std.testing.expectEqual(@as(?Chunk.MeshSet, null), victim.meshes);
    try std.testing.expectEqual(Chunk.State.unbuilt, victim.state);
}

test "new reclaim epoch requeues only older suppressed victims" {
    var rig = try TestRig.init(std.testing.allocator, 4);
    defer rig.deinit(std.testing.allocator);
    const alloc = std.testing.allocator;

    const older_slot = rig.enqueue(.init(5, 0, 5));
    const newest_slot = rig.enqueue(.init(6, 0, 6));
    rig.scheduler.cancel(&rig.store, older_slot);
    rig.scheduler.cancel(&rig.store, newest_slot);
    const older = rig.store.chunk(older_slot);
    const newest = rig.store.chunk(newest_slot);
    older.suppressed_epoch = 1;
    rig.compiler.reclaim_epoch = 1;

    var drive = rig.drive(alloc);
    rig.scheduler.lock();
    rig.compiler.advance_reclaim_epoch_unlocked(&drive, newest_slot);
    rig.scheduler.unlock();

    try std.testing.expectEqual(@as(u32, 2), rig.compiler.reclaim_epoch);
    try std.testing.expectEqual(@as(?u32, null), older.suppressed_epoch);
    try std.testing.expect(older.queue_index != null);
    try std.testing.expectEqual(@as(?u32, 2), newest.suppressed_epoch);
    try std.testing.expectEqual(@as(?u16, null), newest.queue_index);
}

test "invalidating an OOM-blocked job unblocks and restarts at pack" {
    try setup_test_world();
    defer World.data.deinit();
    World.data.apply_block(8, 8, 8, .{ .id = .stone });
    settle_test_world();

    var rig = try TestRig.init(std.testing.allocator, 4);
    defer rig.deinit(std.testing.allocator);
    const alloc = std.testing.allocator;

    const slot = rig.enqueue(.init(0, 0, 0));
    const chunk = rig.store.chunk(slot);

    _ = rig.compiler.step(&rig.drive(alloc), 1_000_000); // pack
    var failing = std.testing.FailingAllocator.init(alloc, .{ .fail_index = 0 });
    try std.testing.expectEqual(Status.oom_blocked, rig.compiler.step(&rig.drive(failing.allocator()), 1_000_000));
    try std.testing.expectEqual(@as(u32, 1), rig.compiler.blocked_count);

    // A new revision cancels the stale phase and allows pack for it.
    rig.invalidate(slot);
    try std.testing.expectEqual(@as(u32, 0), rig.compiler.blocked_count);
    try std.testing.expectEqual(@as(?u32, null), chunk.blocked_epoch);
    try std.testing.expectEqual(Chunk.State.unbuilt, chunk.state);

    // pack for the new revision runs even while allocation is prohibited;
    // mesh_alloc then returns to the blocked set without an allocator call
    // (the healthy allocator proves it: creation would have succeeded).
    try std.testing.expectEqual(Status.phase_complete, rig.compiler.step(&rig.drive(alloc), 1_000_000));
    try std.testing.expectEqual(Chunk.State.mesh_alloc, chunk.state);
    try std.testing.expect(chunk.counts.opaque_verts > 0);
    try std.testing.expectEqual(Status.oom_blocked, rig.compiler.step(&rig.drive(alloc), 1_000_000));
    try std.testing.expectEqual(@as(u32, 1), rig.compiler.blocked_count);
    try std.testing.expectEqual(@as(?Chunk.MeshSet, null), chunk.meshes);
}

test "retirement cancels queue membership and invalidates claims" {
    try test_all_air_world();
    defer World.data.deinit();

    var rig = try TestRig.init(std.testing.allocator, 4);
    defer rig.deinit(std.testing.allocator);
    const alloc = std.testing.allocator;

    const slot = rig.enqueue(.init(2, 1, 2));
    const generation = rig.store.generation(slot);
    rig.scheduler.cancel(&rig.store, slot);
    rig.store.retire(slot);
    try std.testing.expect(!rig.store.validate(slot, generation));

    // The coordinate can become resident again as an independent chunk.
    const slot2 = rig.enqueue(.init(2, 1, 2));
    var guard: u32 = 8;
    while (guard > 0) : (guard -= 1) {
        if (rig.compiler.step(&rig.drive(alloc), 1_000_000) == .idle) break;
    }
    try std.testing.expectEqual(Chunk.State.built, rig.store.chunk(slot2).state);
}
