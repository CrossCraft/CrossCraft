const zm = @import("zmath");

pos: zm.Vec,
rot: zm.Vec,
scale: zm.Vec,

const Self = @This();
pub fn new() Self {
    return .{
        .pos = @splat(0),
        .rot = @splat(0),
        .scale = @splat(1),
    };
}

pub fn get_matrix(self: *const Self) zm.Mat {
    const scaling = zm.scaling(self.scale[0], self.scale[1], self.scale[2]);
    const rotation_x = zm.rotation_x(self.rot[0]);
    const rotation_y = zm.rotation_y(self.rot[1]);
    const rotation_z = zm.rotation_z(self.rot[2]);

    const rotation = zm.mul(zm.mul(rotation_z, rotation_x), rotation_y);
    const translation = zm.translation(self.pos[0], self.pos[1], self.pos[2]);

    return zm.mul(scaling, zm.mul(rotation, translation));
}
