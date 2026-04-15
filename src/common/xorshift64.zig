const std = @import("std");
const assert = std.debug.assert;
const FP16 = @import("fp.zig").FP(32, 16, true);

pub const Xorshift64 = struct {
    state: u64,

    pub fn init(seed: u64) Xorshift64 {
        var rng: Xorshift64 = .{ .state = if (seed == 0) 1 else seed };
        // Warm-up: low-entropy seeds (e.g. 1) produce a poorly-mixed first
        // output. Discard a few iterations so the first caller-visible value
        // has full state diffusion.
        for (0..8) |_| _ = rng.next();
        return rng;
    }

    pub fn next(self: *Xorshift64) u64 {
        var x = self.state;
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        self.state = x;
        return x;
    }

    // Modulo-bias is acceptable here: only used for noise seeding and the
    // 256-entry Fisher-Yates shuffle, where a 64-bit source over a tiny
    // bound keeps the bias far below perceptual thresholds.
    pub fn next_bounded(self: *Xorshift64, bound: u32) u32 {
        assert(bound > 0);
        return @intCast(self.next() % @as(u64, bound));
    }

    /// Returns FP16 in [0, 1).
    pub fn next_float(self: *Xorshift64) FP16 {
        return .{ .value = @intCast(self.next() & 0xFFFF) };
    }
};
