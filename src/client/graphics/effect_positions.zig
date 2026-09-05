//! Legacy particle/rain meshes use 128 packed units per block and a 256x
//! model scale on every target. Selecting the 32768 divisor explicitly keeps
//! that existing convention, including its small desktop SNORM scale bias.
const Rendering = @import("aether").Rendering;

pub const encoding = Rendering.vertex.PositionEncoding.init(128, .psp_ge) catch unreachable;

test "effect positions preserve the existing 128 unit and 256 model scales" {
    const std = @import("std");
    try std.testing.expectEqual(@as(f32, 256), encoding.model_scale());
    try std.testing.expectEqual(@as(i16, 128), try encoding.encode_component(1));
    try std.testing.expectEqual(@as(i16, -32768), try encoding.encode_component(-256));
    try std.testing.expectError(error.PositionOutOfRange, encoding.encode_component(256));
}

test "effect billboards preserve Classic packed corners UVs winding and scale" {
    const std = @import("std");
    const Math = @import("aether").Math;
    const Camera = @import("../player/Camera.zig");
    var batch = try Rendering.BillboardBatcher.init(std.testing.allocator, .{
        .capacity = 1,
        .units_per_world_unit = encoding.units_per_world_unit,
        .normalization = encoding.normalization,
    });
    defer batch.deinit();

    const origin = Math.Vec3.new(500, 64, 300);
    const position = Math.Vec3.new(501.5, 61.75, 303.75);
    const uv: Rendering.BillboardBatcher.UvRegion = .{ .min = .{ 1, 2049 }, .max = .{ 511, 2559 } };
    for ([_][2]f32{ .{ 0, 0 }, .{ 0.7, -0.4 }, .{ -2.1, 1.2 }, .{ std.math.pi / 2.0, -std.math.pi / 4.0 } }) |angles| {
        var camera = Camera.init(origin.x, origin.y, origin.z);
        camera.yaw = angles[0];
        camera.pitch = angles[1];
        // Tilt is deliberately omitted from both historical effect bases.
        camera.tilt = Math.Mat4.rotation_z(0.2);
        for ([_]f32{ 0.06, 0.12 }) |half_size| {
            try batch.begin(origin, camera.billboard_basis());
            try batch.add(.{ .position = position, .size = .{ half_size * 2, half_size * 2 }, .uv = uv, .color = 0xff123456 });
            const cy = @cos(camera.yaw);
            const sy = @sin(camera.yaw);
            const cp = @cos(camera.pitch);
            const sp = @sin(camera.pitch);
            const rx = cy * half_size;
            const rz = -sy * half_size;
            const upx = -sy * sp * half_size;
            const upy = cp * half_size;
            const upz = -cy * sp * half_size;
            const historical = [4][3]f32{
                .{ 1.5 - rx - upx, -2.25 - upy, 3.75 - rz - upz },
                .{ 1.5 + rx - upx, -2.25 - upy, 3.75 + rz - upz },
                .{ 1.5 + rx + upx, -2.25 + upy, 3.75 + rz + upz },
                .{ 1.5 - rx + upx, -2.25 + upy, 3.75 - rz + upz },
            };
            const historical_uv = [4][2]i16{ .{ 1, 2559 }, .{ 511, 2559 }, .{ 511, 2049 }, .{ 1, 2049 } };
            const order: []const usize = if (Rendering.mesh.indexing_enabled) &.{ 0, 1, 2, 3 } else &.{ 0, 1, 2, 0, 2, 3 };
            for (batch.data.vertices.items, order) |vertex, corner| {
                for (vertex.pos, historical[corner]) |encoded_value, expected| {
                    try std.testing.expectEqual(@as(i16, @intFromFloat(@round(expected * 128))), encoded_value);
                }
                try std.testing.expectEqual(historical_uv[corner], vertex.uv);
                try std.testing.expectEqual(@as(u32, 0xff123456), vertex.color);
            }
            if (Rendering.mesh.indexing_enabled) try std.testing.expectEqualSlices(Rendering.mesh.Index, &.{ 0, 1, 2, 0, 2, 3 }, batch.data.indices.items);
            try std.testing.expectEqual(Math.Mat4.scaling(256, 256, 256).mul(Math.Mat4.translation(origin.x, origin.y, origin.z)), batch.model_matrix());
        }
    }
}
