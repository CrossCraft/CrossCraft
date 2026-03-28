const std = @import("std");
const assert = std.debug.assert;
const FP16 = @import("fp.zig").FP(32, 16, true);

pub const Xorshift64 = struct {
    state: u64,

    pub fn init(seed: u64) Xorshift64 {
        return .{ .state = if (seed == 0) 1 else seed };
    }

    pub fn next(self: *Xorshift64) u64 {
        var x = self.state;
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        self.state = x;
        return x;
    }

    pub fn nextBounded(self: *Xorshift64, bound: u32) u32 {
        assert(bound > 0);
        return @intCast(self.next() % @as(u64, bound));
    }

    /// Returns FP16 in [0, 1).
    pub fn nextFloat(self: *Xorshift64) FP16 {
        return .{ .value = @intCast(self.next() & 0xFFFF) };
    }
};
