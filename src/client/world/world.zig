const std = @import("std");
const ae = @import("aether");
const Util = ae.Util;
const Rendering = ae.Rendering;

const TextureAtlas = @import("../graphics/TextureAtlas.zig").TextureAtlas;
const Color = @import("../graphics/Color.zig").Color;
const Camera = @import("../player/Camera.zig");
const collision = @import("../player/collision.zig");
const config = @import("../config.zig").current;

const ChunkMesh = @import("chunk/ChunkMesh.zig");
const BlockRegistry = @import("block/BlockRegistry.zig");
const Sky = @import("sky/sky.zig");

const SECTIONS_Y: u32 = 4;
const WORLD_CX: u32 = 16;
const WORLD_CZ: u32 = 16;
const MAX_ACTIVE: u32 = @import("../config.zig").max_sections();

/// Sections whose center is within this distance of the camera are
/// considered "near LOD" and meshed at full detail; beyond it the mesher
/// downgrades them (currently: leaves become fully opaque). Crossing the
/// boundary in either direction triggers a rebuild via refresh_lod_states.
/// Per-platform value lives in config.zig.
const LOD_NEAR_RADIUS_BLOCKS: f32 = @floatFromInt(config.lod_near_radius_blocks);
const LOD_NEAR_RADIUS_SQ: f32 = LOD_NEAR_RADIUS_BLOCKS * LOD_NEAR_RADIUS_BLOCKS;

const Self = @This();

/// Grid of sections. Only valid where loaded[cx][cz] is true.
grid: [WORLD_CX][WORLD_CZ][SECTIONS_Y]ChunkMesh,
/// Per-column: all 4 sections have GPU handles allocated.
loaded: [WORLD_CX][WORLD_CZ]bool,
/// Per-section: mesh has been built via rebuild().
built: [WORLD_CX][WORLD_CZ][SECTIONS_Y]bool,
/// Set when mark_section_dirty() is called; cleared after re-queue.
dirty: bool,

build_queue: [MAX_ACTIVE]GridRef,
build_cursor: u32,
build_end: u32,
build_estimator: Util.Estimator,

terrain: *const Rendering.Texture,
clouds: *const Rendering.Texture,
atlas: TextureAtlas,
pipeline: Rendering.Pipeline.Handle,
sky: Sky,
cam_cx: i32,
cam_cz: i32,

const GridRef = packed struct { cx: u8, cz: u8, sy: u8 };

pub fn init(
    pipeline: Rendering.Pipeline.Handle,
    terrain: *const Rendering.Texture,
    clouds: *const Rendering.Texture,
    atlas: TextureAtlas,
    camera: *const Camera,
) !Self {
    BlockRegistry.init();

    const row_false = [_]bool{false} ** WORLD_CZ;
    const section_false = [_]bool{false} ** SECTIONS_Y;
    const col_section_false = [_][SECTIONS_Y]bool{section_false} ** WORLD_CZ;
    var self: Self = .{
        .grid = undefined,
        .loaded = .{row_false} ** WORLD_CX,
        .built = .{col_section_false} ** WORLD_CX,
        .dirty = false,
        .build_queue = undefined,
        .build_cursor = 0,
        .build_end = 0,
        .build_estimator = Util.Estimator.init(),
        .terrain = terrain,
        .clouds = clouds,
        .atlas = atlas,
        .pipeline = pipeline,
        .sky = try Sky.init(pipeline),
        .cam_cx = camera_chunk(camera.x),
        .cam_cz = camera_chunk(camera.z),
    };

    self.recollect(camera);

    // Warm up the estimator
    while (self.build_cursor < self.build_end and self.build_estimator.is_warming_up()) {
        const ref = self.build_queue[self.build_cursor];
        self.build_estimator.begin();
        self.grid[ref.cx][ref.cz][ref.sy].rebuild(&self.atlas) catch break;
        self.build_estimator.end();
        self.built[ref.cx][ref.cz][ref.sy] = true;
        self.build_cursor += 1;
    }

    return self;
}

pub fn deinit(self: *Self) void {
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

    const new_cx = camera_chunk(camera.x);
    const new_cz = camera_chunk(camera.z);
    if (new_cx != self.cam_cx or new_cz != self.cam_cz) {
        self.recollect(camera);
    }

    // Catch LOD transitions that happen mid-chunk (player walking inside the
    // same column can still cross the 32-block radius for nearby sections).
    self.refresh_lod_states(camera);

    // Re-queue any newly dirty sections immediately. We can't wait for the
    // current queue to drain: a player break/place that lands while a heavy
    // LOD rebuild is in flight would otherwise take many frames to show up,
    // which looks like a dropped update. queue_unbuilt_sections rescans all
    // loaded sections, so already-built ones drop out naturally.
    if (self.dirty) {
        self.queue_unbuilt_sections(camera);
        self.dirty = false;
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
        self.build_estimator.begin();
        if (self.grid[ref.cx][ref.cz][ref.sy].rebuild(&self.atlas)) {
            self.build_estimator.end();
        } else |_| {
            self.build_estimator.end();
            // OOM - evict farthest built section and retry once
            if (self.try_evict_farthest(camera)) {
                self.grid[ref.cx][ref.cz][ref.sy].rebuild(&self.atlas) catch {
                    self.build_cursor = @intCast(i);
                    return;
                };
            } else {
                self.build_cursor = @intCast(i);
                return;
            }
        }
        self.built[ref.cx][ref.cz][ref.sy] = true;
    }
    self.build_cursor = end;
}

pub fn draw(self: *Self, camera: *const Camera) void {
    const submerged = collision.liquid_at_point(camera.x, camera.y, camera.z);

    Rendering.Pipeline.bind(self.pipeline);

    Rendering.Texture.Default.bind();
    Sky.clear(submerged);
    self.sky.draw_plane(camera, submerged);

    set_terrain_fog(submerged);
    self.terrain.bind();

    var visible: [MAX_ACTIVE]GridRef = undefined;
    var visible_count: u32 = 0;

    for (0..WORLD_CX) |cx| {
        for (0..WORLD_CZ) |cz| {
            if (!self.loaded[cx][cz]) continue;
            for (0..SECTIONS_Y) |sy| {
                const sec = &self.grid[cx][cz][sy];
                if (!camera.section_visible(sec.cx, sec.sy, sec.cz)) continue;
                visible[visible_count] = .{ .cx = @intCast(cx), .cz = @intCast(cz), .sy = @intCast(sy) };
                visible_count += 1;
            }
        }
    }

    std.sort.pdq(GridRef, visible[0..visible_count], camera, grid_ref_less_than);

    // Sections close to the player need hardware clip planes to prevent
    // vertices from overflowing the PSP 4096 virtual viewport.
    const CLIP_SECTION_COUNT: u32 = 4;
    const clip_count = @min(CLIP_SECTION_COUNT, visible_count);

    // Opaque pass (front-to-back): clip planes on for closest sections
    Rendering.gfx.api.set_alpha_blend(false);
    if (clip_count > 0) {
        Rendering.gfx.api.set_clip_planes(true);
        for (visible[0..clip_count]) |ref| {
            self.grid[ref.cx][ref.cz][ref.sy].draw_opaque();
        }
        Rendering.gfx.api.set_clip_planes(false);
    }
    for (visible[clip_count..visible_count]) |ref| {
        self.grid[ref.cx][ref.cz][ref.sy].draw_opaque();
    }

    // Transparent pass (back-to-front): far sections first, then closest with clip planes
    Rendering.gfx.api.set_alpha_blend(true);
    var ri: u32 = visible_count;
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

    self.clouds.bind();
    self.sky.draw_clouds();
}

fn recollect(self: *Self, camera: *const Camera) void {
    self.cam_cx = camera_chunk(camera.x);
    self.cam_cz = camera_chunk(camera.z);

    // Phase 1: compute needed columns
    const r: i32 = @intCast(config.chunk_radius);
    const radius_blocks: f32 = @as(f32, @floatFromInt(config.chunk_radius)) * 16.0 + 11.5;
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
    self.dirty = false;
    self.queue_unbuilt_sections(camera);
}

fn init_column(self: *Self, cx: u8, cz: u8, cam: *const Camera) bool {
    var count: u32 = 0;
    for (0..SECTIONS_Y) |sy| {
        self.grid[cx][cz][sy] = ChunkMesh.init(
            self.pipeline,
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
        count += 1;
    }
    return true;
}

fn deinit_column(self: *Self, cx: u8, cz: u8) void {
    for (0..SECTIONS_Y) |sy| {
        self.grid[cx][cz][sy].deinit();
        self.built[cx][cz][sy] = false;
    }
    self.loaded[cx][cz] = false;
}

fn queue_unbuilt_sections(self: *Self, cam: *const Camera) void {
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
    if (cx >= WORLD_CX or cz >= WORLD_CZ or sy >= SECTIONS_Y) return;
    if (!self.loaded[cx][cz]) return;
    self.built[cx][cz][sy] = false;
    self.dirty = true;
}

/// Walk loaded sections and update their LOD state. Sections that cross
/// the LOD_NEAR_RADIUS_BLOCKS boundary in either direction get marked
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
                    self.built[cx][cz][sy] = false;
                    self.dirty = true;
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

/// True when a section's center is within LOD_NEAR_RADIUS_BLOCKS of the camera.
fn target_near_lod(cx: u8, sy: u8, cz: u8, cam: *const Camera) bool {
    const wx: f32 = @as(f32, @floatFromInt(@as(u32, cx) * 16)) + 8.0;
    const wy: f32 = @as(f32, @floatFromInt(@as(u32, sy) * 16)) + 8.0;
    const wz: f32 = @as(f32, @floatFromInt(@as(u32, cz) * 16)) + 8.0;
    return cam.distance_sq(wx, wy, wz) <= LOD_NEAR_RADIUS_SQ;
}

fn grid_ref_less_than(cam: *const Camera, a: GridRef, b: GridRef) bool {
    return grid_ref_dist_sq(a, cam) < grid_ref_dist_sq(b, cam);
}

fn camera_chunk(pos: f32) i32 {
    return @intFromFloat(@floor(pos / 16.0));
}

fn set_terrain_fog(submerged: ?collision.Liquid) void {
    const c = switch (submerged orelse .water) {
        .water => if (submerged != null) Color.game_underwater else Color.game_daytime,
        .lava => Color.game_underlava,
    };
    const fog_end: f32 = switch (submerged orelse .water) {
        .water => if (submerged != null) 16.0 else @as(f32, @floatFromInt(config.chunk_radius * 16 - 16)),
        .lava => 2.0,
    };
    const fog_start: f32 = if (submerged != null) 0.0 else fog_end * 0.4;
    Rendering.gfx.api.set_fog(
        true,
        fog_start,
        fog_end,
        @as(f32, @floatFromInt(c.r)) / 255.0,
        @as(f32, @floatFromInt(c.g)) / 255.0,
        @as(f32, @floatFromInt(c.b)) / 255.0,
    );
}
