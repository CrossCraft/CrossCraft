const FP16 = @import("fp.zig").FP(32, 16, true);

pub const TWO_PI: i32 = 411775;
pub const PI: i32 = 205887;
// Precomputed reciprocal: 1024 * (1 << 32) / TWO_PI, for fast angle->table index.
const SIN_RECIP: i64 = @divTrunc(1024 * (1 << 32), @as(i64, TWO_PI));

const SIN_TABLE: [1024]i32 = blk: {
    @setEvalBranchQuota(10000);
    var table: [1024]i32 = undefined;
    for (0..1024) |i| {
        const angle: f64 = @as(f64, @floatFromInt(i)) * (2.0 * @import("std").math.pi / 1024.0);
        table[i] = @intFromFloat(@round(@sin(angle) * 65536.0));
    }
    break :blk table;
};

pub fn sin_fp16(angle: FP16) FP16 {
    var a: i64 = angle.value;
    a = @rem(a, @as(i64, TWO_PI));
    if (a < 0) a += TWO_PI;
    const idx: u32 = @intCast((a *% SIN_RECIP) >> 32);
    return .{ .value = SIN_TABLE[idx & 1023] };
}

pub fn cos_fp16(angle: FP16) FP16 {
    return sin_fp16(.{ .value = angle.value +% @divTrunc(TWO_PI, 4) });
}
