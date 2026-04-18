const std = @import("std");
const ae = @import("aether");
const Math = ae.Math;
const Rendering = ae.Rendering;

const Self = @This();

x: f32,
y: f32,
z: f32,
yaw: f32, // radians, 0 = looking -Z
pitch: f32, // radians, positive = looking up
fov: f32, // vertical FOV in radians
frustum: Math.Frustum,

// View-bob state, written by Player.sync_camera and consumed by both
// the world view matrix (tilt) and the held-block renderer (bob_hor/ver
// for screen-space sway). Defaults are no-op so anything that doesn't
// touch them stays unaffected.
tilt: Math.Mat4,
bob_hor: f32,
bob_ver: f32,

pub fn init(x: f32, y: f32, z: f32) Self {
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

/// Build view + projection matrices, upload to GPU, extract frustum planes.
pub fn apply(self: *Self) void {
    const screen_w = Rendering.gfx.surface.get_width();
    const screen_h = Rendering.gfx.surface.get_height();
    const aspect: f32 = @as(f32, @floatFromInt(screen_w)) / @as(f32, @floatFromInt(screen_h));

    const proj = Math.Mat4.perspectiveFovRh(self.fov, aspect, if (ae.platform == .psp) 0.3275 else 0.1, if (ae.platform == .psp) 132.0 else 256.0);
    Rendering.gfx.api.set_proj_matrix(&proj);

    const view = Math.Mat4.translation(-self.x, -self.y, -self.z)
        .mul(Math.Mat4.rotationY(-self.yaw))
        .mul(Math.Mat4.rotationX(self.pitch))
        .mul(self.tilt);
    Rendering.gfx.api.set_view_matrix(&view);

    // VP for frustum extraction (row-vector convention = V * P)
    self.frustum = Math.Frustum.fromViewProjection(view.mul(proj));
}

/// Conservative AABB frustum test for a 16x16x16 section.
pub fn section_visible(self: *const Self, cx: u32, sy: u32, cz: u32) bool {
    const wx: f32 = @floatFromInt(cx * 16);
    const wy: f32 = @floatFromInt(sy * 16);
    const wz: f32 = @floatFromInt(cz * 16);
    const aabb = Math.AABB{
        .min = Math.Vec3.new(wx, wy, wz),
        .max = Math.Vec3.new(wx + 16.0, wy + 16.0, wz + 16.0),
    };
    return self.frustum.containsAABB(aabb);
}

/// Squared horizontal distance (XZ plane) from camera to a world point.
pub fn distance_sq_xz(self: *const Self, wx: f32, wz: f32) f32 {
    const dx = wx - self.x;
    const dz = wz - self.z;
    return dx * dx + dz * dz;
}

/// Squared 3D distance from camera to a world point.
pub fn distance_sq(self: *const Self, wx: f32, wy: f32, wz: f32) f32 {
    const dx = wx - self.x;
    const dy = wy - self.y;
    const dz = wz - self.z;
    return dx * dx + dy * dy + dz * dz;
}
