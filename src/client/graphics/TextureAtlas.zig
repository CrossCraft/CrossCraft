const std = @import("std");
const assert = std.debug.assert;
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
        assert(std.math.isPowerOfTwo(rows));
        assert(std.math.isPowerOfTwo(cols));
        return .{
            .col_log2 = @intCast(@ctz(cols)),
            .row_log2 = @intCast(@ctz(rows)),
            .min_guard_u = MIN_GUARD,
            .min_guard_v = MIN_GUARD,
            .max_guard_u = MAX_GUARD,
            .max_guard_v = MAX_GUARD,
        };
    }

    pub fn tile_width(self: TextureAtlas) i16 {
        return @intCast(self.tile_span_u() - @as(i32, self.min_guard_u) - @as(i32, self.max_guard_u));
    }

    pub fn tile_height(self: TextureAtlas) i16 {
        return @intCast(self.tile_span_v() - @as(i32, self.min_guard_v) - @as(i32, self.max_guard_v));
    }

    pub fn tile_u(self: TextureAtlas, x: u32) i16 {
        assert(x < (@as(u32, 1) << self.col_log2));
        return @intCast(@as(i32, @intCast(x)) * self.tile_span_u() + @as(i32, self.min_guard_u));
    }

    pub fn tile_v(self: TextureAtlas, y: u32) i16 {
        assert(y < (@as(u32, 1) << self.row_log2));
        return @intCast(@as(i32, @intCast(y)) * self.tile_span_v() + @as(i32, self.min_guard_v));
    }

    fn tile_span_u(self: TextureAtlas) i32 {
        return SNORM_UV_STEPS >> self.col_log2;
    }

    fn tile_span_v(self: TextureAtlas) i32 {
        return SNORM_UV_STEPS >> self.row_log2;
    }
};

test "atlas tiles stay inside sampling boundaries" {
    const atlas = TextureAtlas.init(16, 16);
    const expected_min: i16 = MIN_GUARD;
    const expected_max: i16 = MAX_GUARD;
    const stride: i16 = 2048;

    try std.testing.expectEqual(expected_min, atlas.tile_u(0));
    try std.testing.expectEqual(expected_min, atlas.tile_v(0));
    try std.testing.expectEqual(stride + expected_min, atlas.tile_u(1));
    try std.testing.expectEqual(stride - expected_min - expected_max, atlas.tile_width());
    try std.testing.expectEqual(stride - expected_min - expected_max, atlas.tile_height());
    try std.testing.expectEqual(SNORM_UV_STEPS - expected_max, atlas.tile_u(15) + atlas.tile_width());
}
