const std = @import("std");
const ae = @import("aether");
const Util = ae.Util;
const Rendering = ae.Rendering;

const Vertex = @import("../graphics/Vertex.zig").Vertex;
const TextureAtlas = @import("../graphics/TextureAtlas.zig").TextureAtlas;
const Color = @import("../graphics/Color.zig").Color;
const Camera = @import("../player/Camera.zig");
const config = @import("../config.zig").current;

const chunk = @import("chunk/root.zig");
const ChunkMesh = chunk.ChunkMesh;
const MeshPool = chunk.MeshPool;
const Sky = @import("sky/sky.zig");

const SECTIONS_Y: u32 = 4;
const MAX_SECTIONS: u32 = @import("../config.zig").max_sections();

const Self = @This();

pool: MeshPool,
sections: [MAX_SECTIONS]ChunkMesh,
build_order: [MAX_SECTIONS]u32,
section_count: u32, // actual number of sections (within radius + world bounds)
build_cursor: u32,
build_estimator: Util.Estimator,
terrain: *const Rendering.Texture,
clouds: *const Rendering.Texture,
atlas: TextureAtlas,
pipeline: Rendering.Pipeline.Handle,
sky: Sky,

pub fn init(
    pipeline: Rendering.Pipeline.Handle,
    terrain: *const Rendering.Texture,
    clouds: *const Rendering.Texture,
    atlas: TextureAtlas,
    camera: *const Camera,
) !Self {
    var self: Self = .{
        .pool = undefined,
        .sections = undefined,
        .build_order = undefined,
        .section_count = 0,
        .build_cursor = 0,
        .build_estimator = Util.Estimator.init(),
        .terrain = terrain,
        .clouds = clouds,
        .atlas = atlas,
        .pipeline = pipeline,
        .sky = try Sky.init(pipeline),
    };

    // Collect chunks within radius of camera, clamped to world [0, 15]
    // Check in block-space: distance from camera to chunk center, padded by chunk half-diagonal
    const r: i32 = @intCast(config.chunk_radius);
    const radius_blocks: f32 = @as(f32, @floatFromInt(config.chunk_radius)) * 16.0 + 11.5;
    const radius_blocks_sq = radius_blocks * radius_blocks;
    const cam_cx: i32 = @intCast(@as(u32, @intFromFloat(camera.x)) / 16);
    const cam_cz: i32 = @intCast(@as(u32, @intFromFloat(camera.z)) / 16);

    var idx: u32 = 0;
    var dz: i32 = -r;
    while (dz <= r) : (dz += 1) {
        var dx: i32 = -r;
        while (dx <= r) : (dx += 1) {
            const cx_i = cam_cx + dx;
            const cz_i = cam_cz + dz;
            if (cx_i < 0 or cx_i > 15 or cz_i < 0 or cz_i > 15) continue;

            // Block-space distance from camera to chunk center
            const ccx: f32 = @as(f32, @floatFromInt(cx_i)) * 16.0 + 8.0;
            const ccz: f32 = @as(f32, @floatFromInt(cz_i)) * 16.0 + 8.0;
            const dist_sq = (ccx - camera.x) * (ccx - camera.x) + (ccz - camera.z) * (ccz - camera.z);
            if (dist_sq > radius_blocks_sq) continue;

            const cx: u32 = @intCast(cx_i);
            const cz: u32 = @intCast(cz_i);
            for (0..SECTIONS_Y) |sy| {
                self.sections[idx] = try ChunkMesh.init(pipeline, cx, @intCast(sy), cz);
                idx += 1;
            }
        }
    }
    self.section_count = idx;

    // Mesh pool
    const pool_verts: u32 = config.mesh_pool_mb * 1024 * 1024 / @sizeOf(Vertex);
    self.pool = try MeshPool.init(pool_verts);
    self.pool.reset();

    // Sort build order: nearest to camera first
    for (0..self.section_count) |i| self.build_order[i] = @intCast(i);
    sort_by_distance(self.build_order[0..self.section_count], self.sections[0..self.section_count], camera);

    // Warm up the estimator before entering the world
    while (self.build_cursor < self.section_count and self.build_estimator.is_warming_up()) {
        self.build_estimator.begin();
        self.sections[self.build_order[self.build_cursor]].rebuild(&self.pool, &self.atlas);
        self.build_estimator.end();
        self.build_cursor += 1;
    }

    return self;
}

pub fn deinit(self: *Self) void {
    self.sky.deinit();
    for (self.sections[0..self.section_count]) |*sec| sec.deinit();
    self.pool.deinit();
}

/// Build sections incrementally. Call each frame with the budget context.
pub fn update(self: *Self, dt: f32, budget: *const Util.BudgetContext) void {
    self.sky.update(dt);
    if (self.build_cursor >= self.section_count) return;

    const available = budget.safe_remaining();
    const count: u32 = if (self.build_estimator.is_warming_up())
        1
    else
        @intCast(@max(1, self.build_estimator.fit_in(available, .p75)));
    const end = @min(self.build_cursor + count, self.section_count);

    for (self.build_cursor..end) |i| {
        self.build_estimator.begin();
        self.sections[self.build_order[i]].rebuild(&self.pool, &self.atlas);
        self.build_estimator.end();
    }
    self.build_cursor = end;
}

/// Draw sky, terrain, and clouds. Handles frustum culling, sorting, and render passes.
pub fn draw(self: *Self, camera: *const Camera) void {
    Rendering.Pipeline.bind(self.pipeline);

    // Sky plane (drawn first, before terrain writes depth)
    Rendering.Texture.Default.bind();
    self.sky.draw_plane(camera);

    // Terrain fog
    set_terrain_fog();
    self.terrain.bind();

    // Frustum cull + 3D distance sort
    var visible: [MAX_SECTIONS]u32 = undefined;
    var dists: [MAX_SECTIONS]f32 = undefined;
    var visible_count: u32 = 0;

    for (0..self.section_count) |i| {
        const sec = &self.sections[i];
        if (!camera.section_visible(sec.cx, sec.sy, sec.cz)) continue;
        const vi = visible_count;
        visible[vi] = @intCast(i);
        dists[vi] = camera.distance_sq(sec.center_x(), sec.center_y(), sec.center_z());
        visible_count += 1;
    }

    // Sort by distance (insertion sort)
    for (1..visible_count) |i| {
        const key_vis = visible[i];
        const key_dist = dists[i];
        var j: u32 = @intCast(i);
        while (j > 0 and dists[j - 1] > key_dist) {
            visible[j] = visible[j - 1];
            dists[j] = dists[j - 1];
            j -= 1;
        }
        visible[j] = key_vis;
        dists[j] = key_dist;
    }

    // Pass 1: opaque front-to-back
    Rendering.gfx.api.set_alpha_blend(false);
    for (visible[0..visible_count]) |i| {
        self.sections[i].draw_opaque();
    }

    // Pass 2: transparent back-to-front
    Rendering.gfx.api.set_alpha_blend(true);
    var ri: u32 = visible_count;
    while (ri > 0) {
        ri -= 1;
        self.sections[visible[ri]].draw_transparent();
    }

    // Clouds (after terrain, depth test on)
    self.clouds.bind();
    self.sky.draw_clouds(camera);
}

fn set_terrain_fog() void {
    const c = Color.game_daytime;
    const fog_end: f32 = @floatFromInt(config.chunk_radius * 16 - 16);
    Rendering.gfx.api.set_fog(
        true,
        fog_end * 0.4,
        fog_end,
        @as(f32, @floatFromInt(c.r)) / 255.0,
        @as(f32, @floatFromInt(c.g)) / 255.0,
        @as(f32, @floatFromInt(c.b)) / 255.0,
    );
}

fn sort_by_distance(order: []u32, sections: []const ChunkMesh, cam: *const Camera) void {
    for (1..order.len) |i| {
        const key = order[i];
        const key_dist = cam.distance_sq_xz(sections[key].center_x(), sections[key].center_z());
        var j: u32 = @intCast(i);
        while (j > 0) {
            const prev_dist = cam.distance_sq_xz(sections[order[j - 1]].center_x(), sections[order[j - 1]].center_z());
            if (prev_dist <= key_dist) break;
            order[j] = order[j - 1];
            j -= 1;
        }
        order[j] = key;
    }
}
