const std = @import("std");

// Design-limit world shape: 512x128x512 blocks = 32x8x32 chunks. Chunk
// coordinates and the dense lookup index are sized for these limits, never
// for the current 256x64x256 world, so a future larger world does not
// require reworking chunk identity or indexing.
pub const MAX_BLOCKS_X: u32 = 512;
pub const MAX_BLOCKS_Y: u32 = 128;
pub const MAX_BLOCKS_Z: u32 = 512;
pub const MAX_CHUNKS_X: u32 = MAX_BLOCKS_X / 16;
pub const MAX_CHUNKS_Y: u32 = MAX_BLOCKS_Y / 16;
pub const MAX_CHUNKS_Z: u32 = MAX_BLOCKS_Z / 16;
pub const MAX_CHUNK_COUNT: u32 = MAX_CHUNKS_X * MAX_CHUNKS_Y * MAX_CHUNKS_Z;

pub const Error = error{InvalidDimensions};

/// Identity of one 16x16x16 chunk. Coordinates are chunk units within the
/// design-limit grid; the reserved bits keep the value a single u16.
pub const ChunkCoord = packed struct(u16) {
    x: u5,
    y: u3,
    z: u5,
    reserved: u3 = 0,

    pub fn init(x: u32, y: u32, z: u32) ChunkCoord {
        std.debug.assert(x < MAX_CHUNKS_X);
        std.debug.assert(y < MAX_CHUNKS_Y);
        std.debug.assert(z < MAX_CHUNKS_Z);
        return .{ .x = @intCast(x), .y = @intCast(y), .z = @intCast(z) };
    }

    /// Dense lookup index, stable over all supported shapes: it uses the
    /// design-limit strides rather than the current shape's, so an index
    /// means the same coordinate no matter what world is loaded. Range is
    /// the inclusive 0...8191.
    pub fn index(self: ChunkCoord) u16 {
        const wide = (@as(u32, self.y) * MAX_CHUNKS_Z + self.z) * MAX_CHUNKS_X + self.x;
        return @intCast(wide);
    }

    pub fn from_index(i: u16) ChunkCoord {
        std.debug.assert(i < MAX_CHUNK_COUNT);
        const x: u5 = @intCast(i % MAX_CHUNKS_X);
        const rest = i / MAX_CHUNKS_X;
        const z: u5 = @intCast(rest % MAX_CHUNKS_Z);
        const y: u3 = @intCast(rest / MAX_CHUNKS_Z);
        return .{ .x = x, .y = y, .z = z };
    }

    pub fn eql(a: ChunkCoord, b: ChunkCoord) bool {
        return a.x == b.x and a.y == b.y and a.z == b.z;
    }
};

/// Block and chunk dimensions of the loaded world. Dimensions must be
/// nonzero, chunk-aligned, and within the design limits. Partial edge
/// chunks are rejected for now; if they are ever required, their
/// padded-boundary behavior belongs here so callers see one policy.
pub const WorldShape = struct {
    chunks_x: u32,
    chunks_y: u32,
    chunks_z: u32,

    pub fn init(dim_x: u32, dim_y: u32, dim_z: u32) Error!WorldShape {
        if (dim_x == 0 or dim_y == 0 or dim_z == 0) return error.InvalidDimensions;
        if (dim_x > MAX_BLOCKS_X or dim_y > MAX_BLOCKS_Y or dim_z > MAX_BLOCKS_Z)
            return error.InvalidDimensions;
        if (dim_x % 16 != 0 or dim_y % 16 != 0 or dim_z % 16 != 0)
            return error.InvalidDimensions;
        return .{
            .chunks_x = dim_x / 16,
            .chunks_y = dim_y / 16,
            .chunks_z = dim_z / 16,
        };
    }

    pub fn blocks_x(self: WorldShape) u32 {
        return self.chunks_x * 16;
    }
    pub fn blocks_y(self: WorldShape) u32 {
        return self.chunks_y * 16;
    }
    pub fn blocks_z(self: WorldShape) u32 {
        return self.chunks_z * 16;
    }

    pub fn chunk_count(self: WorldShape) u32 {
        return self.chunks_x * self.chunks_y * self.chunks_z;
    }

    pub fn contains(self: WorldShape, coord: ChunkCoord) bool {
        return coord.x < self.chunks_x and coord.y < self.chunks_y and coord.z < self.chunks_z;
    }
};

test "ChunkCoord index anchors" {
    const origin = ChunkCoord.init(0, 0, 0);
    try std.testing.expectEqual(@as(u16, 0), origin.index());

    const max = ChunkCoord.init(31, 7, 31);
    try std.testing.expectEqual(@as(u16, 8191), max.index());
    try std.testing.expectEqual(MAX_CHUNK_COUNT - 1, @as(u32, max.index()));
}

test "ChunkCoord index round trips" {
    var i: u16 = 0;
    while (i < MAX_CHUNK_COUNT) : (i += 1) {
        const coord = ChunkCoord.from_index(i);
        try std.testing.expectEqual(i, coord.index());
    }
}

test "ChunkCoord equality" {
    const a = ChunkCoord.init(3, 2, 1);
    const b = ChunkCoord.init(3, 2, 1);
    const other = ChunkCoord.init(1, 2, 3);
    try std.testing.expect(a.eql(b));
    try std.testing.expect(!a.eql(other));
}

test "WorldShape accepts current 256x64x256 world" {
    const shape = try WorldShape.init(256, 64, 256);
    try std.testing.expectEqual(@as(u32, 16), shape.chunks_x);
    try std.testing.expectEqual(@as(u32, 4), shape.chunks_y);
    try std.testing.expectEqual(@as(u32, 16), shape.chunks_z);
    try std.testing.expectEqual(@as(u32, 1024), shape.chunk_count());
    try std.testing.expectEqual(@as(u32, 256), shape.blocks_x());
    try std.testing.expectEqual(@as(u32, 64), shape.blocks_y());
    try std.testing.expectEqual(@as(u32, 256), shape.blocks_z());

    try std.testing.expect(shape.contains(ChunkCoord.init(15, 3, 15)));
    try std.testing.expect(!shape.contains(ChunkCoord.init(16, 0, 0)));
    try std.testing.expect(!shape.contains(ChunkCoord.init(0, 4, 0)));
    try std.testing.expect(!shape.contains(ChunkCoord.init(0, 0, 16)));
}

test "WorldShape accepts design-limit world" {
    const shape = try WorldShape.init(512, 128, 512);
    try std.testing.expectEqual(MAX_CHUNK_COUNT, shape.chunk_count());
    try std.testing.expect(shape.contains(ChunkCoord.init(31, 7, 31)));
}

test "WorldShape rejects invalid dimensions" {
    try std.testing.expectError(error.InvalidDimensions, WorldShape.init(0, 64, 256));
    try std.testing.expectError(error.InvalidDimensions, WorldShape.init(256, 0, 256));
    try std.testing.expectError(error.InvalidDimensions, WorldShape.init(256, 64, 0));
    try std.testing.expectError(error.InvalidDimensions, WorldShape.init(528, 64, 256));
    try std.testing.expectError(error.InvalidDimensions, WorldShape.init(256, 144, 256));
    try std.testing.expectError(error.InvalidDimensions, WorldShape.init(256, 64, 528));
    // Partial edge chunks are not supported yet.
    try std.testing.expectError(error.InvalidDimensions, WorldShape.init(248, 64, 256));
    try std.testing.expectError(error.InvalidDimensions, WorldShape.init(256, 60, 256));
}
