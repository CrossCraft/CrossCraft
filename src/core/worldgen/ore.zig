const std = @import("std");
const assert = std.debug.assert;

const random_state = @import("random.zig");
const terrain = @import("terrain.zig");
const carve = @import("carve.zig");

const resource_kind = enum {
    coal,
    iron,
    gold,

    pub fn material(self: resource_kind) u8 {
        return switch (self) {
            .coal => 16,
            .iron => 15,
            .gold => 14,
        };
    }

    pub fn abundance(self: resource_kind) u32 {
        return switch (self) {
            .coal => 90,
            .iron => 70,
            .gold => 50,
        };
    }
};

fn vein_attempt_count(dimensions: terrain.world_dimensions, kind: resource_kind) u64 {
    return ((@as(u64, dimensions.width) * dimensions.depth * dimensions.height / 256) / 64) *
        kind.abundance() / 100;
}

const vein_seed = struct {
    start: carve.point_32,
    length: u32,
    yaw: f32,
    pitch: f32,

    pub fn init(dimensions: terrain.world_dimensions, kind: resource_kind, random: *random_state) vein_seed {
        const x = random.next_float();
        const y = random.next_float();
        const z = random.next_float();
        const length_first = random.next_float();
        const length_second = random.next_float();
        const yaw = random.next_float();
        const pitch = random.next_float();

        const sum: f32 = length_first + length_second;
        const scaled_75: f32 = sum * @as(f32, 75.0);
        const scaled_abundance: f32 = scaled_75 * @as(f32, @floatFromInt(kind.abundance()));
        const length_value: f32 = scaled_abundance / @as(f32, 100.0);
        assert(length_value >= 0.0);
        return .{
            .start = .{
                .x = x * @as(f32, @floatFromInt(dimensions.width)),
                .y = y * @as(f32, @floatFromInt(dimensions.height)),
                .z = z * @as(f32, @floatFromInt(dimensions.depth)),
            },
            .length = @intFromFloat(length_value),
            .yaw = (yaw * carve.pi_32) * @as(f32, 2.0),
            .pitch = (pitch * carve.pi_32) * @as(f32, 2.0),
        };
    }

    pub fn initial_motion(self: vein_seed) carve.motion_32 {
        return .{
            .position = self.start,
            .yaw = self.yaw,
            .yaw_velocity = 0.0,
            .pitch = self.pitch,
            .pitch_velocity = 0.0,
        };
    }
};

fn vein_radius(kind: resource_kind, seed: vein_seed, step: u32) f32 {
    assert(seed.length > 0 and step < seed.length);
    const numerator: f32 = @as(f32, @floatFromInt(step)) * carve.pi_32;
    const phase: f32 = numerator / @as(f32, @floatFromInt(seed.length));
    const sine_scaled: f32 = carve.trajectory_sine(phase) * @as(f32, @floatFromInt(kind.abundance()));
    const abundance_radius: f32 = sine_scaled / @as(f32, 100.0);
    return abundance_radius + @as(f32, 1.0);
}

fn resource_pass(kind: resource_kind, random: *random_state, field: terrain.block_field) void {
    const attempts = vein_attempt_count(field.dimensions, kind);
    for (0..@as(usize, @intCast(attempts))) |_| {
        const seed = vein_seed.init(field.dimensions, kind, random);
        var motion = seed.initial_motion();
        for (0..seed.length) |step_usize| {
            const draws: carve.motion_draws = .{
                .yaw_positive = random.next_float(),
                .yaw_negative = random.next_float(),
                .pitch_positive = random.next_float(),
                .pitch_negative = random.next_float(),
            };
            const moved = carve.advanced_motion(motion);
            const turned = carve.turned_motion(0.9, moved, draws);
            const step: u32 = @intCast(step_usize);
            carve.replace_stone_ellipsoid(field, moved.position, vein_radius(kind, seed, step), kind.material());
            motion = turned;
        }
    }
}

pub fn all_resource_passes(random: *random_state, field: terrain.block_field) void {
    resource_pass(.coal, random, field);
    resource_pass(.iron, random, field);
    resource_pass(.gold, random, field);
}

test "resource constants and attempt counts follow the specification" {
    const dimensions: terrain.world_dimensions = .{ .width = 32, .height = 32, .depth = 32 };
    try std.testing.expectEqual(@as(u8, 16), resource_kind.coal.material());
    try std.testing.expectEqual(@as(u8, 15), resource_kind.iron.material());
    try std.testing.expectEqual(@as(u8, 14), resource_kind.gold.material());
    try std.testing.expectEqual(@as(u64, 1), vein_attempt_count(dimensions, .coal));
    try std.testing.expectEqual(@as(u64, 1), vein_attempt_count(dimensions, .iron));
    try std.testing.expectEqual(@as(u64, 1), vein_attempt_count(dimensions, .gold));
}

test "resource passes replace only stone" {
    const dimensions: terrain.world_dimensions = .{ .width = 32, .height = 32, .depth = 32 };
    const blocks = try std.testing.allocator.alloc(u8, dimensions.volume());
    defer std.testing.allocator.free(blocks);

    @memset(blocks, terrain.stone_id);
    blocks[0] = terrain.dirt_id;
    const field = terrain.block_field.init(dimensions, blocks);
    var random = random_state.init(1_234);
    all_resource_passes(&random, field);

    try std.testing.expectEqual(terrain.dirt_id, blocks[0]);
    var replaced = false;
    for (blocks) |material| {
        try std.testing.expect(material == terrain.stone_id or material == terrain.dirt_id or
            material == resource_kind.coal.material() or material == resource_kind.iron.material() or
            material == resource_kind.gold.material());
        replaced = replaced or (material != terrain.stone_id and material != terrain.dirt_id);
    }
    try std.testing.expect(replaced);
}
