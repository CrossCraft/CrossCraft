const builtin = @import("builtin");

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

pub const Location = packed struct(u32) {
    x: u8,
    z: u8,
    y: u8,
    _reserved: u8 = 0,

    pub fn to_index(self: Location) u32 {
        return block_index(self.x, self.y, self.z);
    }
};

test "block_index" {
    const std = @import("std");
    try std.testing.expectEqual(@as(u32, 0), block_index(0, 0, 0));
    try std.testing.expectEqual(@as(u32, 4095), block_index(15, 15, 15));
    try std.testing.expectEqual(@as(u32, 4096), block_index(16, 0, 0));
    try std.testing.expectEqual(@as(u32, 4194303), block_index(255, 63, 255));

    const base = block_index(0, 5, 7);
    try std.testing.expectEqual(base + 1, block_index(1, 5, 7));
    try std.testing.expectEqual(base + 15, block_index(15, 5, 7));
}
