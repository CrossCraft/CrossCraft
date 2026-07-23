const std = @import("std");
const ae = @import("aether");
const Util = ae.Util;
const Rendering = ae.Rendering;

const TextureAtlas = @import("../graphics/TextureAtlas.zig").TextureAtlas;
const Colors = @import("../graphics/Color.zig");
const Color = Colors.Color;
const Camera = @import("../player/Camera.zig");
const collision = @import("../player/collision.zig");
const config = @import("../config.zig");
const Options = @import("../Options.zig");
const c = @import("common").consts;

const limits = @import("chunk/ChunkCoord.zig");
const ChunkCoord = limits.ChunkCoord;
const WorldShape = limits.WorldShape;
const Chunk = @import("chunk/Chunk.zig");
const ChunkStore = @import("chunk/ChunkStore.zig");
const Scheduler = @import("chunk/Scheduler.zig");
const Compiler = @import("chunk/Compiler.zig");
const PriorityClass = Scheduler.PriorityClass;
const Sky = @import("sky/sky.zig");
const ParticleSystem = @import("ParticleSystem.zig");
const Rain = @import("Rain.zig");

const SlotIndex = ChunkStore.SlotIndex;

const Self = @This();

/// Block/chunk dimensions of the loaded world. Chunk residency is
/// independent per 16x16x16 chunk; there is no column lifecycle.
shape: WorldShape,
store: ChunkStore,
scheduler: Scheduler,
compiler: Compiler,

/// Per-frame visibility list populated by draw_world_pass and consumed by
/// draw_fluid_pass so the caller can slot overlays (selection outline, steve
/// models) between the two passes without recomputing visibility.
frame_visible: []SlotIndex,
frame_visible_count: u32,
frame_clip_count: u32,

terrain: *const Rendering.Texture,
clouds: *const Rendering.Texture,
rain_tex: *const Rendering.Texture,
particles_tex: *const Rendering.Texture,
atlas: TextureAtlas,
sky: Sky,
particles: ParticleSystem,
rain: Rain,
cam_cx: i32,
cam_cz: i32,
/// Camera position at the last LOD check. refresh_lod_targets only runs when
/// the camera has moved at least 1 block since this was recorded.
lod_check_x: f32,
lod_check_y: f32,
lod_check_z: f32,
/// Last render-affecting option values applied to resident chunks. When one
/// diverges from Options.current, update() invalidates the affected chunks
/// through the revision path so changes show up immediately.
applied_render_distance: u8,
applied_fancy_leaves: bool,
applied_ao: bool,
allocator: std.mem.Allocator,
io: std.Io,

pub fn init_in_place(
    self: *Self,
    allocator: std.mem.Allocator,
    io: std.Io,
    terrain: *const Rendering.Texture,
    clouds: *const Rendering.Texture,
    rain_tex: *const Rendering.Texture,
    particles_tex: *const Rendering.Texture,
    atlas: TextureAtlas,
    camera: *const Camera,
) !void {
    self.shape = WorldShape.init(c.WorldLength, c.WorldHeight, c.WorldDepth) catch unreachable;
    const capacity = config.max_active_chunks();
    self.store = try ChunkStore.init(allocator, capacity);
    errdefer self.store.deinit();
    self.scheduler = try Scheduler.init(allocator, capacity);
    errdefer self.scheduler.deinit(allocator);
    self.compiler = try Compiler.init(allocator, capacity);
    errdefer self.compiler.deinit(allocator);
    self.frame_visible = try allocator.alloc(SlotIndex, capacity);
    errdefer allocator.free(self.frame_visible);
    self.frame_visible_count = 0;
    self.frame_clip_count = 0;
    self.terrain = terrain;
    self.clouds = clouds;
    self.rain_tex = rain_tex;
    self.particles_tex = particles_tex;
    self.atlas = atlas;
    self.cam_cx = camera_chunk(camera.x);
    self.cam_cz = camera_chunk(camera.z);
    self.lod_check_x = camera.x;
    self.lod_check_y = camera.y;
    self.lod_check_z = camera.z;
    self.applied_render_distance = Options.capped_render_distance();
    self.applied_fancy_leaves = Options.current.fancy_leaves;
    self.applied_ao = Options.current.ambient_occlusion;
    self.allocator = allocator;
    self.io = io;
    self.scheduler.set_camera(&self.store, camera);

    self.sky = try Sky.init(allocator);
    errdefer self.sky.deinit();
    self.particles = try ParticleSystem.init(allocator, atlas);
    errdefer self.particles.deinit();
    self.rain = try Rain.init(allocator);
    errdefer self.rain.deinit();

    self.sync_residency(camera);

    // Warm up the phase estimators with real work, budget-free and bounded.
    var guard: u32 = 4 * self.store.capacity() + 8;
    while (self.compiler.warming() and guard > 0) : (guard -= 1) {
        const status = self.compiler.step(&self.drive(), std.math.maxInt(i64));
        if (status == .idle) break;
    }
}

pub fn deinit(self: *Self) void {
    self.rain.deinit();
    self.particles.deinit();
    self.sky.deinit();
    self.allocator.free(self.frame_visible);
    self.compiler.deinit(self.allocator);
    self.scheduler.deinit(self.allocator);
    self.store.deinit();
}

fn drive(self: *Self) Compiler.Drive {
    return .{
        .store = &self.store,
        .scheduler = &self.scheduler,
        .allocator = self.allocator,
        .atlas = &self.atlas,
        .io = self.io,
    };
}

pub fn update(self: *Self, dt: f32, budget: *const Util.BudgetContext, camera: *const Camera) void {
    self.sky.update(dt);
    self.particles.update(dt, camera);
    self.rain.update(dt, camera);

    self.compiler.begin_frame();
    self.scheduler.set_camera(&self.store, camera);

    // Advance the bouncy-rise animation for every resident chunk. Runs
    // before the compiler drive below so the animation keeps ticking even
    // when there is no pending work. Chunks at rest short-circuit.
    for (self.store.slots) |*slot| {
        if (slot.active) slot.chunk.update_animation(dt);
    }

    const new_cx = camera_chunk(camera.x);
    const new_cz = camera_chunk(camera.z);
    if (new_cx != self.cam_cx or new_cz != self.cam_cz or Options.capped_render_distance() != self.applied_render_distance) {
        self.sync_residency(camera);
    }

    // AO toggle: one bool compare per frame; on mismatch, every resident
    // chunk whose captured state disagrees gets a revision invalidation.
    if (Options.current.ambient_occlusion != self.applied_ao) {
        self.apply_ao_toggle();
    }

    // Fancy/fast leaves changes alter the near_lod target globally. Treat
    // this like an LOD transition now instead of waiting for camera movement.
    if (Options.current.fancy_leaves != self.applied_fancy_leaves) {
        self.apply_fancy_leaves_toggle(camera);
    }

    // Catch LOD transitions mid-chunk only when the camera has moved at
    // least 1 block since the last check. Skipped entirely on stationary
    // frames, eliminating the previous per-frame distance scan.
    const lod_dx = camera.x - self.lod_check_x;
    const lod_dy = camera.y - self.lod_check_y;
    const lod_dz = camera.z - self.lod_check_z;
    if (lod_dx * lod_dx + lod_dy * lod_dy + lod_dz * lod_dz >= 1.0) {
        self.refresh_lod_targets(camera);
        self.lod_check_x = camera.x;
        self.lod_check_y = camera.y;
        self.lod_check_z = camera.z;
    }

    // Drive the compiler: one executor, at most one phase per step. During
    // estimator warmup exactly one phase runs per frame (the old bounded
    // warmup policy); afterwards a phase starts only when its estimate fits
    // the remaining frame budget.
    var remaining = budget.safe_remaining();
    var steps: u32 = 0;
    const max_steps: u32 = 4 * self.store.capacity() + 8;
    while (steps < max_steps) : (steps += 1) {
        const status = self.compiler.step(&self.drive(), remaining);
        if (!continue_after_compiler_step(
            status,
            self.compiler.warming(),
            self.compiler.last_phase_ns,
            &remaining,
        )) break;
    }
}

fn continue_after_compiler_step(
    status: Compiler.Status,
    warming: bool,
    elapsed_ns: i64,
    remaining_ns: *i64,
) bool {
    switch (status) {
        .idle, .deferred => return false,
        .oom_blocked, .phase_complete, .built => {
            remaining_ns.* -= elapsed_ns;
            return !warming and remaining_ns.* > 0;
        },
    }
}

/// Draw everything up to and including particles; callers are expected to
/// invoke draw_fluid_pass afterwards so water/lava draws over overlays like
/// the block selection outline. Populates frame_visible/frame_clip_count.
pub fn draw_world_pass(self: *Self, camera: *const Camera) void {
    const submerged = collision.liquid_at_point(camera.x, camera.y, camera.z);

    Rendering.gfx.api.bind_texture(Rendering.Texture.Default.handle);
    Sky.clear(submerged);
    self.sky.draw_plane(camera, submerged);

    set_terrain_fog(submerged);
    Rendering.gfx.api.bind_texture(self.terrain.handle);

    self.frame_visible_count = 0;
    for (self.store.slots, 0..) |*slot, i| {
        if (!slot.active) continue;
        const coord = slot.chunk.coord;
        if (!camera.section_visible(coord.x, coord.y, coord.z)) continue;
        self.frame_visible[self.frame_visible_count] = @intCast(i);
        self.frame_visible_count += 1;
    }

    const visible = self.frame_visible[0..self.frame_visible_count];
    const sort_ctx: SlotSortCtx = .{ .store = &self.store, .cam = camera };
    std.sort.pdq(SlotIndex, visible, sort_ctx, slot_less_than);

    // Chunks close to the player need hardware clip planes to prevent
    // vertices from overflowing the PSP 4096 virtual viewport.
    const CLIP_CHUNK_COUNT: u32 = 4;
    self.frame_clip_count = @min(CLIP_CHUNK_COUNT, self.frame_visible_count);
    const clip_count = self.frame_clip_count;

    // Opaque pass (front-to-back): clip planes on for closest chunks
    Rendering.gfx.api.set_alpha_blend(false);
    if (clip_count > 0) {
        Rendering.gfx.api.set_clip_planes(true);
        for (visible[0..clip_count]) |slot| {
            self.store.chunk(slot).draw_opaque();
        }
        Rendering.gfx.api.set_clip_planes(false);
    }
    for (visible[clip_count..]) |slot| {
        self.store.chunk(slot).draw_opaque();
    }

    // Clouds are a physical layer at Y=72. Draw after opaque (so terrain
    // occludes them) but before transparent/fluid (so leaves, glass, and
    // water alpha-blend against the cloud layer behind them).
    Rendering.gfx.api.bind_texture(self.clouds.handle);
    self.sky.draw_clouds(camera, submerged);

    // Transparent pass (back-to-front): non-fluid (leaves, glass, cross-plants).
    // Depth writes stay on so leaves properly occlude geometry behind them.
    set_terrain_fog(submerged);
    Rendering.gfx.api.bind_texture(self.terrain.handle);
    Rendering.gfx.api.set_alpha_blend(true);
    var ri: u32 = self.frame_visible_count;
    while (ri > clip_count) {
        ri -= 1;
        self.store.chunk(visible[ri]).draw_transparent();
    }
    if (clip_count > 0) {
        Rendering.gfx.api.set_clip_planes(true);
        while (ri > 0) {
            ri -= 1;
            self.store.chunk(visible[ri]).draw_transparent();
        }
        Rendering.gfx.api.set_clip_planes(false);
    }

    // Particles between transparent and fluid so they depth-test against
    // opaque + transparent geometry and blend before water is drawn.
    self.particles.draw();
}

/// Draw rain streaks + impact splashes.  Slots between draw_world_pass and
/// the selection/fluid overlays so streaks depth-test against terrain and
/// blend over particles.  No-op when the rain option is off.
pub fn draw_rain_pass(self: *Self, camera: *const Camera) void {
    if (!Options.current.rain) return;
    Rendering.gfx.api.bind_texture(self.rain_tex.handle);
    self.rain.draw_streaks(camera);
    Rendering.gfx.api.bind_texture(self.particles_tex.handle);
    self.rain.draw_splashes();
}

/// Draw the fluid (water/lava) pass. Must be called after draw_world_pass on
/// the same frame; consumes the visibility list populated there. Kept
/// separate so overlays (selection outline, remote players) drawn between
/// the two passes are correctly occluded by fluid surfaces.
pub fn draw_fluid_pass(self: *Self) void {
    const visible = self.frame_visible[0..self.frame_visible_count];
    const clip_count = self.frame_clip_count;

    Rendering.gfx.api.bind_texture(self.terrain.handle);
    Rendering.gfx.api.set_alpha_blend(true);

    // Fluid pass (back-to-front): water/lava drawn with depth writes off so
    // fluid faces never occlude each other across chunk borders.
    Rendering.gfx.api.set_depth_write(false);
    var ri: u32 = self.frame_visible_count;
    while (ri > clip_count) {
        ri -= 1;
        self.store.chunk(visible[ri]).draw_fluid();
    }
    if (clip_count > 0) {
        Rendering.gfx.api.set_clip_planes(true);
        while (ri > 0) {
            ri -= 1;
            self.store.chunk(visible[ri]).draw_fluid();
        }
        Rendering.gfx.api.set_clip_planes(false);
    }
    Rendering.gfx.api.set_depth_write(true);
}

// --- Residency ---

/// True when a chunk's XZ center is inside the render-distance circle.
fn desired(self: *const Self, coord: ChunkCoord, camera: *const Camera, radius_sq: f32) bool {
    _ = self;
    const ccx: f32 = @as(f32, @floatFromInt(@as(u32, coord.x) * 16)) + 8.0;
    const ccz: f32 = @as(f32, @floatFromInt(@as(u32, coord.z) * 16)) + 8.0;
    const dx = ccx - camera.x;
    const dz = ccz - camera.z;
    return dx * dx + dz * dz <= radius_sq;
}

/// One chunk-residency pass replacing the old column recollect: retire
/// chunks no longer desired, then give every desired coordinate an
/// independent slot and an initial job. No column object is created; one
/// failed Y chunk never rolls back its vertical neighbors.
fn sync_residency(self: *Self, camera: *const Camera) void {
    self.cam_cx = camera_chunk(camera.x);
    self.cam_cz = camera_chunk(camera.z);
    self.applied_render_distance = Options.capped_render_distance();

    const rd: u32 = self.applied_render_distance;
    const r: i32 = @intCast(rd);
    const radius_blocks: f32 = @as(f32, @floatFromInt(rd)) * 16.0 + 11.5;
    const radius_sq = radius_blocks * radius_blocks;

    // Phase 1: retire active chunks no longer desired.
    for (self.store.slots, 0..) |*slot, i| {
        if (!slot.active) continue;
        if (self.desired(slot.chunk.coord, camera, radius_sq)) continue;
        self.retire_slot(@intCast(i));
    }

    // Phase 2: ensure every desired coordinate is resident with an initial
    // job. A full store leaves the coordinate for a later pass; no other
    // chunk is disturbed.
    var dx: i32 = -r;
    while (dx <= r) : (dx += 1) {
        var dz: i32 = -r;
        while (dz <= r) : (dz += 1) {
            const cx_i = self.cam_cx + dx;
            const cz_i = self.cam_cz + dz;
            if (cx_i < 0 or cx_i >= @as(i32, @intCast(self.shape.chunks_x)) or
                cz_i < 0 or cz_i >= @as(i32, @intCast(self.shape.chunks_z))) continue;
            var y: u32 = 0;
            while (y < self.shape.chunks_y) : (y += 1) {
                const coord = ChunkCoord.init(@intCast(cx_i), y, @intCast(cz_i));
                if (!self.desired(coord, camera, radius_sq)) continue;
                self.ensure_resident(coord, target_near_lod(coord, camera));
            }
        }
    }

    // Phase 3: resident unbuilt chunks that lost queue membership without
    // being suppressed or OOM-blocked (e.g. an earlier pass found the store
    // full) get their initial job now.
    for (self.store.slots, 0..) |_, i| self.enqueue_unbuilt(@intCast(i));

    // init targets were set up front for the new chunks; sync the check
    // position so update() does not fire a redundant refresh next frame.
    self.lod_check_x = camera.x;
    self.lod_check_y = camera.y;
    self.lod_check_z = camera.z;
}

/// Coordinate lookup, slot reuse, initialization, and first enqueue are one
/// lifecycle transition so a packet invalidator cannot observe a partial
/// residency or an old generation.
fn ensure_resident(self: *Self, coord: ChunkCoord, near_lod: bool) void {
    self.scheduler.lock();
    defer self.scheduler.unlock();
    if (self.store.lookup(coord) != null) return;
    const slot = self.store.ensure(coord) orelse return;
    const chunk = self.store.chunk(slot);
    chunk.near_lod = near_lod;
    chunk.ao_enabled = Options.current.ambient_occlusion;
    self.scheduler.append_unlocked(&self.store, slot, self.scheduler.classify_snapshot(chunk));
}

fn enqueue_unbuilt(self: *Self, slot: SlotIndex) void {
    self.scheduler.lock();
    defer self.scheduler.unlock();
    if (!self.store.slots[slot].active) return;
    const chunk = self.store.chunk(slot);
    if (chunk.state != .unbuilt) return;
    if (chunk.queue_index != null or chunk.owner != null) return;
    if (chunk.blocked_epoch != null) return;
    if (chunk.suppressed_epoch) |epoch| {
        // Suppression lasts only while the reclaim epoch that produced it is
        // current; a later epoch lets the chunk rebuild.
        if (epoch == self.compiler.reclaim_epoch) return;
        chunk.suppressed_epoch = null;
    }
    self.scheduler.append_unlocked(&self.store, slot, self.scheduler.classify_snapshot(chunk));
}

fn retire_slot(self: *Self, slot: SlotIndex) void {
    // The synchronous one-executor driver never owns a chunk between steps,
    // so retirement cannot race an in-flight phase.
    self.scheduler.lock();
    std.debug.assert(self.store.chunk(slot).owner == null);
    self.scheduler.cancel_unlocked(&self.store, slot);
    self.compiler.remove_blocked(&self.store, slot);
    const had_meshes = self.store.chunk(slot).meshes != null;
    self.store.retire(slot);
    self.scheduler.unlock();
    // A real free: blocked jobs may retry against the new epoch.
    if (had_meshes) self.compiler.note_external_free(&self.drive());
}

// --- Invalidation ---

/// Route one invalidation through the chunk's revision path and perform
/// the returned queue action. `class` overrides the computed priority
/// (used for ordered interactive block changes). Caller holds the lifecycle
/// mutex from lookup through queue mutation.
fn invalidate_chunk_unlocked(self: *Self, slot: SlotIndex, class: ?PriorityClass) void {
    const action = self.store.chunk(slot).invalidate();
    const chunk = self.store.chunk(slot);
    const priority_class = class orelse self.scheduler.classify_snapshot(chunk);
    if (action == .unblock_enqueue) self.compiler.remove_blocked(&self.store, slot);
    // Active owners record a pending replacement priority; queued/resting
    // chunks are promoted or enqueued immediately.
    self.scheduler.append_unlocked(&self.store, slot, priority_class);
}

fn invalidate_chunk(self: *Self, slot: SlotIndex, class: ?PriorityClass) void {
    self.scheduler.lock();
    self.invalidate_chunk_unlocked(slot, class);
    self.scheduler.unlock();
    self.rain.mark_dirty();
}

/// Mark a chunk for rebuild (e.g. after a lighting change).
pub fn mark_section_dirty(self: *Self, cx: u8, sy: u8, cz: u8) void {
    self.mark_dirty_impl(cx, sy, cz, null);
}

fn mark_dirty_impl(self: *Self, cx: u32, sy: u32, cz: u32, class: ?PriorityClass) void {
    if (cx >= self.shape.chunks_x or sy >= self.shape.chunks_y or cz >= self.shape.chunks_z) return;
    self.scheduler.lock();
    const slot = self.store.lookup(ChunkCoord.init(cx, sy, cz));
    if (slot) |resident| self.invalidate_chunk_unlocked(resident, class);
    self.scheduler.unlock();
    if (slot != null) self.rain.mark_dirty();
}

/// Mark the affected chunks for a single block mutation in an order that
/// avoids one-frame gaps at chunk edges. Removals rebuild neighbors before
/// the owner so newly exposed neighbor faces are hidden by the old owner mesh
/// until the owner rebuild commits. Additions do the inverse.
pub fn mark_block_change_dirty(self: *Self, cx: u8, sy: u8, cz: u8, lx: u16, ly: u16, lz: u16, removing: bool) void {
    self.scheduler.lock();
    if (removing) {
        self.mark_block_neighbor_chunks_dirty_unlocked(cx, sy, cz, lx, ly, lz);
        self.mark_dirty_unlocked(cx, sy, cz, .interactive);
    } else {
        self.mark_dirty_unlocked(cx, sy, cz, .interactive);
        self.mark_block_neighbor_chunks_dirty_unlocked(cx, sy, cz, lx, ly, lz);
    }
    self.scheduler.unlock();
    self.rain.mark_dirty();
}

fn mark_dirty_unlocked(self: *Self, cx: u32, sy: u32, cz: u32, class: ?PriorityClass) void {
    if (cx >= self.shape.chunks_x or sy >= self.shape.chunks_y or cz >= self.shape.chunks_z) return;
    const slot = self.store.lookup(ChunkCoord.init(cx, sy, cz)) orelse return;
    self.invalidate_chunk_unlocked(slot, class);
}

fn mark_block_neighbor_chunks_dirty_unlocked(self: *Self, cx: u8, sy: u8, cz: u8, lx: u16, ly: u16, lz: u16) void {
    if (lx == 0 and cx > 0) self.mark_dirty_unlocked(cx - 1, sy, cz, .interactive);
    if (lx == 15) self.mark_dirty_unlocked(cx + 1, sy, cz, .interactive);
    if (lz == 0 and cz > 0) self.mark_dirty_unlocked(cx, sy, cz - 1, .interactive);
    if (lz == 15) self.mark_dirty_unlocked(cx, sy, cz + 1, .interactive);
    if (ly == 0 and sy > 0) self.mark_dirty_unlocked(cx, sy - 1, cz, .interactive);
    if (ly == 15) self.mark_dirty_unlocked(cx, sy + 1, cz, .interactive);
}

/// Flip the AO target on every resident chunk whose state disagrees with
/// Options.current.ambient_occlusion, and invalidate through the revision
/// path so the affected chunks re-mesh with the new AO state. Only called
/// on the frame the option actually changes.
fn apply_ao_toggle(self: *Self) void {
    const target = Options.current.ambient_occlusion;
    for (self.store.slots, 0..) |*slot, i| {
        if (!slot.active) continue;
        if (slot.chunk.ao_enabled != target) {
            slot.chunk.ao_enabled = target;
            self.invalidate_chunk(@intCast(i), null);
        }
    }
    self.applied_ao = target;
}

/// Recompute leaf LOD targets after the Fancy Leaves option changes, and
/// invalidate only chunks whose effective leaf mesh needs to change.
fn apply_fancy_leaves_toggle(self: *Self, cam: *const Camera) void {
    self.refresh_lod_targets(cam);
    self.applied_fancy_leaves = Options.current.fancy_leaves;
    self.lod_check_x = cam.x;
    self.lod_check_y = cam.y;
    self.lod_check_z = cam.z;
}

/// Walk resident chunks and update their LOD targets. Chunks that cross
/// the configured near-LOD boundary in either direction get invalidated so
/// they re-mesh with the new detail level.
fn refresh_lod_targets(self: *Self, cam: *const Camera) void {
    for (self.store.slots, 0..) |*slot, i| {
        if (!slot.active) continue;
        const target = target_near_lod(slot.chunk.coord, cam);
        if (slot.chunk.near_lod != target) {
            slot.chunk.near_lod = target;
            self.invalidate_chunk(@intCast(i), null);
        }
    }
}

const SlotSortCtx = struct {
    store: *const ChunkStore,
    cam: *const Camera,
};

fn slot_less_than(ctx: SlotSortCtx, a: SlotIndex, b: SlotIndex) bool {
    const ca = &ctx.store.slots[a].chunk;
    const cb = &ctx.store.slots[b].chunk;
    return ctx.cam.distance_sq(ca.center_x(), ca.center_y(), ca.center_z()) <
        ctx.cam.distance_sq(cb.center_x(), cb.center_y(), cb.center_z());
}

/// True when a chunk's center is within the runtime near-LOD radius.
/// Returns false immediately when fancy leaves are disabled so all chunks
/// get the fast/opaque-leaves mesh regardless of distance.
fn target_near_lod(coord: ChunkCoord, cam: *const Camera) bool {
    if (!Options.current.fancy_leaves) return false;
    const lod_near_radius: f32 = @floatFromInt(config.current().lod_near_radius_blocks);
    const lod_near_radius_sq = lod_near_radius * lod_near_radius;
    const wx: f32 = @as(f32, @floatFromInt(@as(u32, coord.x) * 16)) + 8.0;
    const wy: f32 = @as(f32, @floatFromInt(@as(u32, coord.y) * 16)) + 8.0;
    const wz: f32 = @as(f32, @floatFromInt(@as(u32, coord.z) * 16)) + 8.0;
    return cam.distance_sq(wx, wy, wz) <= lod_near_radius_sq;
}

fn camera_chunk(pos: f32) i32 {
    const v = @floor(pos / 16.0);
    if (v < -2147483648.0 or v > 2147483647.0) return 0;
    return @intFromFloat(v);
}

fn set_terrain_fog(submerged: ?collision.Liquid) void {
    const col = switch (submerged orelse .water) {
        .water => if (submerged != null) Colors.game_underwater else Colors.game_daytime,
        .lava => Colors.game_underlava,
    };
    const fog_end: f32 = switch (submerged orelse .water) {
        .water => if (submerged != null) 16.0 else blk: {
            const rd: f32 = @floatFromInt(Options.capped_render_distance());
            break :blk @max(rd * 16.0 - 16.0, 16.0);
        },
        .lava => 2.0,
    };
    const fog_start: f32 = if (submerged != null) 0.0 else fog_end * 0.4;
    Rendering.gfx.api.set_fog(
        Options.current.fog or submerged != null,
        fog_start,
        fog_end,
        @as(f32, @floatFromInt(col.r)) / 255.0,
        @as(f32, @floatFromInt(col.g)) / 255.0,
        @as(f32, @floatFromInt(col.b)) / 255.0,
    );
}

test "OOM compiler phases consume budget and obey warmup" {
    var remaining: i64 = 1_000;
    try std.testing.expect(continue_after_compiler_step(.oom_blocked, false, 400, &remaining));
    try std.testing.expectEqual(@as(i64, 600), remaining);

    try std.testing.expect(!continue_after_compiler_step(.oom_blocked, true, 200, &remaining));
    try std.testing.expectEqual(@as(i64, 400), remaining);

    remaining = 300;
    try std.testing.expect(!continue_after_compiler_step(.oom_blocked, false, 400, &remaining));
    try std.testing.expectEqual(@as(i64, -100), remaining);

    remaining = 300;
    try std.testing.expect(!continue_after_compiler_step(.deferred, false, 400, &remaining));
    try std.testing.expectEqual(@as(i64, 300), remaining);
}
