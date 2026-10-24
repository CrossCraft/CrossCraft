const std = @import("std");
const assert = std.debug.assert;
const ae = @import("aether");
const Math = ae.Math;
const Rendering = ae.Rendering;

const Vertex = @import("aether").Rendering.Vertex;
const Colors = @import("../../graphics/Color.zig");
const Color = Colors.Color;
const Camera = @import("../../player/Camera.zig");

const World = @import("core").World;

const BatchMesh = Rendering.MeshType(Vertex);
const BatchMeshData = Rendering.MeshDataType(Vertex);

// Fog reaches its end at 120 blocks, past which the plane equals the clear color; the plane only needs to reach that far at the screen's edges. The GE pays per vertex, so the grid stays coarse.
const PlaneGrid: u32 = 16;
const PlaneSize: f32 = 384.0;
const PlaneHalfSize: f32 = 192.0;
const SkyYOffset: f32 = 48.0;

const CloudGrid: u32 = 64;
const CloudSize: f32 = 1024.0;
const CloudHalfSize: f32 = 512.0;
const cloud_cell: f32 = CloudSize / @as(f32, @floatFromInt(CloudGrid));
/// Cloud cells beyond this many from the camera are fully fogged.
const CloudDrawRadiusCells: i32 = 11;
const CloudUvRepeats: u32 = 1;
/// Scales cloud UV density without changing the mesh.
const CloudTexScale: u32 = 2;
const CloudUvPeriod: f32 = CloudSize * @as(f32, @floatFromInt(CloudTexScale)) / @as(f32, @floatFromInt(CloudUvRepeats));
/// Keep clouds above tall worlds; the classic 64-block height gives Y=72.
const CloudYMargin: u32 = 8;
const CloudSpeed: f32 = 0.175;

const Sky = @This();

// Both meshes are built once; overlapping backends can borrow them as-is.
const static_desc: Rendering.mesh.Desc = .{ .retention = .static };

plane_data: BatchMeshData,
plane_mesh: BatchMesh,
cloud_data: BatchMeshData,
cloud_mesh: BatchMesh,
scroll: f32,
allocator: std.mem.Allocator,

pub fn init(allocator: std.mem.Allocator) !Sky {
    var self: Sky = .{
        .plane_data = try BatchMeshData.init(allocator),
        .plane_mesh = try BatchMesh.init(&static_desc),
        .cloud_data = try BatchMeshData.init(allocator),
        .cloud_mesh = try BatchMesh.init(&static_desc),
        .scroll = 0,
        .allocator = allocator,
    };
    try build_plane(allocator, &self.plane_data);
    try build_clouds(allocator, &self.cloud_data);
    self.plane_mesh.update(&self.plane_data);
    self.cloud_mesh.update(&self.cloud_data);
    return self;
}

pub fn deinit(self: *Sky) void {
    self.plane_mesh.deinit();
    self.cloud_mesh.deinit();
    self.plane_data.deinit(self.allocator);
    self.cloud_data.deinit(self.allocator);
    self.* = undefined;
}

pub fn update(self: *Sky, dt: f32) void {
    self.scroll += dt * CloudSpeed;
    while (self.scroll >= CloudUvPeriod) self.scroll -= CloudUvPeriod;
}

const collision = @import("../../player/collision.zig");

pub fn clear(submerged: ?collision.Liquid) void {
    const c = fog_color(submerged);
    Rendering.gfx.api.set_clear_color(
        @as(f32, @floatFromInt(c.r)) / 255.0,
        @as(f32, @floatFromInt(c.g)) / 255.0,
        @as(f32, @floatFromInt(c.b)) / 255.0,
        1.0,
    );
}

pub fn draw_plane(self: *Sky, camera: *const Camera, submerged: ?collision.Liquid, base: *const Rendering.RenderState) void {
    var state = base.*;
    state.texture = Rendering.Texture.Default.handle;
    state.fog = sky_fog(submerged);
    state.blend = .solid;
    // The camera-relative background can sit below the clouds. It must not
    // occlude them or terrain as the camera changes height.
    state.depth_write = false;
    Rendering.set_state(&state);
    const m = Math.Mat4.scaling(PlaneSize, 1.0, PlaneSize)
        .mul(Math.Mat4.translation(
        camera.x - PlaneHalfSize,
        camera.y + SkyYOffset,
        camera.z - PlaneHalfSize,
    ));
    self.plane_mesh.draw(&m);
}

/// `base` carries the cloud texture.
pub fn draw_clouds(self: *Sky, camera: *const Camera, submerged: ?collision.Liquid, base: *const Rendering.RenderState) void {
    const dims = World.data.dims;
    const center: f32 = @floatFromInt(dims.length / 2);
    const cloud_y: f32 = @floatFromInt(dims.height + CloudYMargin);
    const m = Math.Mat4.scaling(CloudSize, 1.0, CloudSize)
        .mul(Math.Mat4.translation(
        center - CloudHalfSize,
        cloud_y,
        center - CloudHalfSize,
    ));
    var state = base.*;
    state.fog = sky_fog(submerged);
    state.blend = .alpha;
    state.uv_offset = .{ -self.scroll / CloudUvPeriod, 0.0 };
    state.cull = false;
    Rendering.set_state(&state);
    // Rows are emitted z-major, so each row's visible cells are one range.
    const origin = center - CloudHalfSize;
    const cam_x: i32 = @intFromFloat(Math.floor((camera.x - origin) / cloud_cell));
    const cam_z: i32 = @intFromFloat(Math.floor((camera.z - origin) / cloud_cell));
    const last: i32 = @intCast(CloudGrid - 1);
    if (cam_x + CloudDrawRadiusCells < 0 or cam_x - CloudDrawRadiusCells > last or
        cam_z + CloudDrawRadiusCells < 0 or cam_z - CloudDrawRadiusCells > last) return;
    const x0 = Math.clamp(cam_x - CloudDrawRadiusCells, 0, last);
    const x1 = Math.clamp(cam_x + CloudDrawRadiusCells, 0, last);
    const z0 = Math.clamp(cam_z - CloudDrawRadiusCells, 0, last);
    const z1 = Math.clamp(cam_z + CloudDrawRadiusCells, 0, last);
    var z = z0;

    while (z <= z1) : (z += 1) {
        const first: u32 = @intCast(z * @as(i32, @intCast(CloudGrid)) + x0);
        const quads: u32 = @intCast(x1 - x0 + 1);
        // Six elements per quad: indices when indexed, vertices otherwise.
        self.cloud_mesh.draw_range(&m, first * 6, quads * 6);
    }
}

fn sky_fog(submerged: ?collision.Liquid) Rendering.FogState {
    const c = fog_color(submerged);
    const params = fog_params(submerged);
    return .{
        .enabled = true,
        .near = Camera.near_plane,
        .far = Camera.far_plane,
        .start = params[0],
        .end = params[1],
        .color = .{
            @as(f32, @floatFromInt(c.r)) / 255.0,
            @as(f32, @floatFromInt(c.g)) / 255.0,
            @as(f32, @floatFromInt(c.b)) / 255.0,
        },
    };
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

/// Map sky grid index [0, PlaneGrid] to SNORM16 [0, 32767].
fn encode_plane(i: u32) i16 {
    assert(i <= PlaneGrid);
    return @intCast(Math.min(@as(i32, @intCast(i)) * (32768 / PlaneGrid), 32767));
}

/// Map cloud grid index [0, CloudGrid] to SNORM16 [0, 32767].
fn encode_cloud_pos(i: u32) i16 {
    assert(i <= CloudGrid);
    return @intCast(Math.min(@as(i32, @intCast(i)) * (32768 / CloudGrid), 32767));
}

/// Per-tile UV range for clouds: monotonically increasing within each tile,
/// resetting at texture repeat boundaries to avoid SNORM wrap artifacts.
fn cloud_tile_uv(tile: u32) [2]i16 {
    const tiles_per_repeat = CloudGrid / CloudUvRepeats;
    const scale: i32 = 32768 / (tiles_per_repeat * CloudTexScale);
    const local: i32 = @intCast(tile % tiles_per_repeat);
    return .{
        @intCast(Math.min(local * scale, 32767)),
        @intCast(Math.min((local + 1) * scale, 32767)),
    };
}

fn build_plane(allocator: std.mem.Allocator, mesh: *BatchMeshData) !void {
    try mesh.ensure_quad_capacity(allocator, PlaneGrid * PlaneGrid);
    const color: u32 = @bitCast(Colors.game_daytime_zenith);

    var zi: u32 = 0;
    while (zi < PlaneGrid) : (zi += 1) {
        var xi: u32 = 0;
        while (xi < PlaneGrid) : (xi += 1) {
            emit_down_quad(mesh, encode_plane(xi), encode_plane(xi + 1), encode_plane(zi), encode_plane(zi + 1), color, 0, 0, 0, 0);
        }
    }
}

fn build_clouds(allocator: std.mem.Allocator, mesh: *BatchMeshData) !void {
    try mesh.ensure_quad_capacity(allocator, CloudGrid * CloudGrid);
    const color: u32 = 0xFFFFFFFF;

    var zi: u32 = 0;
    while (zi < CloudGrid) : (zi += 1) {
        const tv = cloud_tile_uv(zi);
        var xi: u32 = 0;
        while (xi < CloudGrid) : (xi += 1) {
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
    mesh.add_quad_assume_capacity(
        .{ .pos = .{ x0, 0, z1 }, .uv = .{ tu0, tv1 }, .color = color },
        .{ .pos = .{ x0, 0, z0 }, .uv = .{ tu0, tv0 }, .color = color },
        .{ .pos = .{ x1, 0, z0 }, .uv = .{ tu1, tv0 }, .color = color },
        .{ .pos = .{ x1, 0, z1 }, .uv = .{ tu1, tv1 }, .color = color },
    );
}
