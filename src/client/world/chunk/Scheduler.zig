const std = @import("std");
const ae = @import("aether");
const Chunk = @import("Chunk.zig");
const ChunkStore = @import("ChunkStore.zig");
const limits = @import("ChunkCoord.zig");
const ChunkCoord = limits.ChunkCoord;
const Camera = @import("../../player/Camera.zig");

const SlotIndex = ChunkStore.SlotIndex;

/// Deterministic priority classes, ordered by urgency. Distance and enqueue
/// sequence break ties inside a class.
pub const PriorityClass = enum(u8) {
    /// Ordered interactive block-change work.
    interactive,
    /// Other dirty visible chunks.
    dirty_visible,
    /// Visible initial builds.
    initial_visible,
    /// Everything else.
    non_visible,
};

/// Stable scheduling identity for one build request. Compiler phase
/// transitions requeue this exact ticket; only an explicit promotion or a
/// render-thread camera refresh may change it.
pub const Priority = struct {
    class: PriorityClass,
    seq: u64,
};

pub const Job = struct {
    slot: SlotIndex,
    generation: u32,
    priority: Priority,
};

const Entry = struct {
    slot: SlotIndex,
    generation: u32,
    priority: Priority,
    dist_sq: f32,
};

/// A packet invalidation can arrive while a phase owns the slot. Keep its
/// replacement priority out of the runnable heap until the owner reaches a
/// phase boundary.
const PendingPriority = struct {
    generation: u32,
    priority: Priority,
};

/// Fixed-capacity binary heap of queued chunk jobs, at most one entry per
/// resident slot. Capacity equals the slot count, so no enqueue can
/// allocate or overflow. The mutex protects heap contents, slot ownership,
/// queue linkage, lifecycle transitions, and OOM-blocked membership; heavy
/// pack/alloc/emit work runs without it.
heap: []Entry,
pending_priorities: []?PendingPriority,
len: u32,
mutex: std.atomic.Mutex,
next_seq: u64,
/// Camera snapshot for visibility classification and distance ranking.
/// Producers and claimers never read a live camera; the render thread
/// refreshes this once per frame.
camera_snapshot: Camera,
snapshot_ready: bool,

const Self = @This();

pub fn init(allocator: std.mem.Allocator, capacity: u32) !Self {
    std.debug.assert(capacity > 0);
    const heap = try allocator.alloc(Entry, capacity);
    errdefer allocator.free(heap);
    const pending_priorities = try allocator.alloc(?PendingPriority, capacity);
    @memset(pending_priorities, null);
    return .{
        .heap = heap,
        .pending_priorities = pending_priorities,
        .len = 0,
        .mutex = .unlocked,
        .next_seq = 0,
        .camera_snapshot = Camera.init(0, 0, 0),
        .snapshot_ready = false,
    };
}

pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
    allocator.free(self.pending_priorities);
    allocator.free(self.heap);
}

pub fn lock(self: *Self) void {
    while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
}

pub fn unlock(self: *Self) void {
    self.mutex.unlock();
}

/// Queue priority from live chunk state and the scheduler-owned camera
/// snapshot. Caller must hold the mutex. Interactive block changes override
/// this at the invalidation site.
pub fn classify_snapshot(self: *const Self, chunk: *const Chunk) PriorityClass {
    std.debug.assert(self.snapshot_ready);
    if (self.camera_snapshot.section_visible(chunk.coord.x, chunk.coord.y, chunk.coord.z))
        return if (chunk.geometry_valid) .dirty_visible else .initial_visible;
    return .non_visible;
}

/// Refresh the ranking snapshot and every queued priority (render thread
/// only). Interactive work keeps its ordered class and sequence.
pub fn set_camera(self: *Self, store: *ChunkStore, camera: *const Camera) void {
    self.lock();
    defer self.unlock();
    self.camera_snapshot = camera.*;
    self.snapshot_ready = true;

    for (self.heap[0..self.len]) |*entry| {
        std.debug.assert(store.validate(entry.slot, entry.generation));
        const chunk = store.chunk(entry.slot);
        entry.dist_sq = self.dist_sq_unlocked(chunk.coord);
        if (entry.priority.class != .interactive) {
            entry.priority.class = self.classify_snapshot(chunk);
        }
    }

    // Bottom-up heap construction restores ordering in linear time.
    var i = self.len / 2;
    while (i > 0) {
        i -= 1;
        self.sift_down(store, i);
    }
}

/// Nearest-3D-chunk-center distance against the camera snapshot.
/// Caller must hold the mutex.
fn dist_sq_unlocked(self: *const Self, coord: ChunkCoord) f32 {
    const wx: f32 = @as(f32, @floatFromInt(@as(u32, coord.x) * 16)) + 8.0;
    const wy: f32 = @as(f32, @floatFromInt(@as(u32, coord.y) * 16)) + 8.0;
    const wz: f32 = @as(f32, @floatFromInt(@as(u32, coord.z) * 16)) + 8.0;
    const dx = wx - self.camera_snapshot.x;
    const dy = wy - self.camera_snapshot.y;
    const dz = wz - self.camera_snapshot.z;
    return dx * dx + dy * dy + dz * dz;
}

fn entry_less(a: Entry, b: Entry) bool {
    if (a.priority.class != b.priority.class)
        return @intFromEnum(a.priority.class) < @intFromEnum(b.priority.class);
    // Ordered interactive block-change work: sequence only, so one batch's
    // owner/neighbor order is never reshuffled by distance.
    if (a.priority.class == .interactive) return a.priority.seq < b.priority.seq;
    if (a.dist_sq != b.dist_sq) return a.dist_sq < b.dist_sq;
    return a.priority.seq < b.priority.seq;
}

/// Caller must hold the mutex. Keeps the slot's queue_index pointing at the
/// entry's heap position; entries always belong to the slot's live
/// generation (retirement cancels membership first).
fn set_pos(self: *Self, store: *ChunkStore, pos: u32) void {
    const entry = &self.heap[pos];
    std.debug.assert(store.validate(entry.slot, entry.generation));
    store.chunk(entry.slot).queue_index = @intCast(pos);
}

fn sift_up(self: *Self, store: *ChunkStore, pos: u32) void {
    var i = pos;
    while (i > 0) {
        const parent = (i - 1) / 2;
        if (!entry_less(self.heap[i], self.heap[parent])) break;
        std.mem.swap(Entry, &self.heap[i], &self.heap[parent]);
        self.set_pos(store, i);
        self.set_pos(store, parent);
        i = parent;
    }
}

fn sift_down(self: *Self, store: *ChunkStore, pos: u32) void {
    var i = pos;
    while (true) {
        const left = i * 2 + 1;
        const right = left + 1;
        var smallest = i;
        if (left < self.len and entry_less(self.heap[left], self.heap[smallest])) smallest = left;
        if (right < self.len and entry_less(self.heap[right], self.heap[smallest])) smallest = right;
        if (smallest == i) break;
        std.mem.swap(Entry, &self.heap[i], &self.heap[smallest]);
        self.set_pos(store, i);
        self.set_pos(store, smallest);
        i = smallest;
    }
}

fn fresh_priority(self: *Self, class: PriorityClass) Priority {
    const priority: Priority = .{ .class = class, .seq = self.next_seq };
    self.next_seq +%= 1;
    return priority;
}

fn class_more_urgent(a: PriorityClass, b: PriorityClass) bool {
    return @intFromEnum(a) < @intFromEnum(b);
}

/// Merge an already-sequenced replacement with the ticket being resumed.
/// A newer interactive ticket replaces obsolete order from an earlier
/// block-change batch; other equal-class work retains its original order.
fn merge_priority(current: Priority, replacement: Priority) Priority {
    if (class_more_urgent(replacement.class, current.class)) return replacement;
    if (class_more_urgent(current.class, replacement.class)) return current;
    if (current.class == .interactive and replacement.seq > current.seq) return replacement;
    return current;
}

fn insert_unlocked(
    self: *Self,
    store: *ChunkStore,
    slot: SlotIndex,
    generation: u32,
    priority: Priority,
) void {
    std.debug.assert(self.len < self.heap.len);
    const chunk = store.chunk(slot);
    const entry: Entry = .{
        .slot = slot,
        .generation = generation,
        .priority = priority,
        .dist_sq = self.dist_sq_unlocked(chunk.coord),
    };
    self.heap[self.len] = entry;
    self.len += 1;
    self.set_pos(store, self.len - 1);
    self.sift_up(store, self.len - 1);
}

/// Record a replacement priority for an in-flight phase. Caller holds the
/// mutex and the chunk is owned, so retirement cannot reuse the slot.
fn promote_pending_unlocked(
    self: *Self,
    slot: SlotIndex,
    generation: u32,
    class: PriorityClass,
) void {
    const pending_slot = &self.pending_priorities[slot];
    if (pending_slot.*) |*existing| {
        if (existing.generation != generation) {
            existing.* = .{
                .generation = generation,
                .priority = self.fresh_priority(class),
            };
        } else if (class_more_urgent(class, existing.priority.class) or
            (class == .interactive and existing.priority.class == .interactive))
        {
            existing.priority = self.fresh_priority(class);
        }
        return;
    }
    pending_slot.* = .{
        .generation = generation,
        .priority = self.fresh_priority(class),
    };
}

/// Schedule explicit work, atomically deduplicated by queue membership.
/// More urgent work wins; every interactive-on-interactive promotion takes
/// a fresh sequence so the newest ordered batch replaces the old one.
pub fn append(self: *Self, store: *ChunkStore, slot: SlotIndex, class: PriorityClass) void {
    self.lock();
    defer self.unlock();
    self.append_unlocked(store, slot, class);
}

/// Lock-free body of append; caller must hold the mutex. If the slot is
/// currently owned, the promotion is held for its next phase boundary.
pub fn append_unlocked(self: *Self, store: *ChunkStore, slot: SlotIndex, class: PriorityClass) void {
    const generation = store.generation(slot);
    const chunk = store.chunk(slot);
    if (chunk.owner != null) {
        self.promote_pending_unlocked(slot, generation, class);
        return;
    }
    if (chunk.queue_index != null) {
        self.promote_unlocked(store, slot, generation, class);
        return;
    }
    self.insert_unlocked(store, slot, generation, self.fresh_priority(class));
}

/// Reprioritize a queued slot; enqueues it when absent.
pub fn promote(self: *Self, store: *ChunkStore, slot: SlotIndex, class: PriorityClass) void {
    self.lock();
    defer self.unlock();
    self.append_unlocked(store, slot, class);
}

/// Caller must hold the mutex; chunk must be queued.
fn promote_unlocked(self: *Self, store: *ChunkStore, slot: SlotIndex, generation: u32, class: PriorityClass) void {
    const chunk = store.chunk(slot);
    const pos = chunk.queue_index.?;
    const entry = &self.heap[pos];
    std.debug.assert(entry.slot == slot and entry.generation == generation);
    if (class_more_urgent(class, entry.priority.class) or
        (class == .interactive and entry.priority.class == .interactive))
    {
        entry.priority = self.fresh_priority(class);
    }
    entry.dist_sq = self.dist_sq_unlocked(chunk.coord);
    self.sift_up(store, pos);
    self.sift_down(store, pos);
}

/// Requeue a claimed phase without manufacturing a new priority. A packet
/// invalidation recorded while the phase ran is merged at this boundary.
/// Caller must hold the mutex.
pub fn requeue_unlocked(self: *Self, store: *ChunkStore, job: Job) void {
    std.debug.assert(store.validate(job.slot, job.generation));
    const chunk = store.chunk(job.slot);
    std.debug.assert(chunk.queue_index == null);
    var priority = job.priority;
    const pending_slot = &self.pending_priorities[job.slot];
    if (pending_slot.*) |replacement| {
        std.debug.assert(replacement.generation == job.generation);
        priority = merge_priority(priority, replacement.priority);
        pending_slot.* = null;
    }
    self.insert_unlocked(store, job.slot, job.generation, priority);
}

/// Cancel queue membership. No-op when the slot is not queued.
pub fn cancel(self: *Self, store: *ChunkStore, slot: SlotIndex) void {
    self.lock();
    defer self.unlock();
    self.cancel_unlocked(store, slot);
}

/// Lock-free body of cancel; caller must hold the mutex.
pub fn cancel_unlocked(self: *Self, store: *ChunkStore, slot: SlotIndex) void {
    const chunk = store.chunk(slot);
    self.pending_priorities[slot] = null;
    const pos = chunk.queue_index orelse return;
    std.debug.assert(self.heap[pos].slot == slot);
    chunk.queue_index = null;
    self.len -= 1;
    if (pos != self.len) {
        self.heap[pos] = self.heap[self.len];
        self.set_pos(store, pos);
        self.sift_up(store, pos);
        self.sift_down(store, pos);
    }
}

/// Distance from the camera snapshot to a chunk center. Caller must hold
/// the mutex.
pub fn dist_sq_snapshot(self: *const Self, coord: ChunkCoord) f32 {
    return self.dist_sq_unlocked(coord);
}

/// Visibility against the render thread's last complete camera snapshot.
/// Caller must hold the mutex.
pub fn visible_snapshot(self: *const Self, coord: ChunkCoord) bool {
    std.debug.assert(self.snapshot_ready);
    return self.camera_snapshot.section_visible(coord.x, coord.y, coord.z);
}

/// Atomically remove the best job. The slot leaves the queue; assigning an
/// owner is the claimer's next step under the same mutex discipline.
/// Validates the slot generation so a stale entry can never hand out work
/// for a different residency.
pub fn claim(self: *Self, store: *ChunkStore) ?Job {
    self.lock();
    defer self.unlock();
    return self.claim_unlocked(store);
}

/// Lock-free body of claim. The compiler uses this so removing the queue
/// entry and assigning its owner are one lifecycle transition.
pub fn claim_unlocked(self: *Self, store: *ChunkStore) ?Job {
    while (self.len > 0) {
        const best = self.heap[0];
        self.len -= 1;
        if (self.len > 0) {
            self.heap[0] = self.heap[self.len];
            self.set_pos(store, 0);
            self.sift_down(store, 0);
        }
        if (!store.validate(best.slot, best.generation)) continue;
        store.chunk(best.slot).queue_index = null;
        return .{
            .slot = best.slot,
            .generation = best.generation,
            .priority = best.priority,
        };
    }
    return null;
}

pub fn pending(self: *Self) u32 {
    self.lock();
    defer self.unlock();
    return self.len;
}

// --- Tests ---

fn make_store(capacity: u32) !ChunkStore {
    return ChunkStore.init(std.testing.allocator, capacity);
}

fn test_camera(x: f32, y: f32, z: f32) Camera {
    var camera = Camera.init(x, y, z);
    camera.frustum = ae.Math.Frustum.fromViewProjection(ae.Math.Mat4.identity());
    return camera;
}

fn enqueue_coords(sched: *Self, store: *ChunkStore, coords: []const ChunkCoord, class: PriorityClass) void {
    for (coords) |coord| {
        const slot = store.ensure(coord).?;
        sched.append(store, slot, class);
    }
}

fn claim_order(sched: *Self, store: *ChunkStore, out: []ChunkCoord) u32 {
    var n: u32 = 0;
    while (sched.claim(store)) |job| {
        out[n] = store.chunk(job.slot).coord;
        n += 1;
    }
    return n;
}

const LifecycleRace = struct {
    scheduler: *Self,
    store: *ChunkStore,
    coord_a: ChunkCoord,
    coord_b: ChunkCoord,
};

fn race_invalidate(ctx: *LifecycleRace) void {
    var i: u32 = 0;
    while (i < 10_000) : (i += 1) {
        ctx.scheduler.lock();
        if (ctx.store.lookup(ctx.coord_a)) |slot| {
            _ = ctx.store.chunk(slot).invalidate();
            const class = ctx.scheduler.classify_snapshot(ctx.store.chunk(slot));
            ctx.scheduler.append_unlocked(ctx.store, slot, class);
        }
        ctx.scheduler.unlock();
    }
}

fn race_recycle(ctx: *LifecycleRace) void {
    var i: u32 = 0;
    while (i < 10_000) : (i += 1) {
        ctx.scheduler.lock();
        if (ctx.store.slots[0].active) {
            ctx.scheduler.cancel_unlocked(ctx.store, 0);
            ctx.store.retire(0);
        }
        const coord = if (i % 2 == 0) ctx.coord_b else ctx.coord_a;
        const slot = ctx.store.ensure(coord).?;
        ctx.scheduler.append_unlocked(ctx.store, slot, .non_visible);
        ctx.scheduler.unlock();
    }
}

test "append and claim are deduplicated per slot" {
    var store = try make_store(4);
    defer store.deinit();
    var sched = try Self.init(std.testing.allocator, 4);
    defer sched.deinit(std.testing.allocator);

    const slot = store.ensure(ChunkCoord.init(1, 0, 1)).?;
    sched.append(&store, slot, .non_visible);
    sched.append(&store, slot, .non_visible);
    try std.testing.expectEqual(@as(u32, 1), sched.pending());

    const job = sched.claim(&store).?;
    try std.testing.expectEqual(slot, job.slot);
    try std.testing.expect(store.validate(job.slot, job.generation));
    try std.testing.expectEqual(@as(?u16, null), store.chunk(slot).queue_index);
    try std.testing.expectEqual(@as(?Job, null), sched.claim(&store));
}

test "class beats distance beats sequence" {
    var store = try make_store(8);
    defer store.deinit();
    var sched = try Self.init(std.testing.allocator, 8);
    defer sched.deinit(std.testing.allocator);
    var camera = test_camera(0, 0, 0);
    sched.set_camera(&store, &camera);

    // Far interactive beats near initial-build.
    enqueue_coords(&sched, &store, &.{ChunkCoord.init(3, 0, 3)}, .initial_visible);
    enqueue_coords(&sched, &store, &.{ChunkCoord.init(31, 7, 31)}, .interactive);
    // Same class: nearer first.
    enqueue_coords(&sched, &store, &.{ChunkCoord.init(20, 0, 20)}, .non_visible);
    enqueue_coords(&sched, &store, &.{ChunkCoord.init(10, 0, 10)}, .non_visible);

    var order: [4]ChunkCoord = undefined;
    const n = claim_order(&sched, &store, &order);
    try std.testing.expectEqual(@as(u32, 4), n);
    try std.testing.expect(order[0].eql(ChunkCoord.init(31, 7, 31)));
    try std.testing.expect(order[1].eql(ChunkCoord.init(3, 0, 3)));
    try std.testing.expect(order[2].eql(ChunkCoord.init(10, 0, 10)));
    try std.testing.expect(order[3].eql(ChunkCoord.init(20, 0, 20)));
}

test "ordered block-change batch preserves enqueue order" {
    var store = try make_store(8);
    defer store.deinit();
    var sched = try Self.init(std.testing.allocator, 8);
    defer sched.deinit(std.testing.allocator);
    var camera = test_camera(0, 0, 0);
    sched.set_camera(&store, &camera);

    // Interleaved distances: order within the interactive class is the
    // enqueue sequence, not distance.
    const batch = [_]ChunkCoord{
        ChunkCoord.init(9, 0, 9),
        ChunkCoord.init(1, 0, 1),
        ChunkCoord.init(5, 0, 5),
    };
    enqueue_coords(&sched, &store, &batch, .interactive);
    camera.x = 200;
    camera.z = 200;
    sched.set_camera(&store, &camera);

    var order: [3]ChunkCoord = undefined;
    const n = claim_order(&sched, &store, &order);
    try std.testing.expectEqual(@as(u32, 3), n);
    for (batch, 0..) |coord, i| try std.testing.expect(order[i].eql(coord));
}

test "promotion to a more urgent class re-sequences" {
    var store = try make_store(8);
    defer store.deinit();
    var sched = try Self.init(std.testing.allocator, 8);
    defer sched.deinit(std.testing.allocator);
    var camera = test_camera(0, 0, 0);
    sched.set_camera(&store, &camera);

    const a = store.ensure(ChunkCoord.init(1, 0, 1)).?;
    const b = store.ensure(ChunkCoord.init(2, 0, 2)).?;
    sched.append(&store, a, .interactive);
    sched.append(&store, b, .non_visible);
    // b's block change arrived after a's, so b joins the interactive tier
    // behind a despite having queued earlier.
    sched.promote(&store, b, .interactive);

    var order: [2]ChunkCoord = undefined;
    const n = claim_order(&sched, &store, &order);
    try std.testing.expectEqual(@as(u32, 2), n);
    try std.testing.expect(order[0].eql(ChunkCoord.init(1, 0, 1)));
    try std.testing.expect(order[1].eql(ChunkCoord.init(2, 0, 2)));
}

test "latest interactive batch replaces queued and in-flight order" {
    var store = try make_store(4);
    defer store.deinit();
    var sched = try Self.init(std.testing.allocator, 4);
    defer sched.deinit(std.testing.allocator);

    const a = store.ensure(ChunkCoord.init(1, 0, 1)).?;
    const b = store.ensure(ChunkCoord.init(2, 0, 2)).?;
    sched.append(&store, a, .interactive);
    sched.append(&store, b, .interactive);

    // a is already compiling when a later batch requires b before a.
    const a_job = sched.claim(&store).?;
    try std.testing.expectEqual(a, a_job.slot);
    sched.lock();
    store.chunk(a).owner = 0;
    sched.unlock();
    sched.promote(&store, b, .interactive);
    sched.promote(&store, a, .interactive);

    // The in-flight promotion is installed at a's phase boundary.
    sched.lock();
    store.chunk(a).owner = null;
    sched.requeue_unlocked(&store, a_job);
    sched.unlock();

    try std.testing.expectEqual(b, sched.claim(&store).?.slot);
    try std.testing.expectEqual(a, sched.claim(&store).?.slot);
}

test "cancel removes membership and keeps the heap valid" {
    var store = try make_store(8);
    defer store.deinit();
    var sched = try Self.init(std.testing.allocator, 8);
    defer sched.deinit(std.testing.allocator);
    var camera = test_camera(0, 0, 0);
    sched.set_camera(&store, &camera);

    var slots: [5]SlotIndex = undefined;
    for (0..5) |i| {
        slots[i] = store.ensure(ChunkCoord.init(@intCast(i), 0, 0)).?;
        sched.append(&store, slots[i], .non_visible);
    }
    sched.cancel(&store, slots[1]);
    sched.cancel(&store, slots[3]);
    // Cancelling an absent slot is a no-op.
    sched.cancel(&store, slots[3]);
    try std.testing.expectEqual(@as(u32, 3), sched.pending());

    var order: [5]ChunkCoord = undefined;
    const n = claim_order(&sched, &store, &order);
    try std.testing.expectEqual(@as(u32, 3), n);
    try std.testing.expect(order[0].eql(ChunkCoord.init(0, 0, 0)));
    try std.testing.expect(order[1].eql(ChunkCoord.init(2, 0, 0)));
    try std.testing.expect(order[2].eql(ChunkCoord.init(4, 0, 0)));
}

test "stale generations are rejected at claim" {
    var store = try make_store(8);
    defer store.deinit();
    var sched = try Self.init(std.testing.allocator, 8);
    defer sched.deinit(std.testing.allocator);

    const slot = store.ensure(ChunkCoord.init(1, 0, 1)).?;
    sched.append(&store, slot, .non_visible);
    // Simulate retirement by cancelling + retiring + re-ensuring: the old
    // entry can never claim into the new residency.
    sched.cancel(&store, slot);
    store.retire(slot);
    const reused = store.ensure(ChunkCoord.init(4, 0, 4)).?;
    sched.append(&store, reused, .non_visible);

    const job = sched.claim(&store).?;
    try std.testing.expectEqual(reused, job.slot);
    try std.testing.expectEqual(store.generation(reused), job.generation);
}

test "locked lookup invalidation and slot reuse stay generation safe" {
    var store = try make_store(1);
    defer store.deinit();
    var sched = try Self.init(std.testing.allocator, 1);
    defer sched.deinit(std.testing.allocator);
    var camera = test_camera(0, 0, 0);
    sched.set_camera(&store, &camera);

    const coord_a = ChunkCoord.init(1, 0, 1);
    const coord_b = ChunkCoord.init(2, 0, 2);
    const slot = store.ensure(coord_a).?;
    sched.append(&store, slot, .non_visible);
    var ctx: LifecycleRace = .{
        .scheduler = &sched,
        .store = &store,
        .coord_a = coord_a,
        .coord_b = coord_b,
    };

    const invalidator = try std.Thread.spawn(.{}, race_invalidate, .{&ctx});
    const recycler = try std.Thread.spawn(.{}, race_recycle, .{&ctx});
    invalidator.join();
    recycler.join();

    sched.lock();
    defer sched.unlock();
    try std.testing.expectEqual(@as(u32, 1), store.active_count);
    try std.testing.expectEqual(@as(u32, 1), sched.len);
    const entry = sched.heap[0];
    try std.testing.expect(store.validate(entry.slot, entry.generation));
    try std.testing.expectEqual(@as(?u16, 0), store.chunk(entry.slot).queue_index);
}

test "full capacity holds one entry per resident slot" {
    const cap: u32 = 6;
    var store = try make_store(cap);
    defer store.deinit();
    var sched = try Self.init(std.testing.allocator, cap);
    defer sched.deinit(std.testing.allocator);

    for (0..cap) |i| {
        const slot = store.ensure(ChunkCoord.init(@intCast(i), 0, 0)).?;
        sched.append(&store, slot, .non_visible);
        sched.append(&store, slot, .non_visible); // dedupe, no growth
    }
    try std.testing.expectEqual(cap, sched.pending());

    var order: [cap]ChunkCoord = undefined;
    try std.testing.expectEqual(cap, claim_order(&sched, &store, &order));
}

test "camera snapshot drives distance ranking" {
    var store = try make_store(4);
    defer store.deinit();
    var sched = try Self.init(std.testing.allocator, 4);
    defer sched.deinit(std.testing.allocator);

    var camera = test_camera(500, 0, 500);
    sched.set_camera(&store, &camera);
    const near = store.ensure(ChunkCoord.init(30, 0, 30)).?;
    const far = store.ensure(ChunkCoord.init(1, 0, 1)).?;
    sched.append(&store, far, .dirty_visible);
    sched.append(&store, near, .dirty_visible);

    const job = sched.claim(&store).?;
    try std.testing.expectEqual(near, job.slot);
}

test "classification reads the copied camera snapshot" {
    var store = try make_store(2);
    defer store.deinit();
    var sched = try Self.init(std.testing.allocator, 2);
    defer sched.deinit(std.testing.allocator);

    const slot = store.ensure(ChunkCoord.init(0, 0, 0)).?;
    var camera = test_camera(0, 0, 0);
    try std.testing.expect(camera.section_visible(0, 0, 0));
    sched.set_camera(&store, &camera);

    camera.frustum = ae.Math.Frustum.fromViewProjection(
        ae.Math.Mat4.translation(-1000, 0, 0),
    );
    try std.testing.expect(!camera.section_visible(0, 0, 0));

    sched.lock();
    const class = sched.classify_snapshot(store.chunk(slot));
    sched.unlock();
    try std.testing.expectEqual(PriorityClass.initial_visible, class);
}

test "camera refresh reorders an existing distance backlog" {
    var store = try make_store(4);
    defer store.deinit();
    var sched = try Self.init(std.testing.allocator, 4);
    defer sched.deinit(std.testing.allocator);

    var camera = test_camera(0, 0, 0);
    sched.set_camera(&store, &camera);
    const old_near = store.ensure(ChunkCoord.init(2, 0, 2)).?;
    const new_near = store.ensure(ChunkCoord.init(30, 0, 30)).?;
    sched.append(&store, old_near, .non_visible);
    sched.append(&store, new_near, .non_visible);

    camera.x = 30 * 16 + 8;
    camera.z = 30 * 16 + 8;
    sched.set_camera(&store, &camera);

    try std.testing.expectEqual(new_near, sched.claim(&store).?.slot);
}

test "camera refresh recomputes visibility classes" {
    var store = try make_store(4);
    defer store.deinit();
    var sched = try Self.init(std.testing.allocator, 4);
    defer sched.deinit(std.testing.allocator);

    const visible = store.ensure(ChunkCoord.init(0, 0, 0)).?;
    const hidden = store.ensure(ChunkCoord.init(4, 0, 4)).?;
    store.chunk(visible).geometry_valid = true;
    sched.append(&store, visible, .non_visible);
    sched.append(&store, hidden, .dirty_visible);

    var camera = test_camera(0, 0, 0);
    sched.set_camera(&store, &camera);

    try std.testing.expectEqual(visible, sched.claim(&store).?.slot);
}
