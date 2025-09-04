const std = @import("std");

const Platform = @import("../platform/platform.zig");
const gfx = Platform.gfx;
const zm = @import("zmath");

fov: f32,
yaw: f32,
pitch: f32,

const Self = @This();

pub fn update(self: *Self) void {
    gfx.api.set_proj_matrix(self.get_projection_matrix());
    gfx.api.set_view_matrix(self.get_view_matrix());
}

pub fn get_projection_matrix(self: *Self) zm.Mat {
    const width: f32 = gfx.surface.get_width();
    const height: f32 = gfx.surface.get_height();

    return zm.perspectiveFovRhGl(std.math.degreesToRadians(self.fov), width / height, 0.3, 250.0);
}

pub fn get_view_matrix(self: *Self, target: *const zm.Vec) zm.Mat {
    const yaw = std.math.degreesToRadians(self.yaw);
    const pitch = std.math.degreesToRadians(self.pitch);

    // Negative because we want to move the world opposite to the camera
    const t = zm.translation(-target[0], -target[1], -target[2]);

    // Negative because we want to rotate the world opposite to the camera
    const ry = zm.rotationY(yaw);
    const rx = zm.rotationX(pitch);

    return zm.mul(zm.mul(t, ry), rx);
}
