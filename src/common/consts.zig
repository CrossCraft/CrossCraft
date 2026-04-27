const assert = @import("std").debug.assert;
const builtin = @import("builtin");
const BlockRegistry = @import("BlockRegistry.zig");

pub const MAX_PLAYERS = if (builtin.os.tag == .psp) 4 else 128;

pub const WorldLength = 256;
pub const WorldHeight = 64;
pub const WorldDepth = 256;

pub const Message = [64]u8;

pub const WaterLevel = 32;

pub const ChunkSize = 16;
pub const ChunksX = WorldLength / ChunkSize;
pub const ChunksY = WorldHeight / ChunkSize;
pub const ChunksZ = WorldDepth / ChunkSize;
pub const ChunkVolume = ChunkSize * ChunkSize * ChunkSize;

/// YZX two-level layout keeps each 16x16x16 chunk contiguous for cache-friendly streaming.
pub fn block_index(x: u32, y: u32, z: u32) u32 {
    const log2_chunk_size = 4;
    const chunk_size_mask = 15;
    const log2_chunk_volume = 12;
    const chunk = ((((y >> log2_chunk_size) << log2_chunk_size) + (z >> log2_chunk_size)) << log2_chunk_size) + (x >> log2_chunk_size);
    const local = ((((y & chunk_size_mask) << log2_chunk_size) + (z & chunk_size_mask)) << log2_chunk_size) + (x & chunk_size_mask);
    return (chunk << log2_chunk_volume) + local;
}

test "block_index" {
    const std = @import("std");
    try std.testing.expectEqual(@as(u32, 0), block_index(0, 0, 0));
    try std.testing.expectEqual(@as(u32, 4095), block_index(15, 15, 15));
    try std.testing.expectEqual(@as(u32, 4096), block_index(16, 0, 0));
    try std.testing.expectEqual(@as(u32, 4194303), block_index(255, 63, 255));
    // x is the fastest-varying axis within a chunk
    const base = block_index(0, 5, 7);
    try std.testing.expectEqual(base + 1, block_index(1, 5, 7));
    try std.testing.expectEqual(base + 15, block_index(15, 5, 7));
}

/// One of the six cube-face directions. Shared by block rendering (mesher,
/// face geometry, particles) and the block registry's per-face texture lookup.
pub const Face = enum(u3) {
    x_neg = 0,
    x_pos = 1,
    y_neg = 2,
    y_pos = 3,
    z_neg = 4,
    z_pos = 5,
};

pub const Location = packed struct(u32) {
    x: u8,
    z: u8,
    y: u8,
    _reserved: u8 = 0,

    pub fn to_index(self: Location) u32 {
        return block_index(self.x, self.y, self.z);
    }
};

pub const Block = struct {
    id: Type,

    comptime {
        assert(@sizeOf(Block) == 1);
    }

    pub const Type = enum(u8) {
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
    };

    // --- Identity ---

    pub inline fn is_air(self: Block) bool {
        return self.id == .air;
    }

    // --- Coarse property getters (hot-path single-load) ---

    pub inline fn mesh_props(self: Block) BlockRegistry.MeshProps {
        return BlockRegistry.global.mesh_props[@intFromEnum(self.id)];
    }

    pub inline fn sim_props(self: Block) BlockRegistry.SimProps {
        return BlockRegistry.global.sim_props[@intFromEnum(self.id)];
    }

    pub inline fn fluid_kind(self: Block) BlockRegistry.FluidKind {
        return BlockRegistry.global.fluid_kind[@intFromEnum(self.id)];
    }

    pub inline fn material(self: Block) BlockRegistry.Material {
        return BlockRegistry.global.material[@intFromEnum(self.id)];
    }

    pub inline fn bounds(self: Block) BlockRegistry.SubvoxelBounds {
        return BlockRegistry.global.bounds[@intFromEnum(self.id)];
    }

    pub inline fn face_tile(self: Block, face: Face) BlockRegistry.Tile {
        return BlockRegistry.global.get_face_tile(self, face);
    }

    pub inline fn display_name(self: Block) []const u8 {
        return BlockRegistry.global.display_name[@intFromEnum(self.id)];
    }

    pub inline fn collision_height(self: Block) f32 {
        const h16 = BlockRegistry.global.collision_height_16[@intFromEnum(self.id)];
        return @as(f32, @floatFromInt(h16)) * (1.0 / 16.0);
    }

    // --- Mesh flags ---

    pub inline fn is_opaque(self: Block) bool {
        return self.mesh_props().@"opaque";
    }
    pub inline fn is_visible(self: Block) bool {
        return self.mesh_props().visible;
    }
    pub inline fn is_fluid(self: Block) bool {
        return self.mesh_props().fluid;
    }
    pub inline fn is_cross(self: Block) bool {
        return self.mesh_props().cross;
    }
    pub inline fn is_leaf(self: Block) bool {
        return self.mesh_props().leaf;
    }
    pub inline fn is_slab(self: Block) bool {
        return self.mesh_props().slab;
    }
    pub inline fn is_glass(self: Block) bool {
        return self.mesh_props().glass;
    }
    pub inline fn emits_light(self: Block) bool {
        return self.mesh_props().emits_light;
    }

    // --- Sim flags ---

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

    // --- Fluid kind ---

    pub inline fn is_water(self: Block) bool {
        return self.fluid_kind() == .water;
    }
    pub inline fn is_lava(self: Block) bool {
        return self.fluid_kind() == .lava;
    }
};

test "Block accessors" {
    const std = @import("std");
    BlockRegistry.init();

    try std.testing.expect((Block{ .id = .air }).is_air());
    try std.testing.expect(!(Block{ .id = .stone }).is_air());

    try std.testing.expect((Block{ .id = .stone }).is_opaque());
    try std.testing.expect(!(Block{ .id = .glass }).is_opaque());
    try std.testing.expect((Block{ .id = .glass }).is_glass());

    try std.testing.expect((Block{ .id = .still_water }).is_water());
    try std.testing.expect((Block{ .id = .flowing_lava }).is_lava());
    try std.testing.expect((Block{ .id = .still_water }).is_fluid());
    try std.testing.expect(!(Block{ .id = .air }).is_fluid());

    try std.testing.expectEqual(@as(u5, 8), (Block{ .id = .slab }).bounds().max_y);
    try std.testing.expect((Block{ .id = .stone }).bounds().is_full());

    try std.testing.expect((Block{ .id = .bedrock }).is_solid());
    try std.testing.expect(!(Block{ .id = .bedrock }).is_breakable());

    try std.testing.expectEqual(@as(f32, 0.5), (Block{ .id = .slab }).collision_height());
    try std.testing.expectEqual(@as(f32, 1.0), (Block{ .id = .stone }).collision_height());
    try std.testing.expectEqual(@as(f32, 0.0), (Block{ .id = .air }).collision_height());

    // face_tile: stone uses all(1,0) -- all faces share the same tile.
    const stone_top = (Block{ .id = .stone }).face_tile(.y_pos);
    try std.testing.expectEqual(@as(u8, 1), stone_top.col);
    try std.testing.expectEqual(@as(u8, 0), stone_top.row);
}
