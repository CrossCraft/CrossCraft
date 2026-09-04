const std = @import("std");
const assert = std.debug.assert;

const random_state = @This();

pub const state_bits: u6 = 48;
pub const modulus: u64 = @as(u64, 1) << state_bits;
pub const mask: u64 = modulus - 1;
pub const multiplier: u64 = 25_214_903_917;
pub const addend: u64 = 11;

state: u64,

pub fn init(seed: i64) random_state {
    const low_48 = @as(u64, @bitCast(seed)) & mask;
    const initialized: random_state = .{ .state = (low_48 ^ multiplier) & mask };
    assert(initialized.state < modulus);
    return initialized;
}

pub fn next_state(self: *random_state) void {
    assert(self.state < modulus);
    self.state = (self.state *% multiplier +% addend) & mask;
    assert(self.state < modulus);
}

pub inline fn next_bits(self: *random_state, comptime bits: u6) u32 {
    assert(bits > 0 and bits <= 32);
    self.next_state();
    const result: u32 = @intCast(self.state >> (state_bits - bits));
    assert(@as(u64, result) < (@as(u64, 1) << bits));
    return result;
}

pub fn next_int(self: *random_state) i32 {
    return @bitCast(self.next_bits(32));
}

// Constant bounds compile to multiplication or shifts instead of PSP division.
pub inline fn next_int_bounded(self: *random_state, bound: u32) u32 {
    assert(bound > 0 and bound < 2_147_483_648);

    if (std.math.isPowerOfTwo(bound)) {
        const bits = self.next_bits(31);
        const result: u32 = bits >> @intCast(31 - @ctz(bound));
        assert(result < bound);
        return result;
    }

    while (true) {
        const bits = self.next_bits(31);
        const value = bits % bound;
        const acceptance = bits - value + (bound - 1);
        if (acceptance < 2_147_483_648) {
            assert(value < bound);
            return value;
        }
    }
}

pub fn next_float(self: *random_state) f32 {
    const numerator = self.next_bits(24);
    // Multiplication by 2^-24 is exact and avoids PSP soft-float division.
    const result = @as(f32, @floatFromInt(numerator)) * @as(f32, 1.0 / 16_777_216.0);
    assert(result >= 0.0 and result < 1.0);
    return result;
}

pub fn next_double(self: *random_state) f64 {
    const high = self.next_bits(26);
    const low = self.next_bits(27);
    const numerator = @as(u64, high) * 134_217_728 + low;
    const result = @as(f64, @floatFromInt(numerator)) / 9_007_199_254_740_992.0;
    assert(result >= 0.0 and result < 1.0);
    return result;
}

test "initial state and documented Java-compatible draws" {
    var actual = random_state.init(0);
    try std.testing.expectEqual(@as(u64, multiplier), actual.state);
    try std.testing.expectEqual(@as(i32, -1_155_484_576), actual.next_int());
    try std.testing.expectEqual(@as(i32, -723_955_400), actual.next_int());

    const negative = random_state.init(-1);
    try std.testing.expectEqual(@as(u64, ((@as(u64, @bitCast(@as(i64, -1))) & mask) ^ multiplier) & mask), negative.state);
}

test "bounded draws preserve range and rejection state transitions" {
    var actual = random_state.init(12_345);
    const expected = [_]u32{ 51, 80, 41, 28, 55, 84, 75, 2 };
    for (expected) |value| try std.testing.expectEqual(value, actual.next_int_bounded(100));

    var powers = random_state.init(7);
    try std.testing.expectEqual(@as(u32, 11), powers.next_int_bounded(16));
}

test "floating draws match Java Random" {
    var float_random = random_state.init(0);
    try std.testing.expectEqual(@as(u32, 0x3f3b20b4), @as(u32, @bitCast(float_random.next_float())));

    var double_random = random_state.init(0);
    try std.testing.expectEqual(@as(u64, 0x3fe764168ea6ca89), @as(u64, @bitCast(double_random.next_double())));
}
