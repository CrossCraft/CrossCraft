const std = @import("std");

/// Maps integer tile indices to SNORM16 UV coordinates for a rectangular texture atlas.
/// SNORM16 range [0, 32767] corresponds to UV [0, 1].
/// All dimensions must be powers of two.
pub const TextureAtlas = struct {
    col_log2: u5,
    row_log2: u5,

    pub fn init(res_x: u32, res_y: u32, rows: u32, cols: u32) TextureAtlas {
        std.debug.assert(std.math.isPowerOfTwo(res_x));
        std.debug.assert(std.math.isPowerOfTwo(res_y));
        std.debug.assert(std.math.isPowerOfTwo(rows));
        std.debug.assert(std.math.isPowerOfTwo(cols));
        return .{
            .col_log2 = @intCast(@ctz(cols)),
            .row_log2 = @intCast(@ctz(rows)),
        };
    }

    /// Width of one tile in SNORM16 units, inset by one epsilon on each edge.
    pub fn tileWidth(self: TextureAtlas) i16 {
        return @intCast((@as(i32, 32767) >> self.col_log2)); // - 2 * @as(i32, self.epsilon_x));
    }

    /// Height of one tile in SNORM16 units, inset by one epsilon on each edge.
    pub fn tileHeight(self: TextureAtlas) i16 {
        return @intCast((@as(i32, 32767) >> self.row_log2)); // - 2 * @as(i32, self.epsilon_y));
    }

    /// SNORM16 U coordinate for the left edge of tile column x, inset by one epsilon.
    pub fn tileU(self: TextureAtlas, x: u32) i16 {
        std.debug.assert(x < (@as(u32, 1) << self.col_log2));
        const stride: i32 = @as(i32, 32767) >> self.col_log2;
        return @intCast(@as(i32, @intCast(x)) * stride);
    }

    /// SNORM16 V coordinate for the top edge of tile row y, inset by one epsilon.
    pub fn tileV(self: TextureAtlas, y: u32) i16 {
        std.debug.assert(y < (@as(u32, 1) << self.row_log2));
        const stride: i32 = @as(i32, 32767) >> self.row_log2;
        return @intCast(@as(i32, @intCast(y)) * stride);
    }
};
