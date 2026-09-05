const std = @import("std");
const assert = std.debug.assert;

const random_state = @import("random.zig");
const terrain = @import("terrain.zig");
const noise_module = @import("noise.zig");

pub const pi_32: f32 = 3.1415927;
pub const pi_64: f64 = 3.141592653589793;

const offset_memo_max = 64;

// Shared read-only lookup avoids rebuilding a 256 KiB table on every world.
const sine_table: [65_536]f32 = blk: {
    @setEvalBranchQuota(65_536 * 6);
    var table: [65_536]f32 = undefined;
    for (0..table.len) |index| {
        const angle = @as(f64, @floatFromInt(index)) * pi_64 * 2.0 / 65_536.0;
        table[index] = @floatCast(@sin(angle));
    }
    break :blk table;
};

pub fn trajectory_sine(angle: f32) f32 {
    const scaled: f32 = angle * @as(f32, 10_430.378);
    const integral: i32 = @intFromFloat(scaled);
    const index: u16 = @truncate(@as(u32, @bitCast(integral)));
    return sine_table[index];
}

fn trajectory_cosine(angle: f32) f32 {
    const scaled: f32 = angle * @as(f32, 10_430.378);
    const shifted: f32 = scaled + @as(f32, 16_384.0);
    const integral: i32 = @intFromFloat(shifted);
    const index: u16 = @truncate(@as(u32, @bitCast(integral)));
    return sine_table[index];
}

pub const point_32 = struct {
    x: f32,
    y: f32,
    z: f32,
};

pub const motion_32 = struct {
    position: point_32,
    yaw: f32,
    yaw_velocity: f32,
    pitch: f32,
    pitch_velocity: f32,
};

pub const motion_draws = struct {
    yaw_positive: f32,
    yaw_negative: f32,
    pitch_positive: f32,
    pitch_negative: f32,
};

pub fn advanced_motion(motion: motion_32) motion_32 {
    const horizontal = trajectory_cosine(motion.pitch);
    const x_delta: f32 = trajectory_sine(motion.yaw) * horizontal;
    const z_delta: f32 = trajectory_cosine(motion.yaw) * horizontal;
    return .{
        .position = .{
            .x = motion.position.x + x_delta,
            .y = motion.position.y + trajectory_sine(motion.pitch),
            .z = motion.position.z + z_delta,
        },
        .yaw = motion.yaw,
        .yaw_velocity = motion.yaw_velocity,
        .pitch = motion.pitch,
        .pitch_velocity = motion.pitch_velocity,
    };
}

pub fn turned_motion(pitch_damping: f32, motion: motion_32, draws: motion_draws) motion_32 {
    const pitch_intermediate: f32 = motion.pitch + motion.pitch_velocity * @as(f32, 0.5);
    const yaw_difference: f32 = draws.yaw_positive - draws.yaw_negative;
    const pitch_difference: f32 = draws.pitch_positive - draws.pitch_negative;
    return .{
        .position = motion.position,
        .yaw = motion.yaw + motion.yaw_velocity * @as(f32, 0.2),
        .yaw_velocity = motion.yaw_velocity * @as(f32, 0.9) + yaw_difference,
        .pitch = pitch_intermediate * @as(f32, 0.5),
        .pitch_velocity = motion.pitch_velocity * pitch_damping + pitch_difference,
    };
}

fn coordinate_bounds(center: f32, radius: f32, dimension: u32) struct { first: u32, end: u32 } {
    const extent = @abs(radius) + @as(f32, 1.0);
    // Keep bounds in f32 to avoid PSP soft-float calls.
    const raw_first: i32 = @intFromFloat(noise_module.floor_f32(center - extent));
    const raw_last: i32 = @intFromFloat(noise_module.ceil_f32(center + extent));
    const maximum: i32 = @intCast(dimension - 2);
    const first: u32 = @intCast(std.math.clamp(raw_first, 1, maximum));
    const last: u32 = @intCast(std.math.clamp(raw_last, 1, maximum));
    return .{ .first = first, .end = last + 1 };
}

fn walk_ellipsoid_row(
    walk_field: terrain.block_field,
    dz_squared: f32,
    radius_squared: f32,
    dy_squared_twice: f32,
    z: u32,
    y: u32,
    x_first: u32,
    walk_material: u8,
    dx_squared_memo: *const [offset_memo_max]f32,
    x_range_start: i32,
    x_range_end_excl: i32,
    row_minimum_x: i32,
) void {
    const row_base = walk_field.dimensions.index(x_first, y, z);
    // Walk away from the nearest x until the ellipsoid predicate fails.
    var cell_index = row_base + @as(usize, @intCast(row_minimum_x - x_range_start));
    var memo_index: usize = @intCast(row_minimum_x - x_range_start);
    var x_down: i32 = row_minimum_x;
    while (x_down >= x_range_start) {
        const dx_squared = dx_squared_memo[memo_index];
        const horizontal_and_vertical: f32 = dx_squared + dy_squared_twice;
        const metric: f32 = horizontal_and_vertical + dz_squared;
        if (metric >= radius_squared) break;
        if (walk_field.blocks[cell_index] == terrain.stone_id)
            walk_field.blocks[cell_index] = walk_material;
        if (x_down == x_range_start) break;
        x_down -= 1;
        cell_index -= 1;
        memo_index -= 1;
    }
    cell_index = row_base + @as(usize, @intCast(row_minimum_x + 1 - x_range_start));
    memo_index = @intCast(row_minimum_x + 1 - x_range_start);
    var x_up: i32 = row_minimum_x + 1;
    while (x_up < x_range_end_excl) {
        const dx_squared = dx_squared_memo[memo_index];
        const horizontal_and_vertical: f32 = dx_squared + dy_squared_twice;
        const metric: f32 = horizontal_and_vertical + dz_squared;
        if (metric >= radius_squared) break;
        if (walk_field.blocks[cell_index] == terrain.stone_id)
            walk_field.blocks[cell_index] = walk_material;
        if (x_up == x_range_end_excl - 1) break;
        x_up += 1;
        cell_index += 1;
        memo_index += 1;
    }
}

pub fn replace_stone_ellipsoid(field: terrain.block_field, center: point_32, radius: f32, material: u8) void {
    const dimensions = field.dimensions;
    const radius_squared: f32 = radius * radius;
    const x_bounds = coordinate_bounds(center.x, radius, dimensions.width);
    const y_bounds = coordinate_bounds(center.y, radius, dimensions.height);
    const z_bounds = coordinate_bounds(center.z, radius, dimensions.depth);

    if (x_bounds.end - x_bounds.first > offset_memo_max or
        y_bounds.end - y_bounds.first > offset_memo_max or
        z_bounds.end - z_bounds.first > offset_memo_max)
    {
        for (x_bounds.first..x_bounds.end) |x_usize| {
            const x: u32 = @intCast(x_usize);
            const dx: f32 = @as(f32, @floatFromInt(x)) - center.x;
            const dx_squared: f32 = dx * dx;
            for (y_bounds.first..y_bounds.end) |y_usize| {
                const y: u32 = @intCast(y_usize);
                const dy: f32 = @as(f32, @floatFromInt(y)) - center.y;
                const horizontal_and_vertical: f32 = dx_squared + dy * dy * @as(f32, 2.0);
                var block_index = dimensions.index(x, y, z_bounds.first);
                for (z_bounds.first..z_bounds.end) |z_usize| {
                    const z: u32 = @intCast(z_usize);
                    const dz: f32 = @as(f32, @floatFromInt(z)) - center.z;
                    const metric: f32 = horizontal_and_vertical + dz * dz;
                    if (metric < radius_squared and field.blocks[block_index] == terrain.stone_id)
                        field.blocks[block_index] = material;
                    block_index += @as(usize, dimensions.width);
                }
            }
        }
        return;
    }

    var dx_squared_memo: [offset_memo_max]f32 = undefined;
    for (x_bounds.first..x_bounds.end) |x_usize| {
        const x: u32 = @intCast(x_usize);
        const dx: f32 = @as(f32, @floatFromInt(x)) - center.x;
        dx_squared_memo[x_usize - x_bounds.first] = dx * dx;
    }

    // Walk outward from the nearest cell; the ellipsoid metric increases
    // monotonically along each axis, so each direction stops at its first miss.
    const nearest_x: i32 = @intFromFloat(@round(center.x));
    const x_range_start: i32 = @intCast(x_bounds.first);
    const x_range_end_excl: i32 = @intCast(x_bounds.end);
    const row_minimum_x: i32 = std.math.clamp(nearest_x, x_range_start, x_range_end_excl - 1);
    const row_minimum_x_dist: f32 = @as(f32, @floatFromInt(row_minimum_x)) - center.x;
    const min_dx_squared: f32 = row_minimum_x_dist * row_minimum_x_dist;

    const nearest_y: i32 = @intFromFloat(@round(center.y));
    const y_range_start: i32 = @intCast(y_bounds.first);
    const y_range_end_excl: i32 = @intCast(y_bounds.end);
    const row_minimum_y: i32 = std.math.clamp(nearest_y, y_range_start, y_range_end_excl - 1);

    const nearest_z: i32 = @intFromFloat(@round(center.z));
    const z_range_start: i32 = @intCast(z_bounds.first);
    const z_range_end_excl: i32 = @intCast(z_bounds.end);
    const row_minimum_z: i32 = std.math.clamp(nearest_z, z_range_start, z_range_end_excl - 1);
    const row_minimum_z_dist: f32 = @as(f32, @floatFromInt(row_minimum_z)) - center.z;
    const min_dz_squared: f32 = row_minimum_z_dist * row_minimum_z_dist;

    var y_down: i32 = row_minimum_y;
    while (y_down >= y_range_start) : (y_down -= 1) {
        const y: u32 = @intCast(y_down);
        const dy: f32 = @as(f32, @floatFromInt(y)) - center.y;
        const dy_squared: f32 = dy * dy;
        const dy_squared_twice: f32 = dy_squared * @as(f32, 2.0);
        const row_xy: f32 = min_dx_squared + dy_squared_twice;
        if (row_xy + min_dz_squared >= radius_squared) break;
        var z_down: i32 = row_minimum_z;
        while (z_down >= z_range_start) : (z_down -= 1) {
            const z: u32 = @intCast(z_down);
            const dz: f32 = @as(f32, @floatFromInt(z)) - center.z;
            const dz_squared: f32 = dz * dz;
            if (row_xy + dz_squared >= radius_squared) break;
            walk_ellipsoid_row(field, dz_squared, radius_squared, dy_squared_twice, z, y, x_bounds.first, material, &dx_squared_memo, x_range_start, x_range_end_excl, row_minimum_x);
        }
        var z_up: i32 = row_minimum_z + 1;
        while (z_up < z_range_end_excl) : (z_up += 1) {
            const z: u32 = @intCast(z_up);
            const dz: f32 = @as(f32, @floatFromInt(z)) - center.z;
            const dz_squared: f32 = dz * dz;
            if (row_xy + dz_squared >= radius_squared) break;
            walk_ellipsoid_row(field, dz_squared, radius_squared, dy_squared_twice, z, y, x_bounds.first, material, &dx_squared_memo, x_range_start, x_range_end_excl, row_minimum_x);
        }
    }
    var y_up: i32 = row_minimum_y + 1;
    while (y_up < y_range_end_excl) : (y_up += 1) {
        const y: u32 = @intCast(y_up);
        const dy: f32 = @as(f32, @floatFromInt(y)) - center.y;
        const dy_squared: f32 = dy * dy;
        const dy_squared_twice: f32 = dy_squared * @as(f32, 2.0);
        const row_xy: f32 = min_dx_squared + dy_squared_twice;
        if (row_xy + min_dz_squared >= radius_squared) break;
        var z_down: i32 = row_minimum_z;
        while (z_down >= z_range_start) : (z_down -= 1) {
            const z: u32 = @intCast(z_down);
            const dz: f32 = @as(f32, @floatFromInt(z)) - center.z;
            const dz_squared: f32 = dz * dz;
            if (row_xy + dz_squared >= radius_squared) break;
            walk_ellipsoid_row(field, dz_squared, radius_squared, dy_squared_twice, z, y, x_bounds.first, material, &dx_squared_memo, x_range_start, x_range_end_excl, row_minimum_x);
        }
        var z_up: i32 = row_minimum_z + 1;
        while (z_up < z_range_end_excl) : (z_up += 1) {
            const z: u32 = @intCast(z_up);
            const dz: f32 = @as(f32, @floatFromInt(z)) - center.z;
            const dz_squared: f32 = dz * dz;
            if (row_xy + dz_squared >= radius_squared) break;
            walk_ellipsoid_row(field, dz_squared, radius_squared, dy_squared_twice, z, y, x_bounds.first, material, &dx_squared_memo, x_range_start, x_range_end_excl, row_minimum_x);
        }
    }
}

const cave_seed = struct {
    start: point_32,
    length: u32,
    yaw: f32,
    pitch: f32,
    radius_factor: f32,

    pub fn init(dimensions: terrain.world_dimensions, random: *random_state) cave_seed {
        const x = random.next_float();
        const y = random.next_float();
        const z = random.next_float();
        const length_first = random.next_float();
        const length_second = random.next_float();
        const yaw = random.next_float();
        const pitch = random.next_float();
        const radius_first = random.next_float();
        const radius_second = random.next_float();
        const length_sum: f32 = length_first + length_second;
        const length_value: f32 = length_sum * @as(f32, 200.0);
        assert(length_value >= 0.0);
        return .{
            .start = .{
                .x = x * @as(f32, @floatFromInt(dimensions.width)),
                .y = y * @as(f32, @floatFromInt(dimensions.height)),
                .z = z * @as(f32, @floatFromInt(dimensions.depth)),
            },
            .length = @intFromFloat(length_value),
            .yaw = (yaw * pi_32) * @as(f32, 2.0),
            .pitch = (pitch * pi_32) * @as(f32, 2.0),
            .radius_factor = radius_first * radius_second,
        };
    }

    pub fn initial_motion(self: cave_seed) motion_32 {
        return .{
            .position = self.start,
            .yaw = self.yaw,
            .yaw_velocity = 0.0,
            .pitch = self.pitch,
            .pitch_velocity = 0.0,
        };
    }
};

fn cave_center(motion: motion_32, x_draw: f32, y_draw: f32, z_draw: f32) point_32 {
    const x_offset: f32 = ((x_draw * @as(f32, 4.0)) - @as(f32, 2.0)) * @as(f32, 0.2);
    const y_offset: f32 = ((y_draw * @as(f32, 4.0)) - @as(f32, 2.0)) * @as(f32, 0.2);
    const z_offset: f32 = ((z_draw * @as(f32, 4.0)) - @as(f32, 2.0)) * @as(f32, 0.2);
    return .{
        .x = motion.position.x + x_offset,
        .y = motion.position.y + y_offset,
        .z = motion.position.z + z_offset,
    };
}

fn cave_radius(dimensions: terrain.world_dimensions, seed: cave_seed, step: u32, center: point_32) f32 {
    assert(seed.length > 0 and step < seed.length);
    const height: f32 = @floatFromInt(dimensions.height);
    const vertical: f32 = (height - center.y) / height;
    const depth_scale: f32 = vertical * @as(f32, 3.5) + @as(f32, 1.0);
    const maximum: f32 = @as(f32, 1.2) + depth_scale * seed.radius_factor;
    const numerator: f32 = @as(f32, @floatFromInt(step)) * pi_32;
    const phase: f32 = numerator / @as(f32, @floatFromInt(seed.length));
    return trajectory_sine(phase) * maximum;
}

pub fn cave_pass(random: *random_state, field: terrain.block_field) void {
    const dimensions = field.dimensions;
    const attempts = ((@as(u64, dimensions.width) * dimensions.depth * dimensions.height / 256) / 64) * 2;
    for (0..@as(usize, @intCast(attempts))) |_| {
        const seed = cave_seed.init(dimensions, random);
        var motion = seed.initial_motion();
        for (0..seed.length) |step_usize| {
            const yaw_positive = random.next_float();
            const yaw_negative = random.next_float();
            const pitch_positive = random.next_float();
            const pitch_negative = random.next_float();
            const decision = random.next_float();
            const moved = advanced_motion(motion);
            const turned = turned_motion(0.75, moved, .{
                .yaw_positive = yaw_positive,
                .yaw_negative = yaw_negative,
                .pitch_positive = pitch_positive,
                .pitch_negative = pitch_negative,
            });
            if (decision >= 0.25) {
                const center = cave_center(moved, random.next_float(), random.next_float(), random.next_float());
                const step: u32 = @intCast(step_usize);
                const radius = cave_radius(dimensions, seed, step, center);
                replace_stone_ellipsoid(field, center, radius, terrain.air_id);
            }
            motion = turned;
        }
    }
}

test "sine lookup has specified phase endpoints" {
    try std.testing.expectEqual(@as(f32, 0.0), sine_table[0]);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), sine_table[16_384], 0.000001);
    try std.testing.expectEqual(sine_table[0], trajectory_sine(0.0));
    try std.testing.expectEqual(sine_table[16_384], trajectory_cosine(0.0));
}

test "ellipsoid replacement touches only interior stone" {
    const dimensions: terrain.world_dimensions = .{ .width = 16, .height = 16, .depth = 16 };
    const blocks = try std.testing.allocator.alloc(u8, dimensions.volume());
    defer std.testing.allocator.free(blocks);

    @memset(blocks, terrain.dirt_id);
    const field = terrain.block_field.init(dimensions, blocks);
    field.set(8, 8, 8, terrain.stone_id);
    field.set(9, 8, 8, terrain.dirt_id);
    field.set(0, 8, 8, terrain.stone_id);
    replace_stone_ellipsoid(field, .{ .x = 8.0, .y = 8.0, .z = 8.0 }, 2.0, terrain.air_id);
    try std.testing.expectEqual(terrain.air_id, field.at(8, 8, 8));
    try std.testing.expectEqual(terrain.dirt_id, field.at(9, 8, 8));
    try std.testing.expectEqual(terrain.stone_id, field.at(0, 8, 8));
}

test "zero-volume cave count preserves field and state" {
    const dimensions: terrain.world_dimensions = .{ .width = 16, .height = 16, .depth = 16 };
    const blocks = try std.testing.allocator.alloc(u8, dimensions.volume());
    defer std.testing.allocator.free(blocks);

    @memset(blocks, terrain.stone_id);
    const field = terrain.block_field.init(dimensions, blocks);
    var random = random_state.init(99);
    const state = random.state;
    cave_pass(&random, field);
    try std.testing.expectEqual(state, random.state);
}

test "cave pass only removes stone" {
    const dimensions: terrain.world_dimensions = .{ .width = 32, .height = 32, .depth = 32 };
    const blocks = try std.testing.allocator.alloc(u8, dimensions.volume());
    defer std.testing.allocator.free(blocks);

    @memset(blocks, terrain.stone_id);
    const field = terrain.block_field.init(dimensions, blocks);
    var random = random_state.init(-300);
    cave_pass(&random, field);

    var carved = false;
    for (blocks) |material| {
        try std.testing.expect(material == terrain.stone_id or material == terrain.air_id);
        carved = carved or material == terrain.air_id;
    }
    try std.testing.expect(carved);
}
