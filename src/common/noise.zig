const std = @import("std");
const assert = std.debug.assert;
const FP16 = @import("fp.zig").FP(32, 16, true);
const Xorshift64 = @import("xorshift64.zig").Xorshift64;

// FP16 constants
pub const FP_ONE = FP16.from(1);
pub const TWO_PI: i32 = 411775;
pub const PI: i32 = 205887;
// Precomputed reciprocal: 1024 * (1 << 32) / TWO_PI, for fast angle->table index.
const SIN_RECIP: i64 = @divTrunc(1024 * (1 << 32), @as(i64, TWO_PI));

// -- Trigonometry --------------------------------------------------------

const SIN_TABLE: [1024]i32 = blk: {
    @setEvalBranchQuota(10000);
    var table: [1024]i32 = undefined;
    for (0..1024) |i| {
        const angle: f64 = @as(f64, @floatFromInt(i)) * (2.0 * std.math.pi / 1024.0);
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
    return sin_fp16(.{ .value = angle.value + @divTrunc(TWO_PI, 4) });
}

// -- Noise helpers -------------------------------------------------------

fn fade_16(t: FP16) FP16 {
    // 6t^5 - 15t^4 + 10t^3 = t^3(t(6t - 15) + 10)
    return t.mul(FP16.from(6)).sub(FP16.from(15)).mul(t).add(FP16.from(10)).mul(t).mul(t).mul(t);
}

fn lerp_16(t: FP16, a: FP16, b: FP16) FP16 {
    return a.add(t.mul(b.sub(a)));
}

fn grad_2d(hash: u8, x: FP16, z: FP16) FP16 {
    // Classic improved Perlin gradient set projected to 2D (z_3d = 0).
    const h = hash & 15;
    const u = if (h < 8) x else z;
    const v = if (h < 4) z else if (h == 12 or h == 14) x else FP16{ .value = 0 };
    const p1 = if (h & 1 == 0) u else u.neg();
    const p2 = if (h & 2 == 0) v else v.neg();
    return p1.add(p2);
}

// -- 2D Perlin noise (seeded) --------------------------------------------

pub const PerlinNoise2D = struct {
    perm: [512]u8,

    pub fn init(seed: u64) PerlinNoise2D {
        var rng = Xorshift64.init(seed);
        var result: PerlinNoise2D = undefined;
        for (0..256) |i| {
            result.perm[i] = @intCast(i);
        }
        // Fisher-Yates shuffle
        var i: u32 = 255;
        while (i > 0) : (i -= 1) {
            const j = rng.next_bounded(i + 1);
            const tmp = result.perm[i];
            result.perm[i] = result.perm[j];
            result.perm[j] = tmp;
        }
        // Mirror for wrap-around
        for (0..256) |k| {
            result.perm[256 + k] = result.perm[k];
        }
        return result;
    }

    pub fn noise(self: *const PerlinNoise2D, x: FP16, z: FP16) FP16 {
        const X: usize = @intCast(@as(u32, @bitCast(x.int())) & 255);
        const Z: usize = @intCast(@as(u32, @bitCast(z.int())) & 255);
        const xf: FP16 = .{ .value = x.frac() };
        const zf: FP16 = .{ .value = z.frac() };
        const u = fade_16(xf);
        const v = fade_16(zf);
        const A: usize = @as(usize, self.perm[X]) + Z;
        const Bp: usize = @as(usize, self.perm[X + 1]) + Z;
        return lerp_16(v, lerp_16(u, grad_2d(self.perm[A], xf, zf), grad_2d(self.perm[Bp], xf.sub(FP_ONE), zf)), lerp_16(u, grad_2d(self.perm[A + 1], xf, zf.sub(FP_ONE)), grad_2d(self.perm[Bp + 1], xf.sub(FP_ONE), zf.sub(FP_ONE))));
    }
};

// -- Octave noise --------------------------------------------------------

pub const OctaveNoise = struct {
    octaves: [8]PerlinNoise2D,
    count: u32,

    pub fn init(rng: *Xorshift64, n: u32) OctaveNoise {
        assert(n >= 1 and n <= 8);
        var result: OctaveNoise = undefined;
        result.count = n;
        for (0..n) |i| {
            result.octaves[i] = PerlinNoise2D.init(rng.next());
        }
        return result;
    }

    pub fn compute(self: *const OctaveNoise, x: FP16, z: FP16) FP16 {
        var acc: i64 = 0;
        for (0..self.count) |i| {
            const shift: u5 = @intCast(i);
            const nx: FP16 = .{ .value = x.value >> shift };
            const nz: FP16 = .{ .value = z.value >> shift };
            const val = self.octaves[i].noise(nx, nz);
            acc += @as(i64, val.value) << shift;
        }
        return .{ .value = @intCast(acc) };
    }
};

// -- Combined noise ------------------------------------------------------

pub const CombinedNoise = struct {
    noise1: OctaveNoise,
    noise2: OctaveNoise,

    pub fn init(rng: *Xorshift64, oct1: u32, oct2: u32) CombinedNoise {
        return .{
            .noise1 = OctaveNoise.init(rng, oct1),
            .noise2 = OctaveNoise.init(rng, oct2),
        };
    }

    pub fn compute(self: *const CombinedNoise, x: FP16, z: FP16) FP16 {
        return self.noise1.compute(x.add(self.noise2.compute(x, z)), z);
    }
};
