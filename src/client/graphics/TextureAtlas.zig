const std = @import("std");
const SNORM_UV_MAX: i32 = 32767;
const SNORM_UV_STEPS: i32 = SNORM_UV_MAX + 1;
// Avoid exact atlas boundaries without visibly cropping the source tile. The
// max edge uses one extra step so the last atlas tile never emits SNORM 32767,
// which repeat samplers treat as UV 1.0.
const MIN_GUARD: u16 = 1;
const MAX_GUARD: u16 = 2;

/// Maps integer tile indices to SNORM16 UV coordinates for a rectangular texture atlas.
/// SNORM16 range [0, 32767] corresponds to UV [0, 1].
/// All dimensions must be powers of two.
pub const TextureAtlas = struct {
    col_log2: u5,
    row_log2: u5,
    min_guard_u: u16, // left/top guard in SNORM16 units
    min_guard_v: u16,
    max_guard_u: u16, // right/bottom guard in SNORM16 units
    max_guard_v: u16,

    pub fn init(res_x: u32, res_y: u32, rows: u32, cols: u32) TextureAtlas {
        std.debug.assert(std.math.isPowerOfTwo(res_x));
        std.debug.assert(std.math.isPowerOfTwo(res_y));
        std.debug.assert(std.math.isPowerOfTwo(rows));
        std.debug.assert(std.math.isPowerOfTwo(cols));
        const guards = edge_guards();
        return .{
            .col_log2 = @intCast(@ctz(cols)),
            .row_log2 = @intCast(@ctz(rows)),
            .min_guard_u = guards.min,
            .min_guard_v = guards.min,
            .max_guard_u = guards.max,
            .max_guard_v = guards.max,
        };
    }

    /// Width of one tile in SNORM16 units after applying edge guards.
    pub fn tileWidth(self: TextureAtlas) i16 {
        return @intCast(self.tileSpanU() - @as(i32, self.min_guard_u) - @as(i32, self.max_guard_u));
    }

    /// Height of one tile in SNORM16 units after applying edge guards.
    pub fn tileHeight(self: TextureAtlas) i16 {
        return @intCast(self.tileSpanV() - @as(i32, self.min_guard_v) - @as(i32, self.max_guard_v));
    }

    /// SNORM16 U coordinate for the left edge of tile column x.
    pub fn tileU(self: TextureAtlas, x: u32) i16 {
        std.debug.assert(x < (@as(u32, 1) << self.col_log2));
        return @intCast(@as(i32, @intCast(x)) * self.tileSpanU() + @as(i32, self.min_guard_u));
    }

    /// SNORM16 V coordinate for the top edge of tile row y.
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

const EdgeGuards = struct {
    min: u16,
    max: u16,
};

fn edge_guards() EdgeGuards {
    return .{ .min = MIN_GUARD, .max = MAX_GUARD };
}

test "default atlas inset follows platform" {
    const atlas = TextureAtlas.init(256, 256, 16, 16);
    const guards = edge_guards();
    const expected_min: i16 = @intCast(guards.min);
    const expected_max: i16 = @intCast(guards.max);
    const stride: i16 = 2048;

    try std.testing.expectEqual(expected_min, atlas.tileU(0));
    try std.testing.expectEqual(expected_min, atlas.tileV(0));
    try std.testing.expectEqual(stride + expected_min, atlas.tileU(1));
    try std.testing.expectEqual(stride - expected_min - expected_max, atlas.tileWidth());
    try std.testing.expectEqual(stride - expected_min - expected_max, atlas.tileHeight());
    try std.testing.expectEqual(SNORM_UV_STEPS - expected_max, atlas.tileU(15) + atlas.tileWidth());
}
