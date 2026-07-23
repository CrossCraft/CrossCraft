const std = @import("std");
const ae = @import("aether");
const Math = ae.Math;
const Rendering = ae.Rendering;

const Vertex = Rendering.Vertex;
const ChunkCoord = @import("ChunkCoord.zig").ChunkCoord;
const mesher = @import("mesher.zig");

pub const BatchMesh = Rendering.Mesh(Vertex);
pub const BatchMeshData = Rendering.MeshData(Vertex);
pub const MeshCreateError = error{ OutOfMemory, OutOfMeshes };
pub const WorkerId = u8;

/// Authoritative lifecycle of one resident chunk. `dirty` means committed
/// geometry exists but is stale; `unbuilt` is the resting state when no
/// committed geometry exists (the required non-built dirty case). Phase
/// states track compilation progress while `geometry_valid` independently
/// says whether an older committed mesh can still be drawn. `rejected`
/// contains a source revision whose batch exceeds the active index space.
pub const State = enum {
    unbuilt,
    pack,
    mesh_alloc,
    emit,
    built,
    dirty,
    rejected,
};

/// What the caller must do with the scheduler/blocked set after
/// invalidate() rewrote the lifecycle fields.
pub const InvalidateAction = enum {
    none,
    enqueue,
    promote,
    unblock_enqueue,
};

/// CPU vertex storage + GPU handle bundle for the three draw batches.
/// Created lazily in the mesh_alloc phase; a resident chunk without meshes
/// is metadata only.
pub const MeshSet = struct {
    opaque_data: BatchMeshData,
    @"opaque": BatchMesh,
    trans_data: BatchMeshData,
    trans: BatchMesh,
    fluid_data: BatchMeshData,
    fluid: BatchMesh,

    /// CPU storage only; headless-testable. GPU handles are created by
    /// create_gpu afterwards so allocation failures surface before any
    /// graphics call.
    pub fn create_cpu(allocator: std.mem.Allocator) error{OutOfMemory}!MeshSet {
        var set: MeshSet = undefined;
        set.opaque_data = try init_data(allocator);
        errdefer set.opaque_data.deinit(allocator);
        set.trans_data = try init_data(allocator);
        errdefer set.trans_data.deinit(allocator);
        set.fluid_data = try init_data(allocator);
        return set;
    }

    /// MeshData.init cannot overflow an index space at its fixed initial
    /// capacity, so IndexOverflow is excluded by construction.
    fn init_data(allocator: std.mem.Allocator) error{OutOfMemory}!BatchMeshData {
        return BatchMeshData.init(allocator) catch |err| switch (err) {
            error.IndexOverflow => unreachable,
            error.OutOfMemory => error.OutOfMemory,
        };
    }

    /// GPU handle creation is transactional: a later batch failure releases
    /// the handles already acquired by this attempt.
    pub fn create_gpu(self: *MeshSet) MeshCreateError!void {
        self.@"opaque" = try BatchMesh.init(&.{});
        errdefer self.@"opaque".deinit();
        self.trans = try BatchMesh.init(&.{});
        errdefer self.trans.deinit();
        self.fluid = try BatchMesh.init(&.{});
    }

    pub fn deinit(self: *MeshSet, allocator: std.mem.Allocator) void {
        self.@"opaque".deinit();
        self.trans.deinit();
        self.fluid.deinit();
        self.opaque_data.deinit(allocator);
        self.trans_data.deinit(allocator);
        self.fluid_data.deinit(allocator);
    }
};

coord: ChunkCoord,
meshes: ?MeshSet = null,

state: State = .unbuilt,
/// Incremented for every mesh-affecting invalidation.
source_revision: u32 = 0,
/// Revision captured for the current compilation.
build_revision: u32 = 0,
/// Revision of committed GPU geometry.
built_revision: u32 = 0,
/// Whether the renderer may draw committed geometry.
geometry_valid: bool = false,
owner: ?WorkerId = null,
/// Position in the scheduler heap while queued; null when absent.
queue_index: ?u16 = null,
restart_requested: bool = false,

/// Counts produced by the latest pack phase (emit sizing input).
counts: mesher.SectionCounts = .{ .opaque_verts = 0, .transparent_verts = 0, .fluid_verts = 0 },
/// Counts of the committed GPU geometry; gates drawing.
committed: mesher.SectionCounts = .{ .opaque_verts = 0, .transparent_verts = 0, .fluid_verts = 0 },

/// Target mesh-affecting inputs, written by the renderer through the
/// revision path. Captured into build_* at claim time.
near_lod: bool = false,
ao_enabled: bool = false,
build_near_lod: bool = false,
build_ao: bool = false,

/// OOM wait information: the reclaim epoch the blocked set parked this job
/// at, and the quad capacities the failed mesh_alloc requested.
blocked_epoch: ?u32 = null,
/// Allocator prohibition: while the global reclaim epoch still equals this
/// value, mesh_alloc must not call the allocator. Unlike blocked_epoch it
/// survives an invalidation-driven repack, so a new revision can pack but
/// still cannot allocate until a real free is observed.
prohibited_epoch: ?u32 = null,
req_opaque_quads: u32 = 0,
req_trans_quads: u32 = 0,
req_fluid_quads: u32 = 0,
/// Reclaim epoch at which this chunk was evicted as an OOM victim. While
/// current, the compiler suppresses the immediate rebuild so the freed
/// storage benefits the requester; any invalidation clears it.
suppressed_epoch: ?u32 = null,

/// Bouncy-rise animation progress in [0, 1]. See model_matrix.
anim_progress: f32 = 1.0,
/// True until the first successful publish.
first_build: bool = true,

const Self = @This();

pub fn init(coord: ChunkCoord) Self {
    return .{ .coord = coord };
}

/// Record one mesh-affecting invalidation and rewrite lifecycle fields per
/// the invalidation table. Runs under the scheduler/lifecycle mutex; the
/// caller performs the returned queue action (also under the mutex).
pub fn invalidate(self: *Self) InvalidateAction {
    self.source_revision +%= 1;
    self.suppressed_epoch = null;
    switch (self.state) {
        .built => {
            self.state = .dirty;
            return if (self.queue_index == null) .enqueue else .promote;
        },
        .dirty, .unbuilt => {
            return if (self.queue_index == null) .enqueue else .promote;
        },
        .rejected => {
            // A new source revision may fit even though the previous one did
            // not. Re-enter through pack rather than retrying the same counts.
            self.discard_pending();
            self.state = .unbuilt;
            return if (self.queue_index == null) .enqueue else .promote;
        },
        .pack, .mesh_alloc, .emit => {
            if (self.owner != null) {
                // Actively compiling: the owner stops at the phase boundary.
                self.restart_requested = true;
                return .none;
            }
            // Paused in the queue, or parked in the OOM blocked set: cancel
            // the stale phase and allow pack for the new revision.
            self.discard_pending();
            self.state = if (self.geometry_valid) .dirty else .unbuilt;
            if (self.blocked_epoch != null) {
                self.blocked_epoch = null;
                return .unblock_enqueue;
            }
            return if (self.queue_index == null) .enqueue else .promote;
        },
    }
}

/// Drop uncommitted pack output. CPU mesh lists are left alone because
/// borrowed-source backends may still draw their published storage.
pub fn discard_pending(self: *Self) void {
    self.counts = .{ .opaque_verts = 0, .transparent_verts = 0, .fluid_verts = 0 };
    self.restart_requested = false;
}

/// True when the in-flight compilation no longer matches the source.
pub fn revision_stale(self: *const Self) bool {
    return self.build_revision != self.source_revision;
}

/// Lazily create mesh CPU storage and GPU handles (mesh_alloc phase).
/// Errors are OOM-containment territory for the caller; IndexOverflow from
/// MeshData.init is impossible (initial capacity is 32 vertices).
pub fn create_meshes(self: *Self, allocator: std.mem.Allocator) MeshCreateError!void {
    if (self.meshes != null) return;
    var set = try MeshSet.create_cpu(allocator);
    errdefer set.opaque_data.deinit(allocator);
    errdefer set.trans_data.deinit(allocator);
    errdefer set.fluid_data.deinit(allocator);
    try set.create_gpu();
    self.meshes = set;
}

/// Stop drawing the currently published geometry before its borrowed CPU
/// buffers are changed or released.
pub fn invalidate_geometry(self: *Self) void {
    self.geometry_valid = false;
    self.committed = .{ .opaque_verts = 0, .transparent_verts = 0, .fluid_verts = 0 };
}

/// Release all mesh resources (retirement). After this the chunk is
/// metadata only again; making it resident once more is allocation-free
/// until the next mesh_alloc.
pub fn release_meshes(self: *Self, allocator: std.mem.Allocator) void {
    if (self.meshes) |*set| set.deinit(allocator);
    self.meshes = null;
    self.invalidate_geometry();
    self.discard_pending();
    self.state = .unbuilt;
}

/// Free committed CPU storage and forget the committed geometry, keeping
/// lazily-created handles for reuse. OOM-reclaim victim path.
pub fn release_geometry(self: *Self, allocator: std.mem.Allocator) void {
    if (self.meshes) |*set| {
        set.opaque_data.clear_and_free(allocator);
        set.trans_data.clear_and_free(allocator);
        set.fluid_data.clear_and_free(allocator);
    }
    self.invalidate_geometry();
    self.discard_pending();
    self.state = .unbuilt;
}

/// Retained quad capacities, for OOM diagnostics and fit checks.
pub fn retained_quads(self: *const Self) [3]u32 {
    const set = self.meshes orelse return .{ 0, 0, 0 };
    return .{
        quad_capacity(&set.opaque_data),
        quad_capacity(&set.trans_data),
        quad_capacity(&set.fluid_data),
    };
}

fn quad_capacity(data: *const BatchMeshData) u32 {
    const verts: u32 = @intCast(data.vertices.capacity);
    return if (Rendering.mesh.indexing_enabled) verts / 4 else verts / 6;
}

pub fn update_animation(self: *Self, dt: f32) void {
    if (self.anim_progress < 1.0) {
        self.anim_progress = @min(self.anim_progress + dt, 1.0);
    }
}

pub fn center_x(self: *const Self) f32 {
    return @as(f32, @floatFromInt(@as(u32, self.coord.x) * 16)) + 8.0;
}
pub fn center_y(self: *const Self) f32 {
    return @as(f32, @floatFromInt(@as(u32, self.coord.y) * 16)) + 8.0;
}
pub fn center_z(self: *const Self) f32 {
    return @as(f32, @floatFromInt(@as(u32, self.coord.z) * 16)) + 8.0;
}

/// Draw opaque geometry only. Call front-to-back.
pub fn draw_opaque(self: *Self) void {
    if (!self.geometry_valid or self.committed.opaque_verts == 0) return;
    const set = &self.meshes.?;
    const m = self.model_matrix(scale_opaque);
    set.@"opaque".draw(&m);
}

/// Draw transparent geometry (leaves, glass, cross-plants). Call back-to-front.
pub fn draw_transparent(self: *Self) void {
    if (!self.geometry_valid or self.committed.transparent_verts == 0) return;
    const set = &self.meshes.?;
    const m = self.model_matrix(scale_trans);
    set.trans.draw(&m);
}

/// Draw fluid geometry (water, lava). Call back-to-front with depth writes off.
pub fn draw_fluid(self: *Self) void {
    if (!self.geometry_valid or self.committed.fluid_verts == 0) return;
    const set = &self.meshes.?;
    const m = self.model_matrix(scale_trans);
    set.fluid.draw(&m);
}

// SNORM dequant divides by 32768 (not 32767), so encode_pos(16) = 32767
// maps to 32767/32768 ~= 0.99997, not 1.0. Over-compensate slightly so
// chunk edges overlap by a sub-pixel amount rather than leaving a gap.
// Opaque geometry can use a larger overlap (depth test hides it);
// translucent needs a tighter fit to avoid double-blend artifacts.
const scale_opaque: f32 = if (ae.platform == .psp) 16.0 * 32768.0 / 32753.0 else 16.0;
const scale_trans: f32 = if (ae.platform == .psp) 16.0 * 32768.0 / 32763.0 else 16.0;

fn model_matrix(self: *const Self, s: f32) Math.Mat4 {
    const wx: f32 = @floatFromInt(@as(u32, self.coord.x) * 16);
    const base_wy: f32 = @floatFromInt(@as(u32, self.coord.y) * 16);
    const wz: f32 = @floatFromInt(@as(u32, self.coord.z) * 16);
    // Bouncy rise: at anim_progress=0 the chunk sits 16 blocks below its
    // natural Y, reaching rest at anim_progress=1. Stays at 1 (no offset) on
    // rebuilds and when the option is disabled.
    const wy = base_wy - 16.0 * (1.0 - self.anim_progress);
    return Math.Mat4.scaling(s, s, s).mul(Math.Mat4.translation(wx, wy, wz));
}

test "invalidate from built enqueues as dirty" {
    var chunk = Self.init(ChunkCoord.init(1, 1, 1));
    chunk.state = .built;
    chunk.geometry_valid = true;
    const rev = chunk.source_revision;
    try std.testing.expectEqual(InvalidateAction.enqueue, chunk.invalidate());
    try std.testing.expectEqual(State.dirty, chunk.state);
    try std.testing.expectEqual(rev + 1, chunk.source_revision);
}

test "invalidate from built with queue membership only promotes" {
    var chunk = Self.init(ChunkCoord.init(1, 1, 1));
    chunk.state = .built;
    chunk.geometry_valid = true;
    chunk.queue_index = 3;
    try std.testing.expectEqual(InvalidateAction.promote, chunk.invalidate());
    try std.testing.expectEqual(State.dirty, chunk.state);
}

test "invalidate while unbuilt stays unbuilt" {
    var chunk = Self.init(ChunkCoord.init(1, 1, 1));
    try std.testing.expectEqual(InvalidateAction.enqueue, chunk.invalidate());
    try std.testing.expectEqual(State.unbuilt, chunk.state);
    chunk.queue_index = 0;
    try std.testing.expectEqual(InvalidateAction.promote, chunk.invalidate());
    try std.testing.expectEqual(State.unbuilt, chunk.state);
}

test "invalidate while dirty stays dirty" {
    var chunk = Self.init(ChunkCoord.init(1, 1, 1));
    chunk.state = .dirty;
    chunk.geometry_valid = true;
    try std.testing.expectEqual(InvalidateAction.enqueue, chunk.invalidate());
    try std.testing.expectEqual(State.dirty, chunk.state);
}

test "invalidate retries a rejected source revision from unbuilt" {
    var chunk = Self.init(ChunkCoord.init(1, 1, 1));
    chunk.state = .rejected;
    chunk.counts.fluid_verts = 24;
    try std.testing.expectEqual(InvalidateAction.enqueue, chunk.invalidate());
    try std.testing.expectEqual(State.unbuilt, chunk.state);
    try std.testing.expectEqual(@as(u32, 0), chunk.counts.fluid_verts);
}

test "invalidate of an owned phase job only requests a restart" {
    var chunk = Self.init(ChunkCoord.init(1, 1, 1));
    inline for (.{ State.pack, State.mesh_alloc, State.emit }) |phase| {
        chunk = Self.init(ChunkCoord.init(1, 1, 1));
        chunk.state = phase;
        chunk.owner = 0;
        try std.testing.expectEqual(InvalidateAction.none, chunk.invalidate());
        try std.testing.expect(chunk.restart_requested);
        try std.testing.expectEqual(phase, chunk.state);
    }
}

test "invalidate of a paused phase job discards and requeues" {
    // Without committed geometry the restart rests at unbuilt.
    var chunk = Self.init(ChunkCoord.init(1, 1, 1));
    chunk.state = .emit;
    chunk.queue_index = 2;
    chunk.counts.opaque_verts = 24;
    try std.testing.expectEqual(InvalidateAction.promote, chunk.invalidate());
    try std.testing.expectEqual(State.unbuilt, chunk.state);
    try std.testing.expectEqual(@as(u32, 0), chunk.counts.opaque_verts);

    // With committed geometry it rests at dirty.
    chunk = Self.init(ChunkCoord.init(1, 1, 1));
    chunk.state = .pack;
    chunk.geometry_valid = true;
    try std.testing.expectEqual(InvalidateAction.enqueue, chunk.invalidate());
    try std.testing.expectEqual(State.dirty, chunk.state);
}

test "invalidate of an OOM-blocked job cancels the stale phase" {
    var chunk = Self.init(ChunkCoord.init(1, 1, 1));
    chunk.state = .mesh_alloc;
    chunk.blocked_epoch = 7;
    chunk.geometry_valid = true;
    try std.testing.expectEqual(InvalidateAction.unblock_enqueue, chunk.invalidate());
    try std.testing.expectEqual(State.dirty, chunk.state);
    try std.testing.expectEqual(@as(?u32, null), chunk.blocked_epoch);
}

test "invalidate clears rebuild suppression" {
    var chunk = Self.init(ChunkCoord.init(1, 1, 1));
    chunk.suppressed_epoch = 4;
    _ = chunk.invalidate();
    try std.testing.expectEqual(@as(?u32, null), chunk.suppressed_epoch);
}

test "revision staleness compares build against source" {
    var chunk = Self.init(ChunkCoord.init(1, 1, 1));
    chunk.build_revision = 5;
    chunk.source_revision = 5;
    try std.testing.expect(!chunk.revision_stale());
    chunk.source_revision = 6;
    try std.testing.expect(chunk.revision_stale());
}
