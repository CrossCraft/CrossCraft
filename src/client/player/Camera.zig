const std = @import("std");
const assert = std.debug.assert;
const ae = @import("aether");
const caps = @import("capabilities").ClientType(ae);
const Math = ae.Math;
const Rendering = ae.Rendering;

const Camera = @This();

pub const near_plane: f32 = caps.render.near_plane;
pub const far_plane: f32 = caps.render.far_plane;

x: f32,
y: f32,
z: f32,
yaw: f32, // radians, 0 = looking -Z
pitch: f32, // radians, positive = looking up
fov: f32, // vertical FOV in radians
frustum: Math.Frustum,

// Player.sync_camera supplies view tilt and held-block sway.
tilt: Math.Mat4,
bob_hor: f32,
bob_ver: f32,

pub fn init(x: f32, y: f32, z: f32) Camera {
    return .{
        .x = x,
        .y = y,
        .z = z,
        .yaw = 0,
        .pitch = 0,
        .fov = 70.0 * std.math.pi / 180.0,
        .frustum = undefined,
        .tilt = Math.Mat4.identity(),
        .bob_hor = 0,
        .bob_ver = 0,
    };
}

pub fn apply(self: *Camera) void {
    assert(self.fov > 0.0 and self.fov < std.math.pi);
    assert(std.math.isFinite(self.x) and std.math.isFinite(self.y) and std.math.isFinite(self.z));
    assert(std.math.isFinite(self.yaw) and std.math.isFinite(self.pitch));
    const screen_w = Rendering.gfx.surface.get_width();
    const screen_h = Rendering.gfx.surface.get_height();
    const aspect: f32 = @as(f32, @floatFromInt(screen_w)) / @as(f32, @floatFromInt(screen_h));

    const proj = Math.Mat4.perspectiveFovRh(self.fov, aspect, near_plane, far_plane);
    Rendering.gfx.api.set_proj_matrix(&proj);

    const view = Math.Mat4.translation(-self.x, -self.y, -self.z)
        .mul(Math.Mat4.rotationY(-self.yaw))
        .mul(Math.Mat4.rotationX(self.pitch))
        .mul(self.tilt);
    Rendering.gfx.api.set_view_matrix(&view);

    // Row-vector convention: V * P.
    self.frustum = Math.Frustum.fromViewProjection(view.mul(proj));
}

/// Conservative AABB frustum test for a 16x16x16 section.
pub fn section_visible(self: *const Camera, cx: u32, sy: u32, cz: u32) bool {
    const wx: f32 = @floatFromInt(cx * 16);
    const wy: f32 = @floatFromInt(sy * 16);
    const wz: f32 = @floatFromInt(cz * 16);
    const aabb = Math.AABB{
        .min = Math.Vec3.new(wx, wy, wz),
        .max = Math.Vec3.new(wx + 16.0, wy + 16.0, wz + 16.0),
    };
    return self.frustum.containsAABB(aabb);
}

pub fn distance_sq(self: *const Camera, wx: f32, wy: f32, wz: f32) f32 {
    const dx = wx - self.x;
    const dy = wy - self.y;
    const dz = wz - self.z;
    return dx * dx + dy * dy + dz * dz;
}
