const std = @import("std");
const ae = @import("aether");
const caps = @import("capabilities").ClientType(ae);
const Math = ae.Math;
const Aabb = Math.Aabb;
const Rendering = ae.Rendering;

const Camera = @This();

pub const near_plane: f32 = caps.render.near_plane;
pub const far_plane: f32 = caps.render.far_plane;

x: f32,
y: f32,
z: f32,
yaw: f32, // radians, 0 = looking -Z
pitch: f32, // radians, applied as a positive X rotation in the view matrix
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

/// Adapts game-owned position, bob and tilt to Aether's explicit conventions.
/// The pointer is borrowed only while the returned camera is used locally.
fn engine_camera(self: *const Camera, position: *const Math.Vec3) Rendering.Camera {
    return .{
        .target = position,
        .fov = self.fov,
        .yaw = self.yaw,
        .pitch = self.pitch,
        .angle_unit = .radians,
        .yaw_direction = .left,
        .pitch_direction = .down,
        .near_plane = near_plane,
        .far_plane = far_plane,
        .view_adjustment = self.tilt,
    };
}

pub fn matrices(self: *const Camera, aspect: f32) Rendering.Camera.Error!Rendering.Camera.Matrices {
    const position = Math.Vec3.new(self.x, self.y, self.z);
    const camera = self.engine_camera(&position);
    return camera.matrices(aspect);
}

/// Particles retain the existing yaw/pitch facing and omit view bob/tilt.
pub fn billboard_basis(self: *const Camera) Rendering.BillboardBatcher.Basis {
    const origin = Math.Vec3.zero();
    var camera = self.engine_camera(&origin);
    camera.view_adjustment = null;
    return Rendering.BillboardBatcher.Basis.from_view(camera.get_view_matrix()) catch unreachable;
}

pub fn apply(self: *Camera) void {
    const result = self.matrices(Rendering.aspect_ratio()) catch unreachable;
    Rendering.gfx.api.set_proj_matrix(&result.projection);
    Rendering.gfx.api.set_view_matrix(&result.view);
    self.frustum = result.frustum;
}

/// Conservative AABB frustum test for a 16x16x16 section.
pub fn section_visible(self: *const Camera, cx: u32, sy: u32, cz: u32) bool {
    const wx: f32 = @floatFromInt(cx * 16);
    const wy: f32 = @floatFromInt(sy * 16);
    const wz: f32 = @floatFromInt(cz * 16);
    const aabb = Aabb{
        .min = Math.Vec3.new(wx, wy, wz),
        .max = Math.Vec3.new(wx + 16.0, wy + 16.0, wz + 16.0),
    };
    return self.frustum.contains_aabb(aabb);
}

pub fn distance_sq(self: *const Camera, wx: f32, wy: f32, wz: f32) f32 {
    const dx = wx - self.x;
    const dy = wy - self.y;
    const dz = wz - self.z;
    return dx * dx + dy * dy + dz * dz;
}

test "Aether camera preserves Classic view projection and frustum conventions" {
    var camera = Camera.init(302.5, 65.75, 401.25);
    camera.yaw = 1.25;
    camera.pitch = -0.35;
    camera.tilt = Math.Mat4.rotation_z(0.12).mul(Math.Mat4.translation(0.03, -0.02, 0));
    const result = try camera.matrices(16.0 / 9.0);
    const expected_view = Math.Mat4.translation(-camera.x, -camera.y, -camera.z)
        .mul(Math.Mat4.rotation_y(-camera.yaw))
        .mul(Math.Mat4.rotation_x(camera.pitch))
        .mul(camera.tilt);
    const expected_projection = Math.Mat4.perspective_fov_rh(camera.fov, 16.0 / 9.0, near_plane, far_plane);
    try std.testing.expectEqual(expected_view, result.view);
    try std.testing.expectEqual(expected_projection, result.projection);
    try std.testing.expectEqual(Math.Frustum.from_view_projection(expected_view.mul(expected_projection)), result.frustum);

    const basis = camera.billboard_basis();
    const expected_right = Math.Vec3.new(@cos(camera.yaw), 0, -@sin(camera.yaw));
    const expected_up = Math.Vec3.new(-@sin(camera.yaw) * @sin(camera.pitch), @cos(camera.pitch), -@cos(camera.yaw) * @sin(camera.pitch));
    try std.testing.expectApproxEqAbs(@as(f32, 0), basis.right.sub(expected_right).length(), 0.000001);
    try std.testing.expectApproxEqAbs(@as(f32, 0), basis.up.sub(expected_up).length(), 0.000001);
}
