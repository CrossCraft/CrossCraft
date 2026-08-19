const std = @import("std");
const ae = @import("aether");
const Math = ae.Math;
const Rendering = ae.Rendering;

const Vertex = @import("aether").Rendering.Vertex;
const Colors = @import("../../graphics/Color.zig");
const Color = Colors.Color;
const Camera = @import("../../player/Camera.zig");

const BatchMesh = Rendering.Mesh(Vertex);
const BatchMeshData = Rendering.MeshData(Vertex);

/// Sky plane: 64x64 grid of 16-unit tiles (1024x1024 total).
const PLANE_GRID: u32 = 64;
const PLANE_SIZE: f32 = 1024.0;
const HALF_SIZE: f32 = 512.0;
const SKY_Y_OFFSET: f32 = 48.0;

/// Clouds: 64x64 vertex grid, UV tiles at 0.5x (one repeat per 512 units).
const CLOUD_GRID: u32 = 64;
const CLOUD_UV_REPEATS: u32 = 1;
/// Texture appears this many times larger on screen without changing mesh;
/// UVs span 1/CLOUD_TEX_SCALE of the texture across the grid.
const CLOUD_TEX_SCALE: u32 = 2;
const CLOUD_UV_PERIOD: f32 = PLANE_SIZE * @as(f32, @floatFromInt(CLOUD_TEX_SCALE)) / @as(f32, @floatFromInt(CLOUD_UV_REPEATS));
const CLOUD_Y: f32 = 72.0;
const CLOUD_SPEED: f32 = 0.175;
const WORLD_CENTER: f32 = 128.0;

const Self = @This();

plane_data: BatchMeshData,
plane_mesh: BatchMesh,
cloud_data: BatchMeshData,
cloud_mesh: BatchMesh,
scroll: f32,
allocator: std.mem.Allocator,

pub fn init(allocator: std.mem.Allocator) !Self {
    var self: Self = .{
        .plane_data = try BatchMeshData.init(allocator),
        .plane_mesh = try BatchMesh.init(&.{}),
        .cloud_data = try BatchMeshData.init(allocator),
        .cloud_mesh = try BatchMesh.init(&.{}),
        .scroll = 0,
        .allocator = allocator,
    };
    try build_plane(allocator, &self.plane_data);
    try build_clouds(allocator, &self.cloud_data);
    self.plane_mesh.update(&self.plane_data);
    self.cloud_mesh.update(&self.cloud_data);
    return self;
}

pub fn deinit(self: *Self) void {
    self.plane_mesh.deinit();
    self.cloud_mesh.deinit();
    self.plane_data.deinit(self.allocator);
    self.cloud_data.deinit(self.allocator);
}

pub fn update(self: *Self, dt: f32) void {
    self.scroll += dt * CLOUD_SPEED;
    while (self.scroll >= CLOUD_UV_PERIOD) self.scroll -= CLOUD_UV_PERIOD;
}

const collision = @import("../../player/collision.zig");

/// Set the clear color based on whether the camera is submerged.
pub fn clear(submerged: ?collision.Liquid) void {
    const c = fog_color(submerged);
    Rendering.gfx.api.set_clear_color(
        @as(f32, @floatFromInt(c.r)) / 255.0,
        @as(f32, @floatFromInt(c.g)) / 255.0,
        @as(f32, @floatFromInt(c.b)) / 255.0,
        1.0,
    );
}

/// Draw sky "dome". Call before terrain
pub fn draw_plane(self: *Self, camera: *const Camera, submerged: ?collision.Liquid) void {
    set_sky_fog(submerged);
    Rendering.gfx.api.set_alpha_blend(false);
    const m = Math.Mat4.scaling(PLANE_SIZE, 1.0, PLANE_SIZE)
        .mul(Math.Mat4.translation(
        camera.x - HALF_SIZE,
        camera.y + SKY_Y_OFFSET,
        camera.z - HALF_SIZE,
    ));
    self.plane_mesh.draw(&m);
}

/// Draw cloud layer at fixed Y=72 anchored to the world center.
/// The UV offset slides clouds along +X over time without touching the mesh.
pub fn draw_clouds(self: *Self, _: *const Camera, submerged: ?collision.Liquid) void {
    set_sky_fog(submerged);
    Rendering.gfx.api.set_alpha_blend(true);
    const m = Math.Mat4.scaling(PLANE_SIZE, 1.0, PLANE_SIZE)
        .mul(Math.Mat4.translation(
        WORLD_CENTER - HALF_SIZE,
        CLOUD_Y,
        WORLD_CENTER - HALF_SIZE,
    ));
    Rendering.gfx.api.set_uv_offset(-self.scroll / CLOUD_UV_PERIOD, 0.0);
    Rendering.gfx.api.set_culling(false);
    self.cloud_mesh.draw(&m);
    Rendering.gfx.api.set_culling(true);
    Rendering.gfx.api.set_uv_offset(0.0, 0.0);
}

// --- Fog ---

fn set_sky_fog(submerged: ?collision.Liquid) void {
    const c = fog_color(submerged);
    const params = fog_params(submerged);
    Rendering.gfx.api.set_fog(
        true,
        Camera.near_plane,
        Camera.far_plane,
        params[0],
        params[1],
        @as(f32, @floatFromInt(c.r)) / 255.0,
        @as(f32, @floatFromInt(c.g)) / 255.0,
        @as(f32, @floatFromInt(c.b)) / 255.0,
    );
}

fn fog_color(submerged: ?collision.Liquid) Color {
    return switch (submerged orelse return Colors.game_daytime) {
        .water => Colors.game_underwater,
        .lava => Colors.game_underlava,
    };
}

fn fog_params(submerged: ?collision.Liquid) [2]f32 {
    return switch (submerged orelse return .{ 40.0, 120.0 }) {
        .water => .{ 0.0, 16.0 },
        .lava => .{ 0.0, 2.0 },
    };
}

// --- Mesh building ---

/// Map sky grid index [0, PLANE_GRID] to SNORM16 [0, 32767].
fn encode_plane(i: u32) i16 {
    std.debug.assert(i <= PLANE_GRID);
    return @intCast(@min(@as(i32, @intCast(i)) * (32768 / PLANE_GRID), 32767));
}

/// Map cloud grid index [0, CLOUD_GRID] to SNORM16 [0, 32767].
fn encode_cloud_pos(i: u32) i16 {
    std.debug.assert(i <= CLOUD_GRID);
    return @intCast(@min(@as(i32, @intCast(i)) * (32768 / CLOUD_GRID), 32767));
}

/// Per-tile UV range for clouds: monotonically increasing within each tile,
/// resetting at texture repeat boundaries to avoid SNORM wrap artifacts.
fn cloud_tile_uv(tile: u32) [2]i16 {
    const tiles_per_repeat = CLOUD_GRID / CLOUD_UV_REPEATS;
    const scale: i32 = 32768 / (tiles_per_repeat * CLOUD_TEX_SCALE);
    const local: i32 = @intCast(tile % tiles_per_repeat);
    return .{
        @intCast(@min(local * scale, 32767)),
        @intCast(@min((local + 1) * scale, 32767)),
    };
}

fn build_plane(allocator: std.mem.Allocator, mesh: *BatchMeshData) !void {
    try mesh.ensure_quad_capacity(allocator, PLANE_GRID * PLANE_GRID);
    const color: u32 = @bitCast(Colors.game_daytime_zenith);

    var zi: u32 = 0;
    while (zi < PLANE_GRID) : (zi += 1) {
        var xi: u32 = 0;
        while (xi < PLANE_GRID) : (xi += 1) {
            emit_down_quad(mesh, encode_plane(xi), encode_plane(xi + 1), encode_plane(zi), encode_plane(zi + 1), color, 0, 0, 0, 0);
        }
    }
}

fn build_clouds(allocator: std.mem.Allocator, mesh: *BatchMeshData) !void {
    try mesh.ensure_quad_capacity(allocator, CLOUD_GRID * CLOUD_GRID);
    const color: u32 = 0xFFFFFFFF;

    var zi: u32 = 0;
    while (zi < CLOUD_GRID) : (zi += 1) {
        const tv = cloud_tile_uv(zi);
        var xi: u32 = 0;
        while (xi < CLOUD_GRID) : (xi += 1) {
            const tu = cloud_tile_uv(xi);
            emit_down_quad(mesh, encode_cloud_pos(xi), encode_cloud_pos(xi + 1), encode_cloud_pos(zi), encode_cloud_pos(zi + 1), color, tu[0], tu[1], tv[0], tv[1]);
        }
    }
}

/// Emit a downward-facing quad (y_neg winding from face.zig).
fn emit_down_quad(
    mesh: *BatchMeshData,
    x0: i16,
    x1: i16,
    z0: i16,
    z1: i16,
    color: u32,
    tu0: i16,
    tu1: i16,
    tv0: i16,
    tv1: i16,
) void {
    // v0=(x0,z1) v1=(x1,z1) v2=(x1,z0) v3=(x0,z0); emit 0,2,1 then 0,3,2
    mesh.add_quad_assume_capacity(
        .{ .pos = .{ x0, 0, z1 }, .uv = .{ tu0, tv1 }, .color = color },
        .{ .pos = .{ x0, 0, z0 }, .uv = .{ tu0, tv0 }, .color = color },
        .{ .pos = .{ x1, 0, z0 }, .uv = .{ tu1, tv0 }, .color = color },
        .{ .pos = .{ x1, 0, z1 }, .uv = .{ tu1, tv1 }, .color = color },
    );
}
