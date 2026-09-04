const std = @import("std");
const assert = std.debug.assert;

pub const BLOCK_CAPACITY: usize = 256;
pub const INVENTORY_SLOTS: u8 = 45;
pub const INVENTORY_FILLED: u8 = 42;
const classic_block_count = 50;

pub const Face = enum(u3) {
    x_neg = 0,
    x_pos = 1,
    y_neg = 2,
    y_pos = 3,
    z_neg = 4,
    z_pos = 5,
};

pub const Tile = packed struct(u16) {
    col: u8,
    row: u8,

    pub fn init(col: u8, row: u8) Tile {
        return .{ .col = col, .row = row };
    }
};

pub const FaceTiles = struct {
    top: Tile,
    bottom: Tile,
    side: Tile,

    pub fn all(col: u8, row: u8) FaceTiles {
        const tile: Tile = .init(col, row);
        return .{ .top = tile, .bottom = tile, .side = tile };
    }

    pub fn top_side_bottom(
        top_col: u8,
        top_row: u8,
        side_col: u8,
        side_row: u8,
        bottom_col: u8,
        bottom_row: u8,
    ) FaceTiles {
        return .{
            .top = .init(top_col, top_row),
            .bottom = .init(bottom_col, bottom_row),
            .side = .init(side_col, side_row),
        };
    }

    pub fn for_face(self: FaceTiles, face: Face) Tile {
        return switch (face) {
            .y_pos => self.top,
            .y_neg => self.bottom,
            .x_neg, .x_pos, .z_neg, .z_pos => self.side,
        };
    }

    fn valid(self: FaceTiles) bool {
        return tile_valid(self.top) and tile_valid(self.bottom) and tile_valid(self.side);
    }
};

pub const Material = enum(u3) { stone, grass, gravel, wood, glass, cloth, sand };
pub const FluidKind = enum(u2) { none, water, lava };

pub const SubvoxelBounds = struct {
    min_x: u5,
    min_y: u5,
    min_z: u5,
    max_x: u5,
    max_y: u5,
    max_z: u5,

    pub const full: SubvoxelBounds = .{ .min_x = 0, .min_y = 0, .min_z = 0, .max_x = 16, .max_y = 16, .max_z = 16 };
    pub const slab: SubvoxelBounds = .{ .min_x = 0, .min_y = 0, .min_z = 0, .max_x = 16, .max_y = 8, .max_z = 16 };
    pub const dandelion: SubvoxelBounds = .{ .min_x = 6, .min_y = 0, .min_z = 6, .max_x = 10, .max_y = 8, .max_z = 10 };
    pub const rose: SubvoxelBounds = .{ .min_x = 6, .min_y = 0, .min_z = 6, .max_x = 10, .max_y = 12, .max_z = 10 };
    pub const mushroom: SubvoxelBounds = .{ .min_x = 5, .min_y = 0, .min_z = 5, .max_x = 11, .max_y = 6, .max_z = 11 };
    pub const sapling: SubvoxelBounds = .{ .min_x = 2, .min_y = 0, .min_z = 2, .max_x = 14, .max_y = 16, .max_z = 14 };

    pub fn is_full(self: SubvoxelBounds) bool {
        return self.min_x == 0 and self.min_y == 0 and self.min_z == 0 and
            self.max_x == 16 and self.max_y == 16 and self.max_z == 16;
    }

    fn valid(self: SubvoxelBounds) bool {
        return self.min_x <= self.max_x and self.max_x <= 16 and
            self.min_y <= self.max_y and self.max_y <= 16 and
            self.min_z <= self.max_z and self.max_z <= 16;
    }
};

/// Hot mesher properties. A complete 256-entry table occupies 256 bytes.
pub const MeshProps = packed struct(u8) {
    @"opaque": bool = false,
    visible: bool = false,
    fluid: bool = false,
    cross: bool = false,
    leaf: bool = false,
    slab: bool = false,
    glass: bool = false,
    emits_light: bool = false,
};

pub const SimProps = packed struct(u8) {
    solid: bool = false,
    selectable: bool = false,
    breakable: bool = false,
    step_sound: bool = false,
    in_inventory: bool = false,
    light_passes: bool = false,
    ticks: bool = false,
    fast_tick: bool = false,
};

/// Complete registration input for one block. Registry compiles this friendly
/// aggregate into its hot-path structure-of-arrays tables. Strings are borrowed
/// and must outlive the Registry.
const Definition = struct {
    mesh: MeshProps = .{},
    simulation: SimProps = .{},
    face_tiles: FaceTiles = .all(0, 0),
    material: Material = .grass,
    fluid_kind: FluidKind = .none,
    collision_height_16: u8 = 0,
    bounds: SubvoxelBounds = .full,
    display_name: []const u8 = "",
    inventory_slot: ?u8 = null,

    fn valid(self: Definition) bool {
        const inventory_slot_valid = if (self.inventory_slot) |slot|
            slot < INVENTORY_SLOTS
        else
            true;
        return self.collision_height_16 <= 16 and self.bounds.valid() and
            self.face_tiles.valid() and inventory_slot_valid and
            self.simulation.in_inventory == (self.inventory_slot != null);
    }
};

/// Named tags cover Classic blocks; unnamed values support wire IDs and local
/// sentinels without inflating the one-byte representation.
pub const Block = enum(u8) {
    air = 0,
    stone = 1,
    grass = 2,
    dirt = 3,
    cobblestone = 4,
    planks = 5,
    sapling = 6,
    bedrock = 7,
    flowing_water = 8,
    still_water = 9,
    flowing_lava = 10,
    still_lava = 11,
    sand = 12,
    gravel = 13,
    gold_ore = 14,
    iron_ore = 15,
    coal_ore = 16,
    log = 17,
    leaves = 18,
    sponge = 19,
    glass = 20,
    red_wool = 21,
    orange_wool = 22,
    yellow_wool = 23,
    chartreuse_wool = 24,
    green_wool = 25,
    spring_green_wool = 26,
    cyan_wool = 27,
    capri_wool = 28,
    ultramarine_wool = 29,
    purple_wool = 30,
    violet_wool = 31,
    magenta_wool = 32,
    rose_wool = 33,
    dark_gray_wool = 34,
    light_gray_wool = 35,
    white_wool = 36,
    flower_1 = 37,
    flower_2 = 38,
    mushroom_1 = 39,
    mushroom_2 = 40,
    gold = 41,
    iron = 42,
    double_slab = 43,
    slab = 44,
    brick = 45,
    tnt = 46,
    bookshelf = 47,
    mossy_rocks = 48,
    obsidian = 49,
    _,

    pub inline fn is_air(self: Block) bool {
        return self == .air;
    }

    pub inline fn is_place_replaceable(self: Block) bool {
        return self.is_air() or self.is_fluid();
    }

    pub inline fn mesh_props(self: Block) MeshProps {
        return global.mesh_props[index(self)];
    }

    pub inline fn sim_props(self: Block) SimProps {
        return global.sim_props[index(self)];
    }

    pub inline fn fluid_kind(self: Block) FluidKind {
        return global.fluid_kind[index(self)];
    }

    pub inline fn material(self: Block) Material {
        return global.material[index(self)];
    }

    pub inline fn bounds(self: Block) SubvoxelBounds {
        return global.bounds[index(self)];
    }

    pub inline fn face_tile(self: Block, face: Face) Tile {
        return global.face_tiles[index(self)].for_face(face);
    }

    pub inline fn display_name(self: Block) []const u8 {
        return global.display_name[index(self)];
    }

    pub inline fn collision_height(self: Block) f32 {
        const height = global.collision_height_16[index(self)];
        return @as(f32, @floatFromInt(height)) * (1.0 / 16.0);
    }

    pub inline fn is_opaque(self: Block) bool {
        return self.mesh_props().@"opaque";
    }

    pub inline fn is_fluid(self: Block) bool {
        return self.mesh_props().fluid;
    }

    pub inline fn is_slab(self: Block) bool {
        return self.mesh_props().slab;
    }

    pub inline fn emits_light(self: Block) bool {
        return self.mesh_props().emits_light;
    }

    pub inline fn is_solid(self: Block) bool {
        return self.sim_props().solid;
    }

    pub inline fn is_selectable(self: Block) bool {
        return self.sim_props().selectable;
    }

    pub inline fn is_breakable(self: Block) bool {
        return self.sim_props().breakable;
    }

    pub inline fn has_step_sound(self: Block) bool {
        return self.sim_props().step_sound;
    }

    pub inline fn in_inventory(self: Block) bool {
        return self.sim_props().in_inventory;
    }

    pub inline fn light_passes(self: Block) bool {
        return self.sim_props().light_passes;
    }

    pub inline fn ticks(self: Block) bool {
        return self.sim_props().ticks;
    }

    pub inline fn fast_tick(self: Block) bool {
        return self.sim_props().fast_tick;
    }

    pub inline fn is_water(self: Block) bool {
        return self.fluid_kind() == .water;
    }

    pub inline fn is_lava(self: Block) bool {
        return self.fluid_kind() == .lava;
    }
};

comptime {
    assert(@sizeOf(Block) == 1);
}

/// Compile-time structure-of-arrays lookup table for gameplay hot paths.
const Registry = struct {
    mesh_props: [BLOCK_CAPACITY]MeshProps,
    sim_props: [BLOCK_CAPACITY]SimProps,
    face_tiles: [BLOCK_CAPACITY]FaceTiles,
    material: [BLOCK_CAPACITY]Material,
    fluid_kind: [BLOCK_CAPACITY]FluidKind,
    collision_height_16: [BLOCK_CAPACITY]u8,
    bounds: [BLOCK_CAPACITY]SubvoxelBounds,
    display_name: [BLOCK_CAPACITY][]const u8,
    inventory_order: [INVENTORY_SLOTS]Block,
    inventory_used: [INVENTORY_SLOTS]bool,

    fn empty() Registry {
        return .{
            .mesh_props = @splat(MeshProps{}),
            .sim_props = @splat(SimProps{}),
            .face_tiles = @splat(FaceTiles.all(0, 0)),
            .material = @splat(.grass),
            .fluid_kind = @splat(.none),
            .collision_height_16 = @splat(0),
            .bounds = @splat(.full),
            .display_name = @splat(""),
            .inventory_order = @splat(.air),
            .inventory_used = @splat(false),
        };
    }

    fn classic() Registry {
        var self = Registry.empty();
        for (0..classic_block_count) |raw_id| {
            const value: Block = @enumFromInt(raw_id);
            self.register(value, classic_definition(value));
        }
        return self;
    }

    fn register(self: *Registry, value: Block, def: Definition) void {
        const id = index(value);
        assert(def.valid());
        if (def.inventory_slot) |slot| {
            assert(!self.inventory_used[slot]);
        }

        self.mesh_props[id] = def.mesh;
        self.sim_props[id] = def.simulation;
        self.face_tiles[id] = def.face_tiles;
        self.material[id] = def.material;
        self.fluid_kind[id] = def.fluid_kind;
        self.collision_height_16[id] = def.collision_height_16;
        self.bounds[id] = def.bounds;
        self.display_name[id] = def.display_name;

        if (def.inventory_slot) |slot| {
            self.inventory_order[slot] = value;
            self.inventory_used[slot] = true;
        }
    }
};

const global = Registry.classic();

pub inline fn inventory_block(slot: u8) Block {
    assert(slot < INVENTORY_SLOTS);
    return global.inventory_order[slot];
}

fn index(value: Block) usize {
    return @intFromEnum(value);
}

fn tile_valid(tile: Tile) bool {
    return tile.col < 16 and tile.row < 16;
}

fn set_catalog(
    def: *Definition,
    display_name: []const u8,
    face_tiles: FaceTiles,
    material: Material,
    inventory_slot: ?u8,
) void {
    def.display_name = display_name;
    def.face_tiles = face_tiles;
    def.material = material;
    def.inventory_slot = inventory_slot;
    def.simulation.in_inventory = inventory_slot != null;
}

/// Assemble and validate one complete built-in definition before registration.
fn classic_definition(value: Block) Definition {
    var def: Definition = if (value == .air)
        .{}
    else
        .{
            .mesh = .{ .@"opaque" = true, .visible = true },
            .simulation = .{ .solid = true, .selectable = true, .breakable = true, .step_sound = true },
            .collision_height_16 = 16,
        };

    switch (value) {
        .air => def.simulation.light_passes = true,
        .stone => set_catalog(&def, "Stone", .all(1, 0), .stone, 0),
        .grass => set_catalog(&def, "", .top_side_bottom(0, 0, 3, 0, 2, 0), .grass, null),
        .dirt => set_catalog(&def, "Dirt", .all(2, 0), .gravel, 3),
        .cobblestone => set_catalog(&def, "Cobblestone", .all(0, 1), .stone, 1),
        .planks => set_catalog(&def, "Wood", .all(4, 0), .wood, 4),
        .sapling => set_catalog(&def, "Sapling", .all(15, 0), .grass, 10),
        .bedrock => {
            set_catalog(&def, "", .all(1, 1), .stone, null);
            def.simulation.breakable = false;
        },
        .flowing_water, .still_water => {
            set_catalog(&def, "", .all(14, 0), .grass, null);
            def.fluid_kind = .water;
        },
        .flowing_lava, .still_lava => {
            set_catalog(&def, "", .all(14, 1), .grass, null);
            def.fluid_kind = .lava;
        },
        .sand => set_catalog(&def, "Sand", .all(2, 1), .sand, 15),
        .gravel => set_catalog(&def, "Gravel", .all(3, 1), .gravel, 16),
        .gold_ore => set_catalog(&def, "Gold ore", .all(0, 2), .stone, 36),
        .iron_ore => set_catalog(&def, "Iron ore", .all(1, 2), .stone, 35),
        .coal_ore => set_catalog(&def, "Coal ore", .all(2, 2), .stone, 34),
        .log => set_catalog(&def, "Log", .top_side_bottom(5, 1, 4, 1, 5, 1), .wood, 5),
        .leaves => set_catalog(&def, "Leaves", .all(6, 1), .grass, 6),
        .sponge => set_catalog(&def, "Sponge", .all(0, 3), .grass, 17),
        .glass => set_catalog(&def, "Glass", .all(1, 3), .glass, 7),
        .red_wool => set_catalog(&def, "Red Cloth", .all(0, 4), .cloth, 18),
        .orange_wool => set_catalog(&def, "Orange Cloth", .all(1, 4), .cloth, 19),
        .yellow_wool => set_catalog(&def, "Yellow Cloth", .all(2, 4), .cloth, 20),
        .chartreuse_wool => set_catalog(&def, "Chartreuse Cloth", .all(3, 4), .cloth, 21),
        .green_wool => set_catalog(&def, "Green Cloth", .all(4, 4), .cloth, 22),
        .spring_green_wool => set_catalog(&def, "Spring Green Cloth", .all(5, 4), .cloth, 23),
        .cyan_wool => set_catalog(&def, "Cyan Cloth", .all(6, 4), .cloth, 24),
        .capri_wool => set_catalog(&def, "Capri Cloth", .all(7, 4), .cloth, 25),
        .ultramarine_wool => set_catalog(&def, "Ultramarine Cloth", .all(8, 4), .cloth, 26),
        .purple_wool => set_catalog(&def, "Purple Cloth", .all(9, 4), .cloth, 27),
        .violet_wool => set_catalog(&def, "Violet Cloth", .all(10, 4), .cloth, 28),
        .magenta_wool => set_catalog(&def, "Magenta Cloth", .all(11, 4), .cloth, 29),
        .rose_wool => set_catalog(&def, "Rose Cloth", .all(12, 4), .cloth, 30),
        .dark_gray_wool => set_catalog(&def, "Dark Gray Cloth", .all(13, 4), .cloth, 31),
        .light_gray_wool => set_catalog(&def, "Light Gray Cloth", .all(14, 4), .cloth, 32),
        .white_wool => set_catalog(&def, "White Cloth", .all(15, 4), .cloth, 33),
        .flower_1 => set_catalog(&def, "Dandelion", .all(13, 0), .grass, 11),
        .flower_2 => set_catalog(&def, "Rose", .all(12, 0), .grass, 12),
        .mushroom_1 => set_catalog(&def, "Brown mushroom", .all(13, 1), .grass, 13),
        .mushroom_2 => set_catalog(&def, "Red mushroom", .all(12, 1), .grass, 14),
        .gold => set_catalog(&def, "Gold", .top_side_bottom(8, 1, 8, 2, 8, 1), .stone, 38),
        .iron => set_catalog(&def, "Iron", .top_side_bottom(7, 1, 7, 2, 7, 1), .stone, 37),
        .double_slab => set_catalog(&def, "", .top_side_bottom(6, 0, 5, 0, 6, 0), .stone, null),
        .slab => set_catalog(&def, "Slab", .top_side_bottom(6, 0, 5, 0, 6, 0), .stone, 8),
        .brick => set_catalog(&def, "Brick", .all(7, 0), .stone, 2),
        .tnt => set_catalog(&def, "TNT", .top_side_bottom(9, 0, 8, 0, 10, 0), .grass, 40),
        .bookshelf => set_catalog(&def, "Bookshelf", .top_side_bottom(4, 0, 3, 2, 4, 0), .wood, 39),
        .mossy_rocks => set_catalog(&def, "Mossy rocks", .all(4, 2), .stone, 9),
        .obsidian => set_catalog(&def, "Obsidian", .all(5, 2), .stone, 41),
        else => unreachable,
    }

    switch (value) {
        .sapling, .flower_1, .flower_2, .mushroom_1, .mushroom_2 => {
            def.mesh.@"opaque" = false;
            def.mesh.visible = false;
            def.mesh.cross = true;
            def.simulation.solid = false;
            def.simulation.light_passes = true;
            def.simulation.ticks = true;
            def.collision_height_16 = 0;
        },
        else => {},
    }

    switch (value) {
        .flowing_water, .still_water, .flowing_lava, .still_lava => {
            def.mesh.@"opaque" = false;
            def.mesh.fluid = true;
            def.simulation.solid = false;
            def.simulation.selectable = false;
            def.simulation.step_sound = false;
            def.simulation.ticks = true;
            def.simulation.fast_tick = true;
            def.collision_height_16 = 0;
        },
        else => {},
    }

    switch (value) {
        .flowing_lava, .still_lava => def.mesh.emits_light = true,
        .leaves => {
            def.mesh.@"opaque" = false;
            def.mesh.leaf = true;
            def.simulation.light_passes = true;
        },
        .glass => {
            def.mesh.@"opaque" = false;
            def.mesh.glass = true;
            def.simulation.light_passes = true;
        },
        .slab => {
            def.mesh.@"opaque" = false;
            def.mesh.slab = true;
            def.collision_height_16 = 8;
        },
        else => {},
    }

    switch (value) {
        .dirt, .grass => def.simulation.ticks = true,
        .sand, .gravel => {
            def.simulation.ticks = true;
            def.simulation.fast_tick = true;
        },
        else => {},
    }

    def.bounds = switch (value) {
        .slab => .slab,
        .flower_1 => .dandelion,
        .flower_2 => .rose,
        .sapling => .sapling,
        .mushroom_1, .mushroom_2 => .mushroom,
        else => .full,
    };

    return def;
}

test "classic registry preserves block properties" {
    try std.testing.expect(Block.air.is_air());
    try std.testing.expect(!Block.stone.is_air());
    try std.testing.expect(Block.stone.is_opaque());
    try std.testing.expect(!Block.glass.is_opaque());
    try std.testing.expect(Block.glass.mesh_props().glass);
    try std.testing.expect(Block.still_water.is_water());
    try std.testing.expect(Block.flowing_lava.is_lava());
    try std.testing.expect(Block.still_water.is_fluid());
    try std.testing.expect(Block.air.is_place_replaceable());
    try std.testing.expect(Block.still_water.is_place_replaceable());
    try std.testing.expect(!Block.flower_1.is_place_replaceable());
    try std.testing.expectEqual(@as(u5, 8), Block.slab.bounds().max_y);
    try std.testing.expect(Block.stone.bounds().is_full());
    try std.testing.expect(Block.bedrock.is_solid());
    try std.testing.expect(!Block.bedrock.is_breakable());
    try std.testing.expectEqual(@as(f32, 0.5), Block.slab.collision_height());
    try std.testing.expectEqual(@as(f32, 1.0), Block.stone.collision_height());
    try std.testing.expectEqual(@as(f32, 0.0), Block.air.collision_height());
    try std.testing.expectEqual(@as(u8, 1), Block.stone.face_tile(.y_pos).col);
    try std.testing.expectEqual(Block.obsidian, inventory_block(41));
}
