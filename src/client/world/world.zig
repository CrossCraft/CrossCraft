const std = @import("std");
const ae = @import("aether");
const Util = ae.Util;
const Rendering = ae.Rendering;

const core = @import("core");
const World = core.World;
const TextureAtlas = @import("../graphics/TextureAtlas.zig").TextureAtlas;
const Colors = @import("../graphics/Color.zig");
const Color = Colors.Color;
const Camera = @import("../player/Camera.zig");
const collision = @import("../player/collision.zig");
const config = @import("../config.zig");
const Options = @import("../Options.zig");

const ChunkMesh = @import("chunk/ChunkMesh.zig");
const Sky = @import("sky/sky.zig");
const ParticleSystem = @import("ParticleSystem.zig");
const Rain = @import("Rain.zig");

const MAX_ACTIVE: u32 = @import("../config.zig").max_sections();
comptime {
    // GridRef carries each chunk coord in a u8; the supported world lattice
    // never exceeds that.
    std.debug.assert(core.world_dims.max_length / core.world_dims.chunk_size <= std.math.maxInt(u8));
    std.debug.assert(core.world_dims.max_depth / core.world_dims.chunk_size <= std.math.maxInt(u8));
    std.debug.assert(core.world_dims.max_height / core.world_dims.chunk_size <= std.math.maxInt(u8));
}

/// Four simultaneous block changes and their six neighboring sections.
const MAX_DIRTY_BUF: u32 = 32;

const Self = @This();

/// Power-of-two world geometry permits shift-based flat indexing.
grid_cx: u32,
grid_cz: u32,
grid_sy: u32,
log2_cx: u5,
log2_cz: u5,
log2_sy: u5,

/// Unloaded columns contain undefined meshes and are initialized as a unit.
grid: []ChunkMesh,
loaded: []bool,
built: []bool,
in_queue: []bool,
needed: []bool,
/// Overflow falls back to a full queue rescan.
dirty_buf: [MAX_DIRTY_BUF]GridRef,
dirty_buf_len: u32,
dirty_overflow: bool,
/// Preserve dirty_buf order and move those sections ahead of background
/// rebuilds. Used for block changes where edge rebuild order affects flicker.
dirty_preserve_order: bool,
lod_check_x: f32,
lod_check_y: f32,
lod_check_z: f32,
/// Last option values incorporated into loaded meshes.
applied_render_distance: u8,
applied_fancy_leaves: bool,
applied_ao: bool,

build_queue: [MAX_ACTIVE]GridRef,
build_cursor: u32,
build_end: u32,
build_estimator: Util.Estimator,

/// Shared across opaque and fluid passes so overlays can render between them.
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

/// Flat column id from chunk coords: (cz << log2_cx) | cx.
fn column_index(self: *const Self, cx: usize, cz: usize) u32 {
    return @intCast((cz << self.log2_cx) | cx);
}

/// Flat section id from chunk coords and Y section.
fn section_index(self: *const Self, cx: usize, cz: usize, sy: usize) u32 {
    return @intCast((@as(usize, self.column_index(cx, cz)) << self.log2_sy) | sy);
}

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
    // GameState creates the renderer only after world dimensions are final.
    const dims = World.data.dims;
    self.grid_cx = dims.chunks_x;
    self.grid_cz = dims.chunks_z;
    self.grid_sy = dims.chunks_y;
    self.log2_cx = @intCast(@ctz(dims.chunks_x));
    self.log2_cz = @intCast(@ctz(dims.chunks_z));
    self.log2_sy = @intCast(@ctz(dims.chunks_y));

    const column_count = self.grid_cx * self.grid_cz;
    const section_count = column_count * self.grid_sy;
    self.grid = try allocator.alloc(ChunkMesh, section_count);
    errdefer allocator.free(self.grid);
    self.loaded = try allocator.alloc(bool, column_count);
    errdefer allocator.free(self.loaded);
    self.built = try allocator.alloc(bool, section_count);
    errdefer allocator.free(self.built);
    self.in_queue = try allocator.alloc(bool, section_count);
    errdefer allocator.free(self.in_queue);
    self.needed = try allocator.alloc(bool, column_count);
    errdefer allocator.free(self.needed);
    @memset(self.loaded, false);
    @memset(self.built, false);
    @memset(self.in_queue, false);

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

    while (self.build_cursor < self.build_end and self.build_estimator.is_warming_up()) {
        const ref = self.build_queue[self.build_cursor];
        const idx = self.section_index(ref.cx, ref.cz, ref.sy);
        self.build_estimator.begin(io);
        self.grid[idx].rebuild(&self.atlas) catch break;
        self.build_estimator.end(io);
        mark_first_built(&self.grid[idx]);
        self.built[idx] = true;
        self.in_queue[idx] = false;
        self.build_cursor += 1;
    }
}

pub fn deinit(self: *Self) void {
    self.rain.deinit();
    self.particles.deinit();
    self.sky.deinit();
    for (0..self.grid_cx) |cx| {
        for (0..self.grid_cz) |cz| {
            if (!self.loaded[self.column_index(cx, cz)]) continue;
            self.deinit_column(@intCast(cx), @intCast(cz));
        }
    }
    self.allocator.free(self.grid);
    self.allocator.free(self.loaded);
    self.allocator.free(self.built);
    self.allocator.free(self.in_queue);
    self.allocator.free(self.needed);
}

pub fn update(self: *Self, dt: f32, budget: *const Util.BudgetContext, camera: *const Camera) void {
    self.sky.update(dt);
    self.particles.update(dt, camera);
    self.rain.update(dt, camera);

    // Animations must advance even when no rebuilds are pending.
    for (0..self.grid_cx) |cx| {
        for (0..self.grid_cz) |cz| {
            if (!self.loaded[self.column_index(cx, cz)]) continue;
            for (0..self.grid_sy) |sy| {
                self.grid[self.section_index(cx, cz, sy)].update_animation(dt);
            }
        }
    }

    const new_cx = camera_chunk(camera.x);
    const new_cz = camera_chunk(camera.z);
    if (new_cx != self.cam_cx or new_cz != self.cam_cz or Options.capped_render_distance() != self.applied_render_distance) {
        self.recollect(camera);
    }

    // AO changes invalidate every loaded mesh.
    if (Options.current.ambient_occlusion != self.applied_ao) {
        self.apply_ao_toggle();
    }

    // Apply leaf-mode changes without waiting for camera movement.
    if (Options.current.fancy_leaves != self.applied_fancy_leaves) {
        self.apply_fancy_leaves_toggle(camera);
    }

    // Limit the full LOD scan to whole-block camera movement.
    const lod_dx = camera.x - self.lod_check_x;
    const lod_dy = camera.y - self.lod_check_y;
    const lod_dz = camera.z - self.lod_check_z;
    if (lod_dx * lod_dx + lod_dy * lod_dy + lod_dz * lod_dz >= 1.0) {
        self.refresh_lod_states(camera);
        self.lod_check_x = camera.x;
        self.lod_check_y = camera.y;
        self.lod_check_z = camera.z;
    }

    // Prioritize block changes over background LOD rebuilds.
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
        const idx = self.section_index(ref.cx, ref.cz, ref.sy);
        self.build_estimator.begin(self.io);
        if (self.grid[idx].rebuild(&self.atlas)) {
            self.build_estimator.end(self.io);
        } else |_| {
            self.build_estimator.end(self.io);
            // Evict one distant mesh and retry this section next frame.
            _ = self.try_evict_farthest(camera);
            self.build_cursor = @intCast(i);
            return;
        }
        mark_first_built(&self.grid[idx]);
        self.built[idx] = true;
        self.in_queue[idx] = false;
    }
    self.build_cursor = end;
}

fn mark_first_built(sec: *ChunkMesh) void {
    if (!sec.first_build) return;
    sec.first_build = false;
    if (Options.current.bouncy_chunks) sec.anim_progress = 0.0;
}

/// Populate visibility and draw every world layer preceding fluids.
pub fn draw_world_pass(self: *Self, camera: *const Camera) void {
    const submerged = collision.liquid_at_point(camera.x, camera.y, camera.z);

    Rendering.gfx.api.bind_texture(Rendering.Texture.Default.handle);
    Sky.clear(submerged);
    self.sky.draw_plane(camera, submerged);

    set_terrain_fog(submerged);
    Rendering.gfx.api.bind_texture(self.terrain.handle);

    self.frame_visible_count = 0;
    for (0..self.grid_cx) |cx| {
        for (0..self.grid_cz) |cz| {
            if (!self.loaded[self.column_index(cx, cz)]) continue;
            for (0..self.grid_sy) |sy| {
                const sec = &self.grid[self.section_index(cx, cz, sy)];
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

    // Opaque sections render front-to-back.
    Rendering.gfx.api.set_alpha_blend(false);
    if (clip_count > 0) {
        Rendering.gfx.api.set_clip_planes(true);
        for (visible[0..clip_count]) |ref| {
            self.grid[self.section_index(ref.cx, ref.cz, ref.sy)].draw_opaque();
        }
        Rendering.gfx.api.set_clip_planes(false);
    }
    for (visible[clip_count..]) |ref| {
        self.grid[self.section_index(ref.cx, ref.cz, ref.sy)].draw_opaque();
    }

    // Clouds follow opaque terrain and precede alpha-blended geometry.
    Rendering.gfx.api.bind_texture(self.clouds.handle);
    self.sky.draw_clouds(camera, submerged);

    // Transparent blocks render back-to-front but retain depth writes.
    set_terrain_fog(submerged);
    Rendering.gfx.api.bind_texture(self.terrain.handle);
    Rendering.gfx.api.set_alpha_blend(true);
    var ri: u32 = self.frame_visible_count;
    while (ri > clip_count) {
        ri -= 1;
        self.grid[self.section_index(visible[ri].cx, visible[ri].cz, visible[ri].sy)].draw_transparent();
    }
    if (clip_count > 0) {
        Rendering.gfx.api.set_clip_planes(true);
        while (ri > 0) {
            ri -= 1;
            self.grid[self.section_index(visible[ri].cx, visible[ri].cz, visible[ri].sy)].draw_transparent();
        }
        Rendering.gfx.api.set_clip_planes(false);
    }

    // Particles depth-test before fluids overlay them.
    self.particles.draw();
}

/// Rain renders after terrain and particles but before fluid overlays.
pub fn draw_rain_pass(self: *Self, camera: *const Camera) void {
    if (!Options.current.rain) return;
    Rendering.gfx.api.bind_texture(self.rain_tex.handle);
    self.rain.draw_streaks(camera);
    Rendering.gfx.api.bind_texture(self.particles_tex.handle);
    self.rain.draw_splashes();
}

/// Consume this frame's visibility list after callers insert world overlays.
pub fn draw_fluid_pass(self: *Self) void {
    const visible = self.frame_visible[0..self.frame_visible_count];
    const clip_count = self.frame_clip_count;

    Rendering.gfx.api.bind_texture(self.terrain.handle);
    Rendering.gfx.api.set_alpha_blend(true);

    // Fluid pass (back-to-front): water/lava drawn with depth writes off so
    // fluid faces never occlude each other across section borders.
    Rendering.gfx.api.set_depth_write(false);
    var ri: u32 = self.frame_visible_count;
    while (ri > clip_count) {
        ri -= 1;
        self.grid[self.section_index(visible[ri].cx, visible[ri].cz, visible[ri].sy)].draw_fluid();
    }
    if (clip_count > 0) {
        Rendering.gfx.api.set_clip_planes(true);
        while (ri > 0) {
            ri -= 1;
            self.grid[self.section_index(visible[ri].cx, visible[ri].cz, visible[ri].sy)].draw_fluid();
        }
        Rendering.gfx.api.set_clip_planes(false);
    }
    Rendering.gfx.api.set_depth_write(true);
}

fn recollect(self: *Self, camera: *const Camera) void {
    self.cam_cx = camera_chunk(camera.x);
    self.cam_cz = camera_chunk(camera.z);
    self.applied_render_distance = Options.capped_render_distance();

    const rd: u32 = self.applied_render_distance;
    const r: i32 = @intCast(rd);
    const radius_blocks: f32 = @as(f32, @floatFromInt(rd)) * 16.0 + 11.5;
    const radius_blocks_sq = radius_blocks * radius_blocks;

    @memset(self.needed, false);

    var dz: i32 = -r;
    while (dz <= r) : (dz += 1) {
        var dx: i32 = -r;
        while (dx <= r) : (dx += 1) {
            const cx_i = self.cam_cx + dx;
            const cz_i = self.cam_cz + dz;
            if (cx_i < 0 or cx_i >= @as(i32, @intCast(self.grid_cx)) or
                cz_i < 0 or cz_i >= @as(i32, @intCast(self.grid_cz))) continue;
            const ccx: f32 = @as(f32, @floatFromInt(cx_i)) * 16.0 + 8.0;
            const ccz: f32 = @as(f32, @floatFromInt(cz_i)) * 16.0 + 8.0;
            const dist_sq = (ccx - camera.x) * (ccx - camera.x) +
                (ccz - camera.z) * (ccz - camera.z);
            if (dist_sq > radius_blocks_sq) continue;
            self.needed[self.column_index(@intCast(cx_i), @intCast(cz_i))] = true;
        }
    }

    for (0..self.grid_cx) |cx| {
        for (0..self.grid_cz) |cz| {
            const col = self.column_index(cx, cz);
            if (self.loaded[col] and !self.needed[col]) {
                self.deinit_column(@intCast(cx), @intCast(cz));
            }
        }
    }

    for (0..self.grid_cx) |cx| {
        for (0..self.grid_cz) |cz| {
            const col = self.column_index(cx, cz);
            if (!self.loaded[col] and self.needed[col]) {
                if (self.init_column(@intCast(cx), @intCast(cz), camera)) {
                    self.loaded[col] = true;
                }
            }
        }
    }

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
    for (0..self.grid_sy) |sy| {
        self.grid[self.section_index(cx, cz, sy)] = ChunkMesh.init(
            self.allocator,
            cx,
            @intCast(sy),
            cz,
        ) catch {
            for (0..count) |prev| self.grid[self.section_index(cx, cz, prev)].deinit();
            return false;
        };
        // Set the LOD state up front so the first build uses the correct
        // detail level rather than the default and immediately rebuilding.
        self.grid[self.section_index(cx, cz, sy)].near_lod = target_near_lod(cx, @intCast(sy), cz, cam);
        self.grid[self.section_index(cx, cz, sy)].ao_enabled = Options.current.ambient_occlusion;
        count += 1;
    }
    return true;
}

fn deinit_column(self: *Self, cx: u8, cz: u8) void {
    for (0..self.grid_sy) |sy| {
        const idx = self.section_index(cx, cz, sy);
        self.grid[idx].deinit();
        self.built[idx] = false;
        self.in_queue[idx] = false;
    }
    self.loaded[self.column_index(cx, cz)] = false;
}

fn queue_unbuilt_sections(self: *Self, cam: *const Camera) void {
    @memset(self.in_queue, false);
    var build_idx: u32 = 0;
    for (0..self.grid_cx) |cx| {
        for (0..self.grid_cz) |cz| {
            if (!self.loaded[self.column_index(cx, cz)]) continue;
            for (0..self.grid_sy) |sy| {
                const idx = self.section_index(cx, cz, sy);
                if (!self.built[idx]) {
                    std.debug.assert(build_idx < MAX_ACTIVE);
                    self.build_queue[build_idx] = .{
                        .cx = @intCast(cx),
                        .cz = @intCast(cz),
                        .sy = @intCast(sy),
                    };
                    self.in_queue[idx] = true;
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

/// Insert dirty sections directly, falling back to a full rescan on overflow.
fn flush_dirty_sections(self: *Self, cam: *const Camera) void {
    if (self.dirty_preserve_order) {
        self.flush_ordered_dirty_sections(cam);
        return;
    }

    var added: u32 = 0;
    for (self.dirty_buf[0..self.dirty_buf_len]) |ref| {
        if (self.built[self.section_index(ref.cx, ref.cz, ref.sy)]) continue;
        if (self.in_queue[self.section_index(ref.cx, ref.cz, ref.sy)]) continue;
        if (self.build_end >= MAX_ACTIVE) {
            self.queue_unbuilt_sections(cam);
            return;
        }
        self.build_queue[self.build_end] = ref;
        self.in_queue[self.section_index(ref.cx, ref.cz, ref.sy)] = true;
        self.build_end += 1;
        added += 1;
    }
    // Keep pending work nearest-first after inserting dirty sections.
    if (added > 0 and self.build_end - self.build_cursor > 1) {
        sort_build_queue(self.build_queue[self.build_cursor..self.build_end], cam);
    }
}

/// Move dirty sections ahead of background work while preserving their order.
fn flush_ordered_dirty_sections(self: *Self, cam: *const Camera) void {
    var front: [MAX_DIRTY_BUF]GridRef = undefined;
    var front_len: u32 = 0;

    for (self.dirty_buf[0..self.dirty_buf_len]) |ref| {
        if (self.built[self.section_index(ref.cx, ref.cz, ref.sy)]) continue;
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
        self.in_queue[self.section_index(ref.cx, ref.cz, ref.sy)] = true;
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

    for (0..self.grid_cx) |cx| {
        for (0..self.grid_cz) |cz| {
            if (!self.loaded[self.column_index(cx, cz)]) continue;
            for (0..self.grid_sy) |sy| {
                const idx = self.section_index(cx, cz, sy);
                if (!self.built[idx]) continue;
                const sec = &self.grid[idx];
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

    const best = self.section_index(best_cx, best_cz, best_sy);
    self.grid[best].clear();
    self.built[best] = false;
    return true;
}

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
    if (cx >= self.grid_cx or cz >= self.grid_cz or sy >= self.grid_sy) return;
    const idx = self.section_index(cx, cz, sy);
    const col = self.column_index(cx, cz);
    self.rain.mark_dirty();
    if (!self.loaded[col]) return;
    self.built[idx] = false;
    if (self.in_queue[idx] and !track_queued) return;
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

/// Invalidate loaded sections whose AO state changed.
fn apply_ao_toggle(self: *Self) void {
    const target = Options.current.ambient_occlusion;
    for (0..self.grid_cx) |cx| {
        for (0..self.grid_cz) |cz| {
            if (!self.loaded[self.column_index(cx, cz)]) continue;
            for (0..self.grid_sy) |sy| {
                const idx = self.section_index(cx, cz, sy);
                const sec = &self.grid[idx];
                if (sec.ao_enabled != target) {
                    sec.ao_enabled = target;
                    self.mark_section_dirty(@intCast(cx), @intCast(sy), @intCast(cz));
                }
            }
        }
    }
    self.applied_ao = target;
}

fn apply_fancy_leaves_toggle(self: *Self, cam: *const Camera) void {
    self.refresh_lod_states(cam);
    self.applied_fancy_leaves = Options.current.fancy_leaves;
    self.lod_check_x = cam.x;
    self.lod_check_y = cam.y;
    self.lod_check_z = cam.z;
}

/// Remesh loaded sections that cross the near-LOD boundary.
fn refresh_lod_states(self: *Self, cam: *const Camera) void {
    for (0..self.grid_cx) |cx| {
        for (0..self.grid_cz) |cz| {
            if (!self.loaded[self.column_index(cx, cz)]) continue;
            for (0..self.grid_sy) |sy| {
                const target = target_near_lod(@intCast(cx), @intCast(sy), @intCast(cz), cam);
                const sec = &self.grid[self.section_index(cx, cz, sy)];
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

/// Disabled fancy leaves force the fast mesh at every distance.
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
        Camera.near_plane,
        Camera.far_plane,
        fog_start,
        fog_end,
        @as(f32, @floatFromInt(c.r)) / 255.0,
        @as(f32, @floatFromInt(c.g)) / 255.0,
        @as(f32, @floatFromInt(c.b)) / 255.0,
    );
}
