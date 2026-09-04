const std = @import("std");
const SNORM_UV_MAX: i32 = 32767;
const SNORM_UV_STEPS: i32 = SNORM_UV_MAX + 1;
// Keep the last tile below UV 1.0 for repeat samplers.
const MIN_GUARD: u16 = 1;
const MAX_GUARD: u16 = 2;

/// Maps integer tile indices to SNORM16 UV coordinates for a rectangular texture atlas.
/// SNORM16 range [0, 32767] corresponds to UV [0, 1].
/// All dimensions must be powers of two.
pub const TextureAtlas = struct {
    col_log2: u5,
    row_log2: u5,
    min_guard_u: u16,
    min_guard_v: u16,
    max_guard_u: u16,
    max_guard_v: u16,

    pub fn init(rows: u32, cols: u32) TextureAtlas {
        std.debug.assert(std.math.isPowerOfTwo(rows));
        std.debug.assert(std.math.isPowerOfTwo(cols));
        return .{
            .col_log2 = @intCast(@ctz(cols)),
            .row_log2 = @intCast(@ctz(rows)),
            .min_guard_u = MIN_GUARD,
            .min_guard_v = MIN_GUARD,
            .max_guard_u = MAX_GUARD,
            .max_guard_v = MAX_GUARD,
        };
    }

    pub fn tileWidth(self: TextureAtlas) i16 {
        return @intCast(self.tileSpanU() - @as(i32, self.min_guard_u) - @as(i32, self.max_guard_u));
    }

    pub fn tileHeight(self: TextureAtlas) i16 {
        return @intCast(self.tileSpanV() - @as(i32, self.min_guard_v) - @as(i32, self.max_guard_v));
    }

    pub fn tileU(self: TextureAtlas, x: u32) i16 {
        std.debug.assert(x < (@as(u32, 1) << self.col_log2));
        return @intCast(@as(i32, @intCast(x)) * self.tileSpanU() + @as(i32, self.min_guard_u));
    }

    pub fn tileV(self: TextureAtlas, y: u32) i16 {
        std.debug.assert(y < (@as(u32, 1) << self.row_log2));
        return @intCast(@as(i32, @intCast(y)) * self.tileSpanV() + @as(i32, self.min_guard_v));
    }

    fn tileSpanU(self: TextureAtlas) i32 {
        return SNORM_UV_STEPS >> self.col_log2;
    }

    fn tileSpanV(self: TextureAtlas) i32 {
        return SNORM_UV_STEPS >> self.row_log2;
    }
};

test "atlas tiles stay inside sampling boundaries" {
    const atlas = TextureAtlas.init(16, 16);
    const expected_min: i16 = MIN_GUARD;
    const expected_max: i16 = MAX_GUARD;
    const stride: i16 = 2048;

    try std.testing.expectEqual(expected_min, atlas.tileU(0));
    try std.testing.expectEqual(expected_min, atlas.tileV(0));
    try std.testing.expectEqual(stride + expected_min, atlas.tileU(1));
    try std.testing.expectEqual(stride - expected_min - expected_max, atlas.tileWidth());
    try std.testing.expectEqual(stride - expected_min - expected_max, atlas.tileHeight());
    try std.testing.expectEqual(SNORM_UV_STEPS - expected_max, atlas.tileU(15) + atlas.tileWidth());
}
