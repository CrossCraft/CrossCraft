const std = @import("std");
const ae = @import("aether");
const Util = ae.Util;
const Rendering = ae.Rendering;

const TextureAtlas = @import("../graphics/TextureAtlas.zig").TextureAtlas;
const Color = @import("../graphics/Color.zig").Color;
const Camera = @import("../player/Camera.zig");
const collision = @import("../player/collision.zig");
const config = @import("../config.zig");
const Options = @import("../Options.zig");

const ChunkMesh = @import("chunk/ChunkMesh.zig");
const Sky = @import("sky/sky.zig");
const ParticleSystem = @import("ParticleSystem.zig");
const Rain = @import("Rain.zig");

const SECTIONS_Y: u32 = 4;
const WORLD_CX: u32 = 16;
const WORLD_CZ: u32 = 16;
const MAX_ACTIVE: u32 = @import("../config.zig").max_sections();

/// Maximum sections tracked incrementally in dirty_buf before falling back to
/// a full queue rescan. Sized for 4 simultaneous block changes * 7 neighbors.
const MAX_DIRTY_BUF: u32 = 32;

const Self = @This();

/// Grid of sections. Only valid where loaded[cx][cz] is true.
grid: [WORLD_CX][WORLD_CZ][SECTIONS_Y]ChunkMesh,
/// Per-column: all 4 sections have GPU handles allocated.
loaded: [WORLD_CX][WORLD_CZ]bool,
/// Per-section: mesh has been built via rebuild().
built: [WORLD_CX][WORLD_CZ][SECTIONS_Y]bool,
/// Per-section: currently present in build_queue[build_cursor..build_end].
in_queue: [WORLD_CX][WORLD_CZ][SECTIONS_Y]bool,
/// Sections marked dirty since the last flush, for incremental queue insert.
/// dirty_overflow is set when the buffer is full; triggers a full rescan.
dirty_buf: [MAX_DIRTY_BUF]GridRef,
dirty_buf_len: u32,
dirty_overflow: bool,
/// Preserve dirty_buf order and move those sections ahead of background
/// rebuilds. Used for block changes where edge rebuild order affects flicker.
dirty_preserve_order: bool,
/// Camera position at the last LOD check. refresh_lod_states only runs when
/// the camera has moved at least 1 block since this was recorded.
lod_check_x: f32,
lod_check_y: f32,
lod_check_z: f32,
/// Last render-affecting option values applied to loaded sections. When one
/// diverges from Options.current, update() kicks the same paths that normally
/// run on camera movement so changes made from the options menu show up
/// immediately.
applied_render_distance: u8,
applied_fancy_leaves: bool,
applied_ao: bool,

build_queue: [MAX_ACTIVE]GridRef,
build_cursor: u32,
build_end: u32,
build_estimator: Util.Estimator,

/// Per-frame visibility list populated by draw_world_pass and consumed by
/// draw_fluid_pass so the caller can slot overlays (selection outline, steve
/// models) between the two passes without recomputing visibility.
frame_visible: [MAX_ACTIVE]GridRef,
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
allocator: std.mem.Allocator,
io: std.Io,

const GridRef = packed struct { cx: u8, cz: u8, sy: u8 };

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
    const row_false = [_]bool{false} ** WORLD_CZ;
    const section_false = [_]bool{false} ** SECTIONS_Y;
    const col_section_false = [_][SECTIONS_Y]bool{section_false} ** WORLD_CZ;
    self.grid = undefined;
    self.loaded = .{row_false} ** WORLD_CX;
    self.built = .{col_section_false} ** WORLD_CX;
    self.in_queue = .{col_section_false} ** WORLD_CX;
    self.dirty_buf = undefined;
    self.dirty_buf_len = 0;
    self.dirty_overflow = false;
    self.dirty_preserve_order = false;
    self.lod_check_x = camera.x;
    self.lod_check_y = camera.y;
    self.lod_check_z = camera.z;
    self.applied_render_distance = Options.capped_render_distance();
    self.applied_fancy_leaves = Options.current.fancy_leaves;
    self.applied_ao = Options.current.ambient_occlusion;
    self.build_queue = undefined;
    self.build_cursor = 0;
    self.build_end = 0;
    self.build_estimator = Util.Estimator.init();
    self.frame_visible = undefined;
    self.frame_visible_count = 0;
    self.frame_clip_count = 0;
    self.terrain = terrain;
    self.clouds = clouds;
    self.rain_tex = rain_tex;
    self.particles_tex = particles_tex;
    self.atlas = atlas;
    self.cam_cx = camera_chunk(camera.x);
    self.cam_cz = camera_chunk(camera.z);
    self.allocator = allocator;
    self.io = io;

    self.sky = try Sky.init(allocator);
    errdefer self.sky.deinit();
    self.particles = try ParticleSystem.init(allocator, atlas);
    errdefer self.particles.deinit();
    self.rain = try Rain.init(allocator);
    errdefer self.rain.deinit();

    self.recollect(camera);

    // Warm up the estimator
    while (self.build_cursor < self.build_end and self.build_estimator.is_warming_up()) {
        const ref = self.build_queue[self.build_cursor];
        self.build_estimator.begin(io);
        self.grid[ref.cx][ref.cz][ref.sy].rebuild(&self.atlas) catch break;
        self.build_estimator.end(io);
        mark_first_built(&self.grid[ref.cx][ref.cz][ref.sy]);
        self.built[ref.cx][ref.cz][ref.sy] = true;
        self.in_queue[ref.cx][ref.cz][ref.sy] = false;
        self.build_cursor += 1;
    }
}

pub fn deinit(self: *Self) void {
    self.rain.deinit();
    self.particles.deinit();
    self.sky.deinit();
    for (0..WORLD_CX) |cx| {
        for (0..WORLD_CZ) |cz| {
            if (!self.loaded[cx][cz]) continue;
            self.deinit_column(@intCast(cx), @intCast(cz));
        }
    }
}

pub fn update(self: *Self, dt: f32, budget: *const Util.BudgetContext, camera: *const Camera) void {
    self.sky.update(dt);
    self.particles.update(dt, camera);
    self.rain.update(dt, camera);

    // Advance the bouncy-rise animation for every loaded section. Runs before
    // the early-return below so the animation keeps ticking even when there
    // are no pending rebuilds. Sections already at rest short-circuit.
    for (0..WORLD_CX) |cx| {
        for (0..WORLD_CZ) |cz| {
            if (!self.loaded[cx][cz]) continue;
            for (0..SECTIONS_Y) |sy| {
                self.grid[cx][cz][sy].update_animation(dt);
            }
        }
    }

    const new_cx = camera_chunk(camera.x);
    const new_cz = camera_chunk(camera.z);
    if (new_cx != self.cam_cx or new_cz != self.cam_cz or Options.capped_render_distance() != self.applied_render_distance) {
        self.recollect(camera);
    }

    // AO toggle: one bool compare per frame; on mismatch, every loaded
    // section needs a rebuild since AO is global.
    if (Options.current.ambient_occlusion != self.applied_ao) {
        self.apply_ao_toggle();
    }

    // Fancy/fast leaves changes alter the near_lod target globally. Treat this
    // like an LOD transition now instead of waiting for camera movement.
    if (Options.current.fancy_leaves != self.applied_fancy_leaves) {
        self.apply_fancy_leaves_toggle(camera);
    }

    // Catch LOD transitions mid-chunk only when the camera has moved at
    // least 1 block since the last check. Skipped entirely on stationary
    // frames, eliminating the previous O(1024) per-frame distance scan.
    const lod_dx = camera.x - self.lod_check_x;
    const lod_dy = camera.y - self.lod_check_y;
    const lod_dz = camera.z - self.lod_check_z;
    if (lod_dx * lod_dx + lod_dy * lod_dy + lod_dz * lod_dz >= 1.0) {
        self.refresh_lod_states(camera);
        self.lod_check_x = camera.x;
        self.lod_check_y = camera.y;
        self.lod_check_z = camera.z;
    }

    // Re-queue dirty sections immediately so a player break/place shows up
    // this frame even while a heavy LOD rebuild is in flight. When only a
    // few sections changed, flush_dirty_sections inserts them directly into
    // the live queue without a full rescan.
    if (self.dirty_overflow) {
        self.queue_unbuilt_sections(camera);
        self.dirty_overflow = false;
        self.dirty_buf_len = 0;
        self.dirty_preserve_order = false;
    } else if (self.dirty_buf_len > 0) {
        self.flush_dirty_sections(camera);
        self.dirty_buf_len = 0;
        self.dirty_preserve_order = false;
    }

    if (self.build_cursor >= self.build_end) return;

    const available = budget.safe_remaining();
    const n: u32 = if (self.build_estimator.is_warming_up())
        1
    else
        @intCast(@max(1, self.build_estimator.fit_in(available, .p75)));
    const end = @min(self.build_cursor + n, self.build_end);

    for (self.build_cursor..end) |i| {
        const ref = self.build_queue[i];
        self.build_estimator.begin(self.io);
        if (self.grid[ref.cx][ref.cz][ref.sy].rebuild(&self.atlas)) {
            self.build_estimator.end(self.io);
        } else |_| {
            self.build_estimator.end(self.io);
            // Mesh allocation/indexing failure - evict the farthest built
            // section to free GPU memory, then stop for this frame. The
            // cursor stays at i so this section is retried first next frame
            // rather than rebuilding it
            // twice in one frame.
            _ = self.try_evict_farthest(camera);
            self.build_cursor = @intCast(i);
            return;
        }
        mark_first_built(&self.grid[ref.cx][ref.cz][ref.sy]);
        self.built[ref.cx][ref.cz][ref.sy] = true;
        self.in_queue[ref.cx][ref.cz][ref.sy] = false;
    }
    self.build_cursor = end;
}

/// Clears first_build and, on the first build only, starts the bouncy-rise
/// animation if the option is enabled. Called after a successful rebuild().
fn mark_first_built(sec: *ChunkMesh) void {
    if (!sec.first_build) return;
    sec.first_build = false;
    if (Options.current.bouncy_chunks) sec.anim_progress = 0.0;
}

/// Draw everything up to and including particles; callers are expected to
/// invoke draw_fluid_pass afterwards so water/lava draws over overlays like
/// the block selection outline. Populates frame_visible/frame_clip_count.
pub fn draw_world_pass(self: *Self, camera: *const Camera) void {
    const submerged = collision.liquid_at_point(camera.x, camera.y, camera.z);

    Rendering.Texture.Default.bind();
    Sky.clear(submerged);
    self.sky.draw_plane(camera, submerged);

    set_terrain_fog(submerged);
    self.terrain.bind();

    self.frame_visible_count = 0;
    for (0..WORLD_CX) |cx| {
        for (0..WORLD_CZ) |cz| {
            if (!self.loaded[cx][cz]) continue;
            for (0..SECTIONS_Y) |sy| {
                const sec = &self.grid[cx][cz][sy];
                if (!camera.section_visible(sec.cx, sec.sy, sec.cz)) continue;
                self.frame_visible[self.frame_visible_count] = .{ .cx = @intCast(cx), .cz = @intCast(cz), .sy = @intCast(sy) };
                self.frame_visible_count += 1;
            }
        }
    }

    const visible = self.frame_visible[0..self.frame_visible_count];
    std.sort.pdq(GridRef, visible, camera, grid_ref_less_than);

    // Sections close to the player need hardware clip planes to prevent
    // vertices from overflowing the PSP 4096 virtual viewport.
    const CLIP_SECTION_COUNT: u32 = 4;
    self.frame_clip_count = @min(CLIP_SECTION_COUNT, self.frame_visible_count);
    const clip_count = self.frame_clip_count;

    // Opaque pass (front-to-back): clip planes on for closest sections
    Rendering.gfx.api.set_alpha_blend(false);
    if (clip_count > 0) {
        Rendering.gfx.api.set_clip_planes(true);
        for (visible[0..clip_count]) |ref| {
            self.grid[ref.cx][ref.cz][ref.sy].draw_opaque();
        }
        Rendering.gfx.api.set_clip_planes(false);
    }
    for (visible[clip_count..]) |ref| {
        self.grid[ref.cx][ref.cz][ref.sy].draw_opaque();
    }

    // Clouds are a physical layer at Y=72. Draw after opaque (so terrain
    // occludes them) but before transparent/fluid (so leaves, glass, and
    // water alpha-blend against the cloud layer behind them).
    self.clouds.bind();
    self.sky.draw_clouds(camera, submerged);

    // Transparent pass (back-to-front): non-fluid (leaves, glass, cross-plants).
    // Depth writes stay on so leaves properly occlude geometry behind them.
    set_terrain_fog(submerged);
    self.terrain.bind();
    Rendering.gfx.api.set_alpha_blend(true);
    var ri: u32 = self.frame_visible_count;
    while (ri > clip_count) {
        ri -= 1;
        self.grid[visible[ri].cx][visible[ri].cz][visible[ri].sy].draw_transparent();
    }
    if (clip_count > 0) {
        Rendering.gfx.api.set_clip_planes(true);
        while (ri > 0) {
            ri -= 1;
            self.grid[visible[ri].cx][visible[ri].cz][visible[ri].sy].draw_transparent();
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
    self.rain_tex.bind();
    self.rain.draw_streaks(camera);
    self.particles_tex.bind();
    self.rain.draw_splashes();
}

/// Draw the fluid (water/lava) pass. Must be called after draw_world_pass on
/// the same frame; consumes the visibility list populated there. Kept
/// separate so overlays (selection outline, remote players) drawn between
/// the two passes are correctly occluded by fluid surfaces.
pub fn draw_fluid_pass(self: *Self) void {
    const visible = self.frame_visible[0..self.frame_visible_count];
    const clip_count = self.frame_clip_count;

    self.terrain.bind();
    Rendering.gfx.api.set_alpha_blend(true);

    // Fluid pass (back-to-front): water/lava drawn with depth writes off so
    // fluid faces never occlude each other across section borders.
    Rendering.gfx.api.set_depth_write(false);
    var ri: u32 = self.frame_visible_count;
    while (ri > clip_count) {
        ri -= 1;
        self.grid[visible[ri].cx][visible[ri].cz][visible[ri].sy].draw_fluid();
    }
    if (clip_count > 0) {
        Rendering.gfx.api.set_clip_planes(true);
        while (ri > 0) {
            ri -= 1;
            self.grid[visible[ri].cx][visible[ri].cz][visible[ri].sy].draw_fluid();
        }
        Rendering.gfx.api.set_clip_planes(false);
    }
    Rendering.gfx.api.set_depth_write(true);
}

fn recollect(self: *Self, camera: *const Camera) void {
    self.cam_cx = camera_chunk(camera.x);
    self.cam_cz = camera_chunk(camera.z);
    self.applied_render_distance = Options.capped_render_distance();

    // Phase 1: compute needed columns
    const rd: u32 = self.applied_render_distance;
    const r: i32 = @intCast(rd);
    const radius_blocks: f32 = @as(f32, @floatFromInt(rd)) * 16.0 + 11.5;
    const radius_blocks_sq = radius_blocks * radius_blocks;

    const row_false = [_]bool{false} ** WORLD_CZ;
    var needed: [WORLD_CX][WORLD_CZ]bool = .{row_false} ** WORLD_CX;

    var dz: i32 = -r;
    while (dz <= r) : (dz += 1) {
        var dx: i32 = -r;
        while (dx <= r) : (dx += 1) {
            const cx_i = self.cam_cx + dx;
            const cz_i = self.cam_cz + dz;
            if (cx_i < 0 or cx_i > 15 or cz_i < 0 or cz_i > 15) continue;
            const ccx: f32 = @as(f32, @floatFromInt(cx_i)) * 16.0 + 8.0;
            const ccz: f32 = @as(f32, @floatFromInt(cz_i)) * 16.0 + 8.0;
            const dist_sq = (ccx - camera.x) * (ccx - camera.x) +
                (ccz - camera.z) * (ccz - camera.z);
            if (dist_sq > radius_blocks_sq) continue;
            needed[@intCast(cx_i)][@intCast(cz_i)] = true;
        }
    }

    // Phase 2: deinit columns leaving radius
    for (0..WORLD_CX) |cx| {
        for (0..WORLD_CZ) |cz| {
            if (self.loaded[cx][cz] and !needed[cx][cz]) {
                self.deinit_column(@intCast(cx), @intCast(cz));
            }
        }
    }

    // Phase 3: init columns entering radius
    for (0..WORLD_CX) |cx| {
        for (0..WORLD_CZ) |cz| {
            if (!self.loaded[cx][cz] and needed[cx][cz]) {
                if (self.init_column(@intCast(cx), @intCast(cz), camera)) {
                    self.loaded[cx][cz] = true;
                }
                // If init fails, loaded stays false; will retry next crossing
            }
        }
    }

    // Phase 4: queue ALL unbuilt sections (not just newly-loaded)
    self.dirty_buf_len = 0;
    self.dirty_overflow = false;
    self.dirty_preserve_order = false;
    self.queue_unbuilt_sections(camera);
    // init_column set all LOD states for the new columns; sync the check
    // position so update() does not fire a redundant refresh next frame.
    self.lod_check_x = camera.x;
    self.lod_check_y = camera.y;
    self.lod_check_z = camera.z;
}

fn init_column(self: *Self, cx: u8, cz: u8, cam: *const Camera) bool {
    var count: u32 = 0;
    for (0..SECTIONS_Y) |sy| {
        self.grid[cx][cz][sy] = ChunkMesh.init(
            self.allocator,
            @intCast(cx),
            @intCast(sy),
            @intCast(cz),
        ) catch {
            // Rollback: deinit already-initialized sections
            for (0..count) |prev| self.grid[cx][cz][prev].deinit();
            return false;
        };
        // Set the LOD state up front so the first build uses the correct
        // detail level rather than the default and immediately rebuilding.
        self.grid[cx][cz][sy].near_lod = target_near_lod(cx, @intCast(sy), cz, cam);
        self.grid[cx][cz][sy].ao_enabled = Options.current.ambient_occlusion;
        count += 1;
    }
    return true;
}

fn deinit_column(self: *Self, cx: u8, cz: u8) void {
    for (0..SECTIONS_Y) |sy| {
        self.grid[cx][cz][sy].deinit();
        self.built[cx][cz][sy] = false;
        self.in_queue[cx][cz][sy] = false;
    }
    self.loaded[cx][cz] = false;
}

fn queue_unbuilt_sections(self: *Self, cam: *const Camera) void {
    // Reset in-queue tracking before rebuilding the queue from scratch.
    for (&self.in_queue) |*cx_row| {
        for (cx_row) |*cz_row| @memset(cz_row, false);
    }
    var build_idx: u32 = 0;
    for (0..WORLD_CX) |cx| {
        for (0..WORLD_CZ) |cz| {
            if (!self.loaded[cx][cz]) continue;
            for (0..SECTIONS_Y) |sy| {
                if (!self.built[cx][cz][sy]) {
                    std.debug.assert(build_idx < MAX_ACTIVE);
                    self.build_queue[build_idx] = .{
                        .cx = @intCast(cx),
                        .cz = @intCast(cz),
                        .sy = @intCast(sy),
                    };
                    self.in_queue[cx][cz][sy] = true;
                    build_idx += 1;
                }
            }
        }
    }
    if (build_idx > 1) {
        sort_build_queue(self.build_queue[0..build_idx], cam);
    }
    self.build_cursor = 0;
    self.build_end = build_idx;
}

/// Insert sections from dirty_buf into the live build queue without a full
/// rescan. Falls back to queue_unbuilt_sections if the queue would overflow.
fn flush_dirty_sections(self: *Self, cam: *const Camera) void {
    if (self.dirty_preserve_order) {
        self.flush_ordered_dirty_sections(cam);
        return;
    }

    var added: u32 = 0;
    for (self.dirty_buf[0..self.dirty_buf_len]) |ref| {
        if (self.built[ref.cx][ref.cz][ref.sy]) continue; // already rebuilt
        if (self.in_queue[ref.cx][ref.cz][ref.sy]) continue; // already queued
        if (self.build_end >= MAX_ACTIVE) {
            // No room - compact via a full rescan which resets the queue.
            self.queue_unbuilt_sections(cam);
            return;
        }
        self.build_queue[self.build_end] = ref;
        self.in_queue[ref.cx][ref.cz][ref.sy] = true;
        self.build_end += 1;
        added += 1;
    }
    // Re-sort the unprocessed portion so newly-added sections are ordered
    // closest-first alongside any sections already waiting to be built.
    if (added > 0 and self.build_end - self.build_cursor > 1) {
        sort_build_queue(self.build_queue[self.build_cursor..self.build_end], cam);
    }
}

/// Move dirty sections to the front of the unprocessed queue while preserving
/// dirty_buf order. Sections already queued by background work are removed
/// from their old position; freshly-dirtied sections are inserted up front.
fn flush_ordered_dirty_sections(self: *Self, cam: *const Camera) void {
    var front: [MAX_DIRTY_BUF]GridRef = undefined;
    var front_len: u32 = 0;

    for (self.dirty_buf[0..self.dirty_buf_len]) |ref| {
        if (self.built[ref.cx][ref.cz][ref.sy]) continue;
        if (contains_grid_ref(front[0..front_len], ref)) continue;
        front[front_len] = ref;
        front_len += 1;
    }
    if (front_len == 0) return;

    var reordered: [MAX_ACTIVE]GridRef = undefined;
    var count: u32 = 0;

    for (front[0..front_len]) |ref| {
        if (count >= MAX_ACTIVE) {
            self.queue_unbuilt_sections(cam);
            return;
        }
        reordered[count] = ref;
        self.in_queue[ref.cx][ref.cz][ref.sy] = true;
        count += 1;
    }

    for (self.build_queue[self.build_cursor..self.build_end]) |ref| {
        if (contains_grid_ref(front[0..front_len], ref)) continue;
        if (count >= MAX_ACTIVE) {
            self.queue_unbuilt_sections(cam);
            return;
        }
        reordered[count] = ref;
        count += 1;
    }

    for (reordered[0..count], 0..) |ref, i| {
        self.build_queue[i] = ref;
    }
    self.build_cursor = 0;
    self.build_end = count;
}

fn try_evict_farthest(self: *Self, cam: *const Camera) bool {
    var best_dist: f32 = -1.0;
    var best_cx: u8 = 0;
    var best_cz: u8 = 0;
    var best_sy: u8 = 0;

    for (0..WORLD_CX) |cx| {
        for (0..WORLD_CZ) |cz| {
            if (!self.loaded[cx][cz]) continue;
            for (0..SECTIONS_Y) |sy| {
                if (!self.built[cx][cz][sy]) continue;
                const sec = &self.grid[cx][cz][sy];
                const d = cam.distance_sq(sec.center_x(), sec.center_y(), sec.center_z());
                if (d > best_dist) {
                    best_dist = d;
                    best_cx = @intCast(cx);
                    best_cz = @intCast(cz);
                    best_sy = @intCast(sy);
                }
            }
        }
    }

    if (best_dist < 0.0) return false;

    self.grid[best_cx][best_cz][best_sy].clear();
    self.built[best_cx][best_cz][best_sy] = false;
    return true;
}

/// Mark a section for rebuild (e.g. after a block change).
pub fn mark_section_dirty(self: *Self, cx: u8, sy: u8, cz: u8) void {
    self.mark_section_dirty_impl(cx, sy, cz, false, false);
}

/// Mark the affected sections for a single block mutation in an order that
/// avoids one-frame gaps at section edges. Removals rebuild neighbors before
/// the owner so newly exposed neighbor faces are hidden by the old owner mesh
/// until the owner rebuild commits. Additions do the inverse.
pub fn mark_block_change_dirty(self: *Self, cx: u8, sy: u8, cz: u8, lx: u16, ly: u16, lz: u16, removing: bool) void {
    if (removing) {
        self.mark_block_neighbor_sections_dirty(cx, sy, cz, lx, ly, lz);
        self.mark_section_dirty_impl(cx, sy, cz, true, true);
    } else {
        self.mark_section_dirty_impl(cx, sy, cz, true, true);
        self.mark_block_neighbor_sections_dirty(cx, sy, cz, lx, ly, lz);
    }
}

fn mark_block_neighbor_sections_dirty(self: *Self, cx: u8, sy: u8, cz: u8, lx: u16, ly: u16, lz: u16) void {
    if (lx == 0 and cx > 0) self.mark_section_dirty_impl(cx - 1, sy, cz, true, true);
    if (lx == 15) self.mark_section_dirty_impl(cx + 1, sy, cz, true, true);
    if (lz == 0 and cz > 0) self.mark_section_dirty_impl(cx, sy, cz - 1, true, true);
    if (lz == 15) self.mark_section_dirty_impl(cx, sy, cz + 1, true, true);
    if (ly == 0 and sy > 0) self.mark_section_dirty_impl(cx, sy - 1, cz, true, true);
    if (ly == 15) self.mark_section_dirty_impl(cx, sy + 1, cz, true, true);
}

fn mark_section_dirty_impl(self: *Self, cx: u8, sy: u8, cz: u8, track_queued: bool, preserve_order: bool) void {
    if (cx >= WORLD_CX or cz >= WORLD_CZ or sy >= SECTIONS_Y) return;
    self.rain.mark_dirty();
    if (!self.loaded[cx][cz]) return;
    self.built[cx][cz][sy] = false;
    // Section already in the build queue; it will be rebuilt when the queue
    // reaches it - no need to track it again.
    if (self.in_queue[cx][cz][sy] and !track_queued) return;
    // Track for incremental insert on the next update(). On overflow, flag a
    // full rescan so no dirty sections are silently dropped.
    self.record_dirty_ref(.{ .cx = cx, .cz = cz, .sy = sy }, preserve_order);
}

fn record_dirty_ref(self: *Self, ref: GridRef, preserve_order: bool) void {
    if (!self.dirty_overflow) {
        if (contains_grid_ref(self.dirty_buf[0..self.dirty_buf_len], ref)) {
            if (preserve_order) self.dirty_preserve_order = true;
            return;
        }
        if (self.dirty_buf_len < MAX_DIRTY_BUF) {
            self.dirty_buf[self.dirty_buf_len] = ref;
            self.dirty_buf_len += 1;
            if (preserve_order) self.dirty_preserve_order = true;
        } else {
            self.dirty_overflow = true;
            if (preserve_order) self.dirty_preserve_order = true;
        }
    }
}

fn contains_grid_ref(haystack: []const GridRef, needle: GridRef) bool {
    for (haystack) |ref| {
        if (ref.cx == needle.cx and ref.cz == needle.cz and ref.sy == needle.sy) return true;
    }
    return false;
}

/// Flip ao_enabled on every loaded section whose last-built state disagrees
/// with Options.current.ambient_occlusion, and mark those sections dirty so
/// they re-mesh with the new AO state. Only called on the frame the option
/// actually changes.
fn apply_ao_toggle(self: *Self) void {
    const target = Options.current.ambient_occlusion;
    for (0..WORLD_CX) |cx| {
        for (0..WORLD_CZ) |cz| {
            if (!self.loaded[cx][cz]) continue;
            for (0..SECTIONS_Y) |sy| {
                const sec = &self.grid[cx][cz][sy];
                if (sec.ao_enabled != target) {
                    sec.ao_enabled = target;
                    self.mark_section_dirty(@intCast(cx), @intCast(sy), @intCast(cz));
                }
            }
        }
    }
    self.applied_ao = target;
}

/// Recompute leaf LOD state after the Fancy Leaves option changes, and mark
/// only sections whose effective leaf mesh needs to change.
fn apply_fancy_leaves_toggle(self: *Self, cam: *const Camera) void {
    self.refresh_lod_states(cam);
    self.applied_fancy_leaves = Options.current.fancy_leaves;
    self.lod_check_x = cam.x;
    self.lod_check_y = cam.y;
    self.lod_check_z = cam.z;
}

/// Walk loaded sections and update their LOD state. Sections that cross
/// the configured near-LOD boundary in either direction get marked
/// dirty so they re-mesh with the new detail level.
fn refresh_lod_states(self: *Self, cam: *const Camera) void {
    for (0..WORLD_CX) |cx| {
        for (0..WORLD_CZ) |cz| {
            if (!self.loaded[cx][cz]) continue;
            for (0..SECTIONS_Y) |sy| {
                const target = target_near_lod(@intCast(cx), @intCast(sy), @intCast(cz), cam);
                const sec = &self.grid[cx][cz][sy];
                if (sec.near_lod != target) {
                    sec.near_lod = target;
                    self.mark_section_dirty(@intCast(cx), @intCast(sy), @intCast(cz));
                }
            }
        }
    }
}

fn sort_build_queue(queue: []GridRef, cam: *const Camera) void {
    std.sort.pdq(GridRef, queue, cam, grid_ref_less_than);
}

fn grid_ref_dist_sq(ref: GridRef, cam: *const Camera) f32 {
    const wx: f32 = @as(f32, @floatFromInt(@as(u32, ref.cx) * 16)) + 8.0;
    const wy: f32 = @as(f32, @floatFromInt(@as(u32, ref.sy) * 16)) + 8.0;
    const wz: f32 = @as(f32, @floatFromInt(@as(u32, ref.cz) * 16)) + 8.0;
    return cam.distance_sq(wx, wy, wz);
}

/// True when a section's center is within the runtime near-LOD radius.
/// Returns false immediately when fancy leaves are disabled so all sections
/// get the fast/opaque-leaves mesh regardless of distance.
fn target_near_lod(cx: u8, sy: u8, cz: u8, cam: *const Camera) bool {
    if (!Options.current.fancy_leaves) return false;
    const lod_near_radius: f32 = @floatFromInt(config.current().lod_near_radius_blocks);
    const lod_near_radius_sq = lod_near_radius * lod_near_radius;
    const wx: f32 = @as(f32, @floatFromInt(@as(u32, cx) * 16)) + 8.0;
    const wy: f32 = @as(f32, @floatFromInt(@as(u32, sy) * 16)) + 8.0;
    const wz: f32 = @as(f32, @floatFromInt(@as(u32, cz) * 16)) + 8.0;
    return cam.distance_sq(wx, wy, wz) <= lod_near_radius_sq;
}

fn grid_ref_less_than(cam: *const Camera, a: GridRef, b: GridRef) bool {
    return grid_ref_dist_sq(a, cam) < grid_ref_dist_sq(b, cam);
}

fn camera_chunk(pos: f32) i32 {
    const v = @floor(pos / 16.0);
    if (v < -2147483648.0 or v > 2147483647.0) return 0;
    return @intFromFloat(v);
}

fn set_terrain_fog(submerged: ?collision.Liquid) void {
    const c = switch (submerged orelse .water) {
        .water => if (submerged != null) Color.game_underwater else Color.game_daytime,
        .lava => Color.game_underlava,
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
        @as(f32, @floatFromInt(c.r)) / 255.0,
        @as(f32, @floatFromInt(c.g)) / 255.0,
        @as(f32, @floatFromInt(c.b)) / 255.0,
    );
}
