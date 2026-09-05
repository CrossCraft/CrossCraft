const std = @import("std");
const assert = std.debug.assert;
const SnormUvSteps: i32 = 32768;
// Keep the last tile below UV 1.0 for repeat samplers.
const MinGuard: i32 = 1;
const MaxGuard: i32 = 2;

/// Maps integer tile indices to SNORM16 UV coordinates for a rectangular texture atlas.
/// SNORM16 range [0, 32767] corresponds to UV [0, 1].
/// All dimensions must be powers of two.
pub const TextureAtlas = struct {
    col_log2: u5,
    row_log2: u5,

    pub fn init(rows: u32, cols: u32) TextureAtlas {
        assert(std.math.isPowerOfTwo(rows));
        assert(std.math.isPowerOfTwo(cols));
        return .{
            .col_log2 = @intCast(@ctz(cols)),
            .row_log2 = @intCast(@ctz(rows)),
        };
    }

    pub fn tile_width(self: TextureAtlas) i16 {
        return @intCast((SnormUvSteps >> self.col_log2) - MinGuard - MaxGuard);
    }

    pub fn tile_height(self: TextureAtlas) i16 {
        return @intCast((SnormUvSteps >> self.row_log2) - MinGuard - MaxGuard);
    }

    pub fn tile_u(self: TextureAtlas, x: u32) i16 {
        assert(x < (@as(u32, 1) << self.col_log2));
        return @intCast(@as(i32, @intCast(x)) * (SnormUvSteps >> self.col_log2) + MinGuard);
    }

    pub fn tile_v(self: TextureAtlas, y: u32) i16 {
        assert(y < (@as(u32, 1) << self.row_log2));
        return @intCast(@as(i32, @intCast(y)) * (SnormUvSteps >> self.row_log2) + MinGuard);
    }
};

test "atlas tiles stay inside sampling boundaries" {
    const atlas = TextureAtlas.init(16, 16);
    const stride: i16 = 2048;

    try std.testing.expectEqual(MinGuard, atlas.tile_u(0));
    try std.testing.expectEqual(MinGuard, atlas.tile_v(0));
    try std.testing.expectEqual(stride + MinGuard, atlas.tile_u(1));
    try std.testing.expectEqual(stride - MinGuard - MaxGuard, atlas.tile_width());
    try std.testing.expectEqual(stride - MinGuard - MaxGuard, atlas.tile_height());
    try std.testing.expectEqual(SnormUvSteps - MaxGuard, atlas.tile_u(15) + atlas.tile_width());
}
