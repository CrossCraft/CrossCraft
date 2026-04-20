const builtin = @import("builtin");

pub const MAX_PLAYERS = if (builtin.os.tag == .psp) 4 else 128;

pub const WorldLength = 256;
pub const WorldHeight = 64;
pub const WorldDepth = 256;

pub const Message = [64]u8;

pub const Water_Level = 32;

pub const ChunkSize = 16;
pub const ChunksX = WorldLength / ChunkSize;
pub const ChunksY = WorldHeight / ChunkSize;
pub const ChunksZ = WorldDepth / ChunkSize;
pub const ChunkVolume = ChunkSize * ChunkSize * ChunkSize;

/// Chunk-aware block index: two-level YZX ordering.
/// Each 16x16x16 chunk is contiguous (4 KiB), enabling single-read streaming.
pub fn block_index(x: u32, y: u32, z: u32) u32 {
    const chunk = (y / ChunkSize * ChunksZ + z / ChunkSize) * ChunksX + x / ChunkSize;
    const local = (y % ChunkSize * ChunkSize + z % ChunkSize) * ChunkSize + x % ChunkSize;
    return chunk * ChunkVolume + local;
}

test "block_index" {
    const std = @import("std");
    // First block
    try std.testing.expectEqual(@as(u32, 0), block_index(0, 0, 0));
    // Last block in first chunk
    try std.testing.expectEqual(@as(u32, 4095), block_index(15, 15, 15));
    // First block in second chunk (next CX)
    try std.testing.expectEqual(@as(u32, 4096), block_index(16, 0, 0));
    // Last valid index
    try std.testing.expectEqual(@as(u32, 4194303), block_index(255, 63, 255));
    // Within a chunk, incrementing x gives consecutive indices
    const base = block_index(0, 5, 7);
    try std.testing.expectEqual(base + 1, block_index(1, 5, 7));
    try std.testing.expectEqual(base + 15, block_index(15, 5, 7));
}

pub const Location = packed struct(u32) {
    x: u8,
    z: u8,
    y: u8,
    _reserved: u8 = 0,

    pub fn to_index(self: Location) u32 {
        return block_index(@as(u32, self.x), @as(u32, self.y), @as(u32, self.z));
    }
};

/// Axis-aligned bounding box within a voxel, expressed on a 16x16x16 subgrid.
/// Each coordinate ranges from 0 to 16 (one block = 16 subvoxels per axis).
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
};

pub fn block_bounds(id: Block) SubvoxelBounds {
    return switch (id) {
        .slab => SubvoxelBounds.slab,
        .flower_1 => SubvoxelBounds.dandelion,
        .flower_2 => SubvoxelBounds.rose,
        .sapling => SubvoxelBounds.sapling,
        .mushroom_1, .mushroom_2 => SubvoxelBounds.mushroom,
        else => SubvoxelBounds.full,
    };
}

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
};
