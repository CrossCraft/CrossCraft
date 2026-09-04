const std = @import("std");
const assert = std.debug.assert;

const random_state = @import("random.zig");
const terrain = @import("terrain.zig");
const carve = @import("carve.zig");
const ore = @import("ore.zig");

const level = @This();

pub const world_dimensions = terrain.world_dimensions;

const first_flower_id: u8 = 37;
const second_flower_id: u8 = 38;
const first_mushroom_id: u8 = 39;
const second_mushroom_id: u8 = 40;
const trunk_id: u8 = 17;
const foliage_id: u8 = 18;

const horizontal_walk_point = struct { x: i32, z: i32 };
const subterranean_walk_point = struct { x: i32, y: i32, z: i32 };
const lattice_position = struct { x: i32, y: i32, z: i32 };

blocks: []u8,

fn horizontal_inside(dimensions: world_dimensions, point: horizontal_walk_point) bool {
    const width: i32 = @intCast(dimensions.width);
    const depth: i32 = @intCast(dimensions.depth);
    return point.x >= 0 and point.x < width and point.z >= 0 and point.z < depth;
}

fn flower_eligible(field: terrain.block_field, elevation: *const terrain.elevation_cache, point: horizontal_walk_point) bool {
    if (!horizontal_inside(field.dimensions, point)) return false;
    const x: u32 = @intCast(point.x);
    const z: u32 = @intCast(point.z);
    const top = elevation.surface_height(field.dimensions, x, z);
    return field.at(x, top + 1, z) == terrain.air_id and field.at(x, top, z) == terrain.grass_id;
}

fn place_flower(field: terrain.block_field, elevation: *const terrain.elevation_cache, material: u8, point: horizontal_walk_point) void {
    if (!flower_eligible(field, elevation, point)) return;
    const x: u32 = @intCast(point.x);
    const z: u32 = @intCast(point.z);
    field.set(x, elevation.surface_height(field.dimensions, x, z) + 1, z, material);
}

fn flower_walk(random: *random_state, field: terrain.block_field, elevation: *const terrain.elevation_cache, material: u8, origin: horizontal_walk_point) void {
    var point = origin;
    for (0..5) |_| {
        const x_positive = random.next_int_bounded(6);
        const x_negative = random.next_int_bounded(6);
        const z_positive = random.next_int_bounded(6);
        const z_negative = random.next_int_bounded(6);
        point.x += @as(i32, @intCast(x_positive)) - @as(i32, @intCast(x_negative));
        point.z += @as(i32, @intCast(z_positive)) - @as(i32, @intCast(z_negative));
        place_flower(field, elevation, material, point);
    }
}

fn flower_pass(random: *random_state, field: terrain.block_field, elevation: *const terrain.elevation_cache) void {
    const attempts = @as(u64, field.dimensions.width) * field.dimensions.depth / 3000;
    for (0..@as(usize, @intCast(attempts))) |_| {
        const material = if (random.next_int_bounded(2) == 0) first_flower_id else second_flower_id;
        const origin: horizontal_walk_point = .{
            .x = @intCast(random.next_int_bounded(field.dimensions.width)),
            .z = @intCast(random.next_int_bounded(field.dimensions.depth)),
        };
        for (0..10) |_| flower_walk(random, field, elevation, material, origin);
    }
}

fn mushroom_eligible(field: terrain.block_field, elevation: *const terrain.elevation_cache, point: subterranean_walk_point) bool {
    const width: i32 = @intCast(field.dimensions.width);
    const depth: i32 = @intCast(field.dimensions.depth);
    if (point.x < 0 or point.x >= width or point.z < 0 or
        point.z >= depth or point.y < 1)
        return false;
    const x: u32 = @intCast(point.x);
    const y: u32 = @intCast(point.y);
    const z: u32 = @intCast(point.z);
    const surface_height = elevation.surface_height(field.dimensions, x, z);
    if (surface_height <= 1 or point.y >= @as(i32, @intCast(surface_height)) - 1) return false;
    return field.at(x, y, z) == terrain.air_id and field.at(x, y - 1, z) == terrain.stone_id;
}

fn place_mushroom(field: terrain.block_field, elevation: *const terrain.elevation_cache, material: u8, point: subterranean_walk_point) void {
    if (!mushroom_eligible(field, elevation, point)) return;
    field.set(@intCast(point.x), @intCast(point.y), @intCast(point.z), material);
}

fn mushroom_walk(random: *random_state, field: terrain.block_field, elevation: *const terrain.elevation_cache, material: u8, origin: subterranean_walk_point) void {
    var point = origin;
    for (0..5) |_| {
        const x_positive = random.next_int_bounded(6);
        const x_negative = random.next_int_bounded(6);
        const y_positive = random.next_int_bounded(2);
        const y_negative = random.next_int_bounded(2);
        const z_positive = random.next_int_bounded(6);
        const z_negative = random.next_int_bounded(6);
        point.x += @as(i32, @intCast(x_positive)) - @as(i32, @intCast(x_negative));
        point.y += @as(i32, @intCast(y_positive)) - @as(i32, @intCast(y_negative));
        point.z += @as(i32, @intCast(z_positive)) - @as(i32, @intCast(z_negative));
        place_mushroom(field, elevation, material, point);
    }
}

fn mushroom_pass(random: *random_state, field: terrain.block_field, elevation: *const terrain.elevation_cache) void {
    const attempts = @as(u64, field.dimensions.width) * field.dimensions.depth * field.dimensions.height / 2000;
    for (0..@as(usize, @intCast(attempts))) |_| {
        const material = if (random.next_int_bounded(2) == 0) first_mushroom_id else second_mushroom_id;
        const origin: subterranean_walk_point = .{
            .x = @intCast(random.next_int_bounded(field.dimensions.width)),
            .y = @intCast(random.next_int_bounded(field.dimensions.height)),
            .z = @intCast(random.next_int_bounded(field.dimensions.depth)),
        };
        for (0..20) |_| mushroom_walk(random, field, elevation, material, origin);
    }
}

fn horizontal_distance(left: u32, right: u32) u32 {
    return if (left <= right) right - left else left - right;
}

fn tree_clearance_radius(base: terrain.block_position, height: u32, y: u32) u32 {
    assert(height >= 4 and y >= base.y);
    if (y == base.y) return 0;
    if (y < base.y + height - 1) return 1;
    return 2;
}

fn tree_eligible(field: terrain.block_field, base: terrain.block_position, height: u32) bool {
    const dimensions = field.dimensions;
    assert(height >= 4 and height <= 6);
    if (base.x < 2 or base.x + 2 >= dimensions.width or
        base.z < 2 or base.z + 2 >= dimensions.depth or
        base.y + height + 1 >= dimensions.height or base.y == 0)
        return false;
    if (field.at(base.x, base.y - 1, base.z) != terrain.grass_id) return false;

    var y = base.y;
    while (y <= base.y + height + 1) : (y += 1) {
        const radius = tree_clearance_radius(base, height, y);
        var x = base.x - radius;
        while (x <= base.x + radius) : (x += 1) {
            var z = base.z - radius;
            while (z <= base.z + radius) : (z += 1) {
                assert(x < dimensions.width and y < dimensions.height and z < dimensions.depth);
                if (field.at(x, y, z) != terrain.air_id) return false;
            }
        }
    }
    return true;
}

fn lattice_position_from_block(position: terrain.block_position) lattice_position {
    return .{
        .x = @intCast(position.x),
        .y = @intCast(position.y),
        .z = @intCast(position.z),
    };
}

fn lattice_inside(dimensions: world_dimensions, position: lattice_position) bool {
    const width: i32 = @intCast(dimensions.width);
    const height: i32 = @intCast(dimensions.height);
    const depth: i32 = @intCast(dimensions.depth);
    return position.x >= 0 and position.x < width and
        position.y >= 0 and position.y < height and
        position.z >= 0 and position.z < depth;
}

fn lattice_block_at(field: terrain.block_field, position: lattice_position) u8 {
    if (!lattice_inside(field.dimensions, position)) return terrain.air_id;
    return field.at(@intCast(position.x), @intCast(position.y), @intCast(position.z));
}

fn axis_neighbor_order(position: lattice_position) [6]lattice_position {
    return .{
        .{ .x = position.x - 1, .y = position.y, .z = position.z },
        .{ .x = position.x + 1, .y = position.y, .z = position.z },
        .{ .x = position.x, .y = position.y - 1, .z = position.z },
        .{ .x = position.x, .y = position.y + 1, .z = position.z },
        .{ .x = position.x, .y = position.y, .z = position.z - 1 },
        .{ .x = position.x, .y = position.y, .z = position.z + 1 },
    };
}

fn falling_material(material: u8) bool {
    return material == terrain.sand_id or material == terrain.gravel_id;
}

fn still_fluid_material(material: u8) bool {
    return material == terrain.still_water_id or material == terrain.still_lava_id;
}

fn fluid_material(material: u8) bool {
    return material == terrain.flowing_water_id or
        material == terrain.still_water_id or
        material == terrain.flowing_lava_id or
        material == terrain.still_lava_id;
}

fn flowing_fluid_form(material: u8) u8 {
    assert(still_fluid_material(material));
    return if (material == terrain.still_water_id)
        terrain.flowing_water_id
    else
        terrain.flowing_lava_id;
}

fn opposite_fluid_materials(self_material: u8, changed_material: u8) bool {
    const self_water = self_material == terrain.flowing_water_id or self_material == terrain.still_water_id;
    const self_lava = self_material == terrain.flowing_lava_id or self_material == terrain.still_lava_id;
    const changed_water = changed_material == terrain.flowing_water_id or changed_material == terrain.still_water_id;
    const changed_lava = changed_material == terrain.flowing_lava_id or changed_material == terrain.still_lava_id;
    return (self_water and changed_lava) or (self_lava and changed_water);
}

fn fluid_exposure_neighbors(position: lattice_position) [5]lattice_position {
    return .{
        .{ .x = position.x - 1, .y = position.y, .z = position.z },
        .{ .x = position.x + 1, .y = position.y, .z = position.z },
        .{ .x = position.x, .y = position.y, .z = position.z - 1 },
        .{ .x = position.x, .y = position.y, .z = position.z + 1 },
        .{ .x = position.x, .y = position.y - 1, .z = position.z },
    };
}

fn still_fluid_exposed(field: terrain.block_field, position: terrain.block_position) bool {
    assert(field.inside(position));

    const neighbors = fluid_exposure_neighbors(lattice_position_from_block(position));
    for (neighbors) |neighbor| {
        if (lattice_block_at(field, neighbor) == terrain.air_id) return true;
    }
    return false;
}

fn fall_passable(material: u8) bool {
    return material == terrain.air_id or
        material == terrain.flowing_water_id or
        material == terrain.still_water_id or
        material == terrain.flowing_lava_id or
        material == terrain.still_lava_id;
}

fn falling_destination(field: terrain.block_field, source: terrain.block_position) u32 {
    assert(field.inside(source));

    var destination_y = source.y;
    while (destination_y > 0 and
        fall_passable(field.at(source.x, destination_y - 1, source.z)))
    {
        destination_y -= 1;
    }

    return destination_y;
}

const falling_move_result = union(enum) {
    stationary,
    moved: terrain.block_position,
};

fn moved_falling_field(field: terrain.block_field, source: terrain.block_position) falling_move_result {
    const destination: terrain.block_position = .{
        .x = source.x,
        .y = falling_destination(field, source),
        .z = source.z,
    };
    if (destination.y == source.y) return .stationary;

    const material = field.at(source.x, source.y, source.z);
    field.set(source.x, source.y, source.z, terrain.air_id);
    field.set(destination.x, destination.y, destination.z, material);
    return .{ .moved = destination };
}

fn deliver_neighbor_notifications(field: terrain.block_field, changed_material: u8, positions: []const lattice_position) void {
    assert(changed_material <= 49);
    for (positions) |position| {
        if (!lattice_inside(field.dimensions, position)) continue;

        const source: terrain.block_position = .{ .x = @intCast(position.x), .y = @intCast(position.y), .z = @intCast(position.z) };
        const source_material = field.at(source.x, source.y, source.z);
        if (falling_material(source_material)) {
            assert(!fluid_material(source_material));
            falling_neighbor_reaction(field, source);
        } else if (fluid_material(source_material)) {
            fluid_neighbor_reaction(field, source, changed_material);
        }
    }
}

fn falling_neighbor_reaction(field: terrain.block_field, source: terrain.block_position) void {
    assert(field.inside(source));
    assert(falling_material(field.at(source.x, source.y, source.z)));

    const source_material = field.at(source.x, source.y, source.z);
    switch (moved_falling_field(field, source)) {
        .stationary => {},
        .moved => |destination| {
            const source_neighbors = axis_neighbor_order(lattice_position_from_block(source));
            const destination_neighbors = axis_neighbor_order(lattice_position_from_block(destination));
            deliver_neighbor_notifications(field, terrain.air_id, source_neighbors[0..]);
            deliver_neighbor_notifications(field, source_material, destination_neighbors[0..]);
        },
    }
}

fn fluid_neighbor_reaction(field: terrain.block_field, source: terrain.block_position, changed_material: u8) void {
    assert(field.inside(source));

    const source_material = field.at(source.x, source.y, source.z);
    assert(fluid_material(source_material));
    if (opposite_fluid_materials(source_material, changed_material)) {
        field.set(source.x, source.y, source.z, terrain.stone_id);
        const notifications = axis_neighbor_order(lattice_position_from_block(source));
        deliver_neighbor_notifications(field, terrain.stone_id, notifications[0..]);
        return;
    }

    if (still_fluid_material(source_material) and still_fluid_exposed(field, source)) {
        const flowing_material = flowing_fluid_form(source_material);
        field.set(source.x, source.y, source.z, flowing_material);
    }
}

fn notifying_block_placement(field: terrain.block_field, position: terrain.block_position, material: u8) void {
    assert(field.inside(position));
    if (field.at(position.x, position.y, position.z) == material) return;

    field.set(position.x, position.y, position.z, material);
    const notifications = axis_neighbor_order(lattice_position_from_block(position));
    deliver_neighbor_notifications(field, material, notifications[0..]);
}

fn prepare_tree_base(field: terrain.block_field, base: terrain.block_position) void {
    assert(field.inside(base));
    assert(base.y > 0);
    const below: terrain.block_position = .{ .x = base.x, .y = base.y - 1, .z = base.z };
    assert(field.inside(below));
    notifying_block_placement(field, below, terrain.dirt_id);
}

fn place_canopy(random: *random_state, field: terrain.block_field, base: terrain.block_position, height: u32) void {
    var corner_draws: u32 = 0;
    var y = base.y + height - 3;
    while (y <= base.y + height) : (y += 1) {
        const layer = y + 3 - base.y - height;
        assert(layer < 4);
        const radius: u32 = if (layer < 2) 2 else 1;
        var x = base.x - radius;
        while (x <= base.x + radius) : (x += 1) {
            var z = base.z - radius;
            while (z <= base.z + radius) : (z += 1) {
                const corner = horizontal_distance(base.x, x) == radius and
                    horizontal_distance(base.z, z) == radius;
                if (!corner) {
                    notifying_block_placement(field, .{ .x = x, .y = y, .z = z }, foliage_id);
                } else {
                    corner_draws += 1;
                    const choice = random.next_int_bounded(2);
                    if (choice != 0 and layer != 3) {
                        notifying_block_placement(field, .{ .x = x, .y = y, .z = z }, foliage_id);
                    }
                }
            }
        }
    }
    assert(corner_draws == 16);
}

fn place_trunk(field: terrain.block_field, base: terrain.block_position, height: u32) void {
    var y = base.y;
    while (y < base.y + height) : (y += 1) {
        notifying_block_placement(field, .{ .x = base.x, .y = y, .z = base.z }, trunk_id);
    }
}

fn grow_tree(random: *random_state, field: terrain.block_field, base: terrain.block_position) bool {
    const height = random.next_int_bounded(3) + 4;
    assert(height >= 4 and height <= 6);
    if (!tree_eligible(field, base, height)) return false;

    prepare_tree_base(field, base);
    place_canopy(random, field, base, height);
    place_trunk(field, base, height);
    return true;
}

fn tree_walk(generator_random: *random_state, level_random: *random_state, field: terrain.block_field, elevation: *const terrain.elevation_cache, origin: horizontal_walk_point) void {
    var point = origin;
    for (0..20) |_| {
        const x_positive = generator_random.next_int_bounded(6);
        const x_negative = generator_random.next_int_bounded(6);
        const z_positive = generator_random.next_int_bounded(6);
        const z_negative = generator_random.next_int_bounded(6);
        point.x += @as(i32, @intCast(x_positive)) - @as(i32, @intCast(x_negative));
        point.z += @as(i32, @intCast(z_positive)) - @as(i32, @intCast(z_negative));
        if (!horizontal_inside(field.dimensions, point)) continue;
        if (generator_random.next_int_bounded(4) != 0) continue;

        const x: u32 = @intCast(point.x);
        const z: u32 = @intCast(point.z);
        const base: terrain.block_position = .{
            .x = x,
            .y = elevation.surface_height(field.dimensions, x, z) + 1,
            .z = z,
        };
        _ = grow_tree(level_random, field, base);
    }
}

fn tree_pass(generator_random: *random_state, level_random: *random_state, field: terrain.block_field, elevation: *const terrain.elevation_cache) void {
    const clusters = @as(u64, field.dimensions.width) * field.dimensions.depth / 4000;
    for (0..@as(usize, @intCast(clusters))) |_| {
        const origin: horizontal_walk_point = .{
            .x = @intCast(generator_random.next_int_bounded(field.dimensions.width)),
            .z = @intCast(generator_random.next_int_bounded(field.dimensions.depth)),
        };
        for (0..20) |_| tree_walk(generator_random, level_random, field, elevation, origin);
    }
}

pub fn generate(self: *level, scratch: std.mem.Allocator, seed: i64, dimensions: world_dimensions) std.mem.Allocator.Error!void {
    assert(dimensions.validate());
    assert(self.blocks.len == dimensions.volume());
    @memset(self.blocks, terrain.air_id);

    const field = terrain.block_field.init(dimensions, self.blocks);
    var generator_random = random_state.init(seed);
    const elevation = terrain.elevation_noise.init(&generator_random);
    var heights = try terrain.elevation_cache.init(scratch, &elevation, dimensions);
    defer heights.deinit(scratch);

    terrain.soil(field, &heights);

    carve.cave_pass(&generator_random, field);
    ore.all_resource_passes(&generator_random, field);
    try terrain.boundary_water_pass(scratch, field);
    try terrain.inland_water_pass(scratch, &generator_random, field);
    try terrain.lava_pass(scratch, &generator_random, field);

    const surface_noise = terrain.surface_noise.init(&generator_random);
    terrain.surface(field, &heights, &surface_noise);
    flower_pass(&generator_random, field, &heights);
    mushroom_pass(&generator_random, field, &heights);

    var level_random = random_state.init(seed);
    _ = level_random.next_int();
    tree_pass(&generator_random, &level_random, field, &heights);
    for (self.blocks) |material| assert(material <= 49);
}

fn test_field(dimensions: world_dimensions, material: u8) !terrain.block_field {
    const blocks = try std.testing.allocator.alloc(u8, dimensions.volume());
    @memset(blocks, material);
    return .init(dimensions, blocks);
}

test "flower and mushroom pass attempt counts consume specified draws" {
    const dimensions: world_dimensions = .{ .width = 16, .height = 16, .depth = 16 };
    const field = try test_field(dimensions, terrain.air_id);
    defer std.testing.allocator.free(field.blocks);

    var elevation_random = random_state.init(4);
    const elevation = terrain.elevation_noise.init(&elevation_random);
    var heights = try terrain.elevation_cache.init(std.testing.allocator, &elevation, dimensions);
    defer heights.deinit(std.testing.allocator);

    var actual = random_state.init(88);
    mushroom_pass(&actual, field, &heights);

    var expected = random_state.init(88);
    const attempts = dimensions.volume() / 2000;
    for (0..attempts) |_| {
        _ = expected.next_int_bounded(2);
        _ = expected.next_int_bounded(dimensions.width);
        _ = expected.next_int_bounded(dimensions.height);
        _ = expected.next_int_bounded(dimensions.depth);
        for (0..20 * 5) |_| {
            _ = expected.next_int_bounded(6);
            _ = expected.next_int_bounded(6);
            _ = expected.next_int_bounded(2);
            _ = expected.next_int_bounded(2);
            _ = expected.next_int_bounded(6);
            _ = expected.next_int_bounded(6);
        }
    }
    try std.testing.expectEqual(expected.state, actual.state);
}

test "flower clusters consume ten five-step walks" {
    const dimensions: world_dimensions = .{ .width = 64, .height = 16, .depth = 64 };
    const field = try test_field(dimensions, terrain.air_id);
    defer std.testing.allocator.free(field.blocks);

    var elevation_random = random_state.init(17);
    const elevation = terrain.elevation_noise.init(&elevation_random);
    var heights = try terrain.elevation_cache.init(std.testing.allocator, &elevation, dimensions);
    defer heights.deinit(std.testing.allocator);

    var actual = random_state.init(-808);
    flower_pass(&actual, field, &heights);

    var expected = random_state.init(-808);
    const attempts = @as(u64, dimensions.width) * dimensions.depth / 3000;
    for (0..attempts) |_| {
        _ = expected.next_int_bounded(2);
        _ = expected.next_int_bounded(dimensions.width);
        _ = expected.next_int_bounded(dimensions.depth);
        for (0..10 * 5) |_| {
            _ = expected.next_int_bounded(6);
            _ = expected.next_int_bounded(6);
            _ = expected.next_int_bounded(6);
            _ = expected.next_int_bounded(6);
        }
    }
    try std.testing.expectEqual(expected.state, actual.state);
}

test "tree base placement delivers falling notifications recursively" {
    const dimensions: world_dimensions = .{ .width = 16, .height = 16, .depth = 16 };
    const field = try test_field(dimensions, terrain.stone_id);
    defer std.testing.allocator.free(field.blocks);

    const base: terrain.block_position = .{ .x = 8, .y = 8, .z = 8 };

    field.set(base.x, base.y - 1, base.z, terrain.grass_id);
    field.set(9, 7, 8, terrain.sand_id);
    field.set(9, 6, 8, terrain.air_id);
    field.set(10, 7, 8, terrain.gravel_id);
    field.set(10, 6, 8, terrain.still_water_id);

    prepare_tree_base(field, base);

    try std.testing.expectEqual(terrain.dirt_id, field.at(base.x, base.y - 1, base.z));
    try std.testing.expectEqual(terrain.air_id, field.at(9, 7, 8));
    try std.testing.expectEqual(terrain.sand_id, field.at(9, 6, 8));
    try std.testing.expectEqual(terrain.air_id, field.at(10, 7, 8));
    try std.testing.expectEqual(terrain.gravel_id, field.at(10, 6, 8));
}

test "placement into air notifies axis neighbors" {
    const dimensions: world_dimensions = .{ .width = 16, .height = 16, .depth = 16 };
    const field = try test_field(dimensions, terrain.stone_id);
    defer std.testing.allocator.free(field.blocks);

    const position: terrain.block_position = .{ .x = 8, .y = 7, .z = 8 };

    field.set(position.x, position.y, position.z, terrain.air_id);
    field.set(9, 7, 8, terrain.sand_id);
    field.set(9, 6, 8, terrain.air_id);

    notifying_block_placement(field, position, terrain.dirt_id);

    try std.testing.expectEqual(terrain.dirt_id, field.at(position.x, position.y, position.z));
    try std.testing.expectEqual(terrain.air_id, field.at(9, 7, 8));
    try std.testing.expectEqual(terrain.sand_id, field.at(9, 6, 8));
}

test "notifying placement converts exposed still fluid to flowing" {
    const dimensions: world_dimensions = .{ .width = 16, .height = 16, .depth = 16 };
    const field = try test_field(dimensions, terrain.stone_id);
    defer std.testing.allocator.free(field.blocks);

    const position: terrain.block_position = .{ .x = 8, .y = 8, .z = 8 };

    field.set(position.x, position.y, position.z, terrain.air_id);
    field.set(9, 8, 8, terrain.still_water_id);
    field.set(10, 8, 8, terrain.air_id);

    notifying_block_placement(field, position, terrain.dirt_id);

    try std.testing.expectEqual(terrain.dirt_id, field.at(position.x, position.y, position.z));
    try std.testing.expectEqual(terrain.flowing_water_id, field.at(9, 8, 8));
    try std.testing.expectEqual(terrain.air_id, field.at(10, 8, 8));
}

test "notifying opposite fluid solidifies and notifies neighbors" {
    const dimensions: world_dimensions = .{ .width = 16, .height = 16, .depth = 16 };
    const field = try test_field(dimensions, terrain.stone_id);
    defer std.testing.allocator.free(field.blocks);

    const position: terrain.block_position = .{ .x = 8, .y = 8, .z = 8 };

    field.set(position.x, position.y, position.z, terrain.air_id);
    field.set(9, 8, 8, terrain.still_lava_id);
    field.set(10, 8, 8, terrain.sand_id);
    field.set(10, 7, 8, terrain.air_id);

    notifying_block_placement(field, position, terrain.still_water_id);

    try std.testing.expectEqual(terrain.still_water_id, field.at(position.x, position.y, position.z));
    try std.testing.expectEqual(terrain.stone_id, field.at(9, 8, 8));
    try std.testing.expectEqual(terrain.air_id, field.at(10, 8, 8));
    try std.testing.expectEqual(terrain.sand_id, field.at(10, 7, 8));
}

test "boundary still fluid is exposed through lattice block lookup" {
    const dimensions: world_dimensions = .{ .width = 16, .height = 16, .depth = 16 };
    const field = try test_field(dimensions, terrain.stone_id);
    defer std.testing.allocator.free(field.blocks);

    const position: terrain.block_position = .{ .x = 1, .y = 8, .z = 8 };

    field.set(position.x, position.y, position.z, terrain.air_id);
    field.set(0, 8, 8, terrain.still_lava_id);

    notifying_block_placement(field, position, terrain.dirt_id);

    try std.testing.expectEqual(terrain.flowing_lava_id, field.at(0, 8, 8));
}

test "falling movement notifies source fluid neighbors with air" {
    const dimensions: world_dimensions = .{ .width = 16, .height = 16, .depth = 16 };
    const field = try test_field(dimensions, terrain.stone_id);
    defer std.testing.allocator.free(field.blocks);

    const source: terrain.block_position = .{ .x = 8, .y = 8, .z = 8 };

    field.set(source.x, source.y, source.z, terrain.sand_id);
    field.set(source.x, source.y - 1, source.z, terrain.air_id);
    field.set(9, 8, 8, terrain.still_water_id);

    falling_neighbor_reaction(field, source);

    try std.testing.expectEqual(terrain.air_id, field.at(source.x, source.y, source.z));
    try std.testing.expectEqual(terrain.sand_id, field.at(source.x, source.y - 1, source.z));
    try std.testing.expectEqual(terrain.flowing_water_id, field.at(9, 8, 8));
}

test "canopy placement into air notifies axis neighbors" {
    const dimensions: world_dimensions = .{ .width = 16, .height = 16, .depth = 16 };
    const field = try test_field(dimensions, terrain.stone_id);
    defer std.testing.allocator.free(field.blocks);

    const base: terrain.block_position = .{ .x = 8, .y = 8, .z = 8 };

    field.set(6, 9, 8, terrain.air_id);
    field.set(5, 9, 8, terrain.sand_id);
    field.set(5, 8, 8, terrain.air_id);

    var placement_random = random_state.init(0);
    place_canopy(&placement_random, field, base, 4);

    try std.testing.expectEqual(foliage_id, field.at(6, 9, 8));
    try std.testing.expectEqual(terrain.air_id, field.at(5, 9, 8));
    try std.testing.expectEqual(terrain.sand_id, field.at(5, 8, 8));
}

test "trunk placement into air notifies axis neighbors" {
    const dimensions: world_dimensions = .{ .width = 16, .height = 16, .depth = 16 };
    const field = try test_field(dimensions, terrain.stone_id);
    defer std.testing.allocator.free(field.blocks);

    const base: terrain.block_position = .{ .x = 8, .y = 8, .z = 8 };

    field.set(base.x, base.y, base.z, terrain.air_id);
    field.set(9, 8, 8, terrain.sand_id);
    field.set(9, 7, 8, terrain.air_id);

    place_trunk(field, base, 4);

    try std.testing.expectEqual(trunk_id, field.at(base.x, base.y, base.z));
    try std.testing.expectEqual(terrain.air_id, field.at(9, 8, 8));
    try std.testing.expectEqual(terrain.sand_id, field.at(9, 7, 8));
}

test "unchanged notifying placement does not deliver falling notifications" {
    const dimensions: world_dimensions = .{ .width = 16, .height = 16, .depth = 16 };
    const field = try test_field(dimensions, terrain.stone_id);
    defer std.testing.allocator.free(field.blocks);

    const position: terrain.block_position = .{ .x = 8, .y = 7, .z = 8 };

    field.set(position.x, position.y, position.z, terrain.dirt_id);
    field.set(9, 7, 8, terrain.sand_id);
    field.set(9, 6, 8, terrain.air_id);

    notifying_block_placement(field, position, terrain.dirt_id);

    try std.testing.expectEqual(terrain.dirt_id, field.at(position.x, position.y, position.z));
    try std.testing.expectEqual(terrain.sand_id, field.at(9, 7, 8));
    try std.testing.expectEqual(terrain.air_id, field.at(9, 6, 8));
}

test "tree success consumes height plus sixteen corner draws" {
    const dimensions: world_dimensions = .{ .width = 16, .height = 32, .depth = 16 };
    const field = try test_field(dimensions, terrain.air_id);
    defer std.testing.allocator.free(field.blocks);

    const base: terrain.block_position = .{ .x = 8, .y = 8, .z = 8 };
    field.set(base.x, base.y - 1, base.z, terrain.grass_id);
    var actual = random_state.init(777);
    try std.testing.expect(grow_tree(&actual, field, base));

    var expected = random_state.init(777);
    _ = expected.next_int_bounded(3);
    for (0..16) |_| _ = expected.next_int_bounded(2);
    try std.testing.expectEqual(expected.state, actual.state);
    try std.testing.expectEqual(terrain.dirt_id, field.at(base.x, base.y - 1, base.z));
    try std.testing.expectEqual(trunk_id, field.at(base.x, base.y, base.z));
}
