const std = @import("std");

const Platform = @import("../platform/platform.zig");
const gfx = Platform.gfx;
const zm = @import("zmath");

fov: f32,
yaw: f32,
pitch: f32,
target: *const zm.Vec,

const Self = @This();

/// A simple 3D camera with position and orientation.
pub fn update(self: *Self) void {
    gfx.api.set_proj_matrix(&self.get_projection_matrix());
    gfx.api.set_view_matrix(&self.get_view_matrix());
}

/// Computes and returns the camera's projection matrix based on its field of view and the current aspect ratio.
pub fn get_projection_matrix(self: *Self) zm.Mat {
    const width: f32 = @floatFromInt(gfx.surface.get_width());
    const height: f32 = @floatFromInt(gfx.surface.get_height());

    return zm.perspectiveFovRhGl(std.math.degreesToRadians(self.fov), width / height, 0.3, 250.0);
}

/// Computes and returns the camera's view matrix based on its yaw and pitch angles, from the pespective of the target position.
pub fn get_view_matrix(self: *Self) zm.Mat {
    const yaw = std.math.degreesToRadians(self.yaw);
    const pitch = std.math.degreesToRadians(self.pitch);

    // Negative because we want to move the world opposite to the camera
    const t = zm.translation(-self.target[0], -self.target[1], -self.target[2]);

    // Negative because we want to rotate the world opposite to the camera
    const ry = zm.rotationY(yaw);
    const rx = zm.rotationX(pitch);

    return zm.mul(zm.mul(t, ry), rx);
}
