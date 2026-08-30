const std = @import("std");
const assert = std.debug.assert;
const builtin = @import("builtin");

const random_state = @import("random.zig");

// Down/up rounding to integer, emitted without a libcall. compiler_rt's
// floorf/ceilf are soft-float routines (~50 instructions each on MIPS) and
// every cascade column performs several; the MIPS FPU's truncating cvt.w.s
// (single instruction) plus a sign-corrected unit adjustment reproduces the
// exact @floor/@ceil values branch-free-ish. Non-MIPS targets keep the native
// @floor/@ceil, which are single instructions there. Exact values are
// preserved for every finite in-range input (|x| < 2^31), so no decision can
// move as a result of this substitution.
pub inline fn floor_f32(x: f32) f32 {
    if (builtin.cpu.arch == .mipsel or builtin.cpu.arch == .mips) {
        const truncated: f32 = @floatFromInt(@as(i32, @intFromFloat(x)));
        return if (x < truncated) truncated - 1.0 else truncated;
    }
    return @floor(x);
}

pub inline fn ceil_f32(x: f32) f32 {
    if (builtin.cpu.arch == .mipsel or builtin.cpu.arch == .mips) {
        const truncated: f32 = @floatFromInt(@as(i32, @intFromFloat(x)));
        return if (x > truncated) truncated + 1.0 else truncated;
    }
    return @ceil(x);
}

pub const permutation = struct {
    entries: [512]u8,
    // fused[i] == entries[entries[i]] for i in [0, 512). The 2D sampler always
    // hashes with an implicit z of 0, whose third lookup is entries[xy + 0]:
    // fused turns that three-level chain (entries[entries[entries[x] + y] + 0])
    // into two loads. Pure table indirection; the hash value is unchanged.
    fused: [512]u8,
    // fused_masked[i] == fused[i] & 15: the f32 kernels consume the hash only
    // through the 16-entry gradient coefficient table, so masking once at
    // initialization removes the per-corner andi from every sample.
    fused_masked: [512]u8,

    pub fn init(random: *random_state) permutation {
        var result: permutation = undefined;
        for (0..256) |index| result.entries[index] = @intCast(index);

        for (0..256) |index| {
            const remaining: u32 = @intCast(256 - index);
            const draw = random.next_int_bounded(remaining);
            const other = index + draw;
            assert(other < 256);
            std.mem.swap(u8, &result.entries[index], &result.entries[other]);
        }

        var seen = [_]bool{false} ** 256;
        for (0..256) |index| {
            const value = result.entries[index];
            assert(!seen[value]);
            seen[value] = true;
            result.entries[index + 256] = value;
        }
        for (0..512) |index| {
            const value = result.entries[index];
            result.fused[index] = result.entries[value];
            result.fused_masked[index] = result.fused[index] & 15;
        }
        return result;
    }

    pub fn entry(self: *const permutation, index: usize) u8 {
        assert(index < self.entries.len);
        const value = self.entries[index];
        assert(value < 256);
        return value;
    }
};

pub fn floor_coordinate(coordinate: f32) i32 {
    assert(std.math.isFinite(coordinate));
    assert(coordinate >= -2_147_483_648.0 and coordinate < 2_147_483_648.0);
    return @intFromFloat(floor_f32(coordinate));
}

pub fn fade(parameter: f32) f32 {
    return parameter * parameter * parameter * (parameter * (parameter * 6.0 - 15.0) + 10.0);
}

// The lattice-sampled chains evaluate at (x * 2^-k, y * 2^-k) for integer
// (x, y): lattice cell (x >> k), fractional offset ((x & (2^k - 1)) * 2^-k).
// All of these are exact (a power-of-two multiply only shifts the exponent,
// x <= 512 keeps the product representable), and fade(offset) is a pure
// function of the integer mask. Memoizing it per octave turns the 7-op
// Hermite fade into one L1D-resident load; the per-sample scale multiplies
// and the FPU trunc round-trips disappear for these chains entirely.
pub const lattice_fade_tables: [8][256]f32 = blk: {
    @setEvalBranchQuota(16_000);
    var tables: [8][256]f32 = undefined;
    for (0..tables.len) |row| {
        const k: u32 = @as(u32, @intCast(row)) + 1;
        const mask: u32 = (@as(u32, 1) << @intCast(k)) - 1;
        const inverse: f32 = 1.0 / @as(f32, @floatFromInt(@as(u32, 1) << @intCast(k)));
        for (0..tables[row].len) |index| {
            tables[row][index] = fade(@as(f32, @floatFromInt(index & mask)) * inverse);
        }
    }
    break :blk tables;
};

/// Integer-domain sampling for the lattice chains (both coordinates are
/// non-negative integers, sampled at dyadic octave scales). Bits are
/// identical to the float-domain gradient_noise on these inputs: the lattice
/// coordinate is x >> k (== floor(x * 2^-k) for non-negative x), the offset
/// (x & mask) * 2^-k equals x * 2^-k - floor exactly, and the fade table is
/// the same Hermite polynomial evaluated on the same bits.
fn gradient_noise_lattice(table: *const permutation, x: u32, y: u32, k: u4) f32 {
    const lattice_x: i32 = @intCast(x >> k);
    const lattice_y: i32 = @intCast(y >> k);
    const x_mask: u32 = x & ((@as(u32, 1) << k) - 1);
    const y_mask: u32 = y & ((@as(u32, 1) << k) - 1);
    const scale: f32 = 1.0 / @as(f32, @floatFromInt(@as(u32, 1) << k));
    const offset_x: f32 = @as(f32, @floatFromInt(x_mask)) * scale;
    const offset_y: f32 = @as(f32, @floatFromInt(y_mask)) * scale;
    const faded_x: f32 = lattice_fade_tables[k - 1][x_mask];
    const faded_y: f32 = lattice_fade_tables[k - 1][y_mask];

    const lower_x_lower_y = interpolate(faded_x, gradient_2d(lattice_hash_2d_masked(table, lattice_x, lattice_y), offset_x, offset_y), gradient_2d(lattice_hash_2d_masked(table, lattice_x + 1, lattice_y), offset_x - 1.0, offset_y));
    const upper_x_lower_y = interpolate(faded_x, gradient_2d(lattice_hash_2d_masked(table, lattice_x, lattice_y + 1), offset_x, offset_y - 1.0), gradient_2d(lattice_hash_2d_masked(table, lattice_x + 1, lattice_y + 1), offset_x - 1.0, offset_y - 1.0));
    return interpolate(faded_y, lower_x_lower_y, upper_x_lower_y);
}

pub fn interpolate(weight: f32, lower: f32, upper: f32) f32 {
    return lower + weight * (upper - lower);
}

pub fn gradient(hash: u8, x: f32, y: f32, z: f32) f32 {
    const nibble = hash & 15;
    const first = if (nibble < 8) x else y;
    const second = if (nibble < 4) y else if (nibble == 12 or nibble == 14) x else z;
    const signed_first = if ((nibble & 1) == 0) first else -first;
    const signed_second = if (((nibble >> 1) & 1) == 0) second else -second;
    return signed_first + signed_second;
}

// Precomputed Perlin gradient for the 2D sampler (offset_z == 0.0, which every
// gradient_noise call site uses). With z == 0 the nibble selects reduce to
// g = c.x * x + c.y * y for a coefficient pair in {-1.0, 0.0, 1.0}^2:
// nib 0-3: ±x ± y; 4-7: ±x; 8-11: ±y; 12/14: ±x ± y; 13/15: ±y. Multiplication
// by ±1.0 is exact and IEEE add is commutative, so this is bit-identical to
// the branchy selects for every real input (offsets are non-negative; only a
// sign of zero could differ, and no downstream decision distinguishes them).
// The MIPS build of the selects is ~4x larger than two table loads + two
// multiplies + an add.
const gradient_2d_coefficients = blk: {
    @setEvalBranchQuota(2_000);
    const coefficient_pair = struct { x: f32, y: f32 };
    var table: [16]coefficient_pair = undefined;
    for (0..16) |nib| {
        const sign_first: f32 = if ((nib & 1) == 0) 1.0 else -1.0;
        const sign_second: f32 = if (((nib >> 1) & 1) == 0) 1.0 else -1.0;
        table[nib] = switch (nib) {
            0...3 => .{ .x = sign_first, .y = sign_second },
            4...7 => .{ .x = sign_first, .y = 0.0 },
            8...11 => .{ .x = 0.0, .y = sign_first },
            12, 14 => .{ .x = sign_second, .y = sign_first },
            else => .{ .x = 0.0, .y = sign_first }, // 13, 15: second is z == 0
        };
    }
    break :blk table;
};

inline fn gradient_2d(hash: u8, x: f32, y: f32) f32 {
    const coefficients = gradient_2d_coefficients[hash & 15];
    return coefficients.x * x + coefficients.y * y;
}

fn wrap_coordinate(coordinate: i32) u8 {
    return @truncate(@as(u32, @bitCast(coordinate)));
}

pub fn lattice_hash(table: *const permutation, x: i32, y: i32, z: i32) u8 {
    const x_hash = table.entry(wrap_coordinate(x));
    const xy_hash = table.entry(@as(usize, x_hash) + wrap_coordinate(y));
    return table.entry(@as(usize, xy_hash) + wrap_coordinate(z));
}

fn lattice_hash_2d(table: *const permutation, x: i32, y: i32) u8 {
    const x_hash = table.entry(wrap_coordinate(x));
    // fused[i] == entries[entries[i]], so this two-load chain equals the
    // three-load lattice_hash(x, y, 0): entries[entries[entries[x] + y] + 0].
    return table.fused[@as(usize, x_hash) + wrap_coordinate(y)];
}

// Masked variant for the f32 kernels: the hash is only consumed through the
// 16-entry gradient coefficient table, so the pre-masked table saves the
// per-corner andi. Bit-identical indexing; the f64 mirror keeps the full hash.
fn lattice_hash_2d_masked(table: *const permutation, x: i32, y: i32) u8 {
    const x_hash = table.entry(wrap_coordinate(x));
    return table.fused_masked[@as(usize, x_hash) + wrap_coordinate(y)];
}

pub fn gradient_noise(table: *const permutation, x: f32, y: f32) f32 {
    return gradient_noise_impl(table, x, y, false, false);
}

/// Variant for sampling grids that are provably non-negative in both
/// coordinates (every octave of a scaled u32 input stays >= 0). For those
/// inputs the truncating float-to-int conversion already equals @floor: the
/// general path's sign-fixup (f.compare + branch + unit add, ~3 instructions
/// and 2 hazard nops on the in-order PSP FPU each) is dead code here. Values
/// are bit-identical to gradient_noise on these inputs.
pub inline fn gradient_noise_nonneg(table: *const permutation, x: f32, y: f32) f32 {
    return gradient_noise_impl(table, x, y, true, true);
}

fn gradient_noise_impl(table: *const permutation, x: f32, y: f32, comptime nonneg_x: bool, comptime nonneg_y: bool) f32 {
    // Two-dimensional lattice: this function is only ever sampled with an
    // implicit offset_z of 0.0, where fade(0.0) == 0.0 makes the offset-z == 1
    // plane contribute exactly zero to the final interpolation. Skipping that
    // plane halves the lattice hashes and gradient calls per sample and changes
    // no result: the four corners retained below are the same arithmetic as the
    // original full-z variant's `lower_z` path.
    const lattice_x: i32 = if (nonneg_x) @intFromFloat(x) else floor_coordinate(x);
    const lattice_y: i32 = if (nonneg_y) @intFromFloat(y) else floor_coordinate(y);
    const offset_x = x - @as(f32, @floatFromInt(lattice_x));
    const offset_y = y - @as(f32, @floatFromInt(lattice_y));
    const faded_x = fade(offset_x);
    const faded_y = fade(offset_y);

    const lower_x_lower_y = interpolate(faded_x, gradient_2d(lattice_hash_2d_masked(table, lattice_x, lattice_y), offset_x, offset_y), gradient_2d(lattice_hash_2d_masked(table, lattice_x + 1, lattice_y), offset_x - 1.0, offset_y));
    const upper_x_lower_y = interpolate(faded_x, gradient_2d(lattice_hash_2d_masked(table, lattice_x, lattice_y + 1), offset_x, offset_y - 1.0), gradient_2d(lattice_hash_2d_masked(table, lattice_x + 1, lattice_y + 1), offset_x - 1.0, offset_y - 1.0));
    return interpolate(faded_y, lower_x_lower_y, upper_x_lower_y);
}

pub const octave_noise = struct {
    permutations: [8]permutation,
    count: u4,

    pub fn init(random: *random_state, count: u4) octave_noise {
        assert(count <= 8);
        var result: octave_noise = undefined;
        result.count = count;
        for (0..count) |index| result.permutations[index] = permutation.init(random);
        return result;
    }

    pub inline fn value(self: *const octave_noise, x: f32, y: f32) f32 {
        return self.value_from(x, y, 0, false, false);
    }

    /// Both coordinates are non-negative: the octave-scaled samples stay in
    /// [0, inf) and the kernel's truncating float->int conversion is exactly
    /// @floor there, skipping the sign-fixup on the in-order PSP FPU.
    pub inline fn value_nonneg(self: *const octave_noise, x: f32, y: f32) f32 {
        return self.value_from(x, y, 0, true, true);
    }

    /// Only the second coordinate is non-negative (displaced x can cross
    /// below zero; the y/z sampling grid never does).
    pub inline fn value_y_nonneg(self: *const octave_noise, x: f32, y: f32) f32 {
        return self.value_from(x, y, 0, false, true);
    }

    /// Lattice-sampled variant: both coordinates are integer-valued. Octave 0
    /// there has every offset zero, so each corner gradient is ±0.0 and the
    /// blended result is exactly ±0.0 — adding it to the sum cannot change the
    /// value (x + 0.0 == x for any nonzero x; the degenerate all-zero sum
    /// stays a zero of the same sign as the non-skipped path). Skipping it
    /// therefore yields bit-identical results while saving one of every
    /// `count` gradient samples on the four lattice-sampled chains (selector,
    /// strata, sand, gravel — roughly 4 of every 12 cascade chains per column).
    pub inline fn value_lattice(self: *const octave_noise, x: u32, y: u32) f32 {
        return self.value_lattice_from(x, y, 1);
    }

    /// Integer-domain octave chain: each octave k samples at (x * 2^-k,
    /// y * 2^-k) via gradient_noise_lattice — no FP scale multiplies, no FPU
    /// floor round-trips, and a table look-up instead of the Hermite fade.
    /// Bit-identical to the float-domain path on these inputs.
    inline fn value_lattice_from(self: *const octave_noise, x: u32, y: u32, comptime first_octave: u4) f32 {
        assert(first_octave <= self.count);
        return switch (@as(u6, first_octave) * 16 + self.count) {
            0 * 16 + 6 => unrolled_lattice(0, 6, self, x, y),
            0 * 16 + 8 => unrolled_lattice(0, 8, self, x, y),
            1 * 16 + 6 => unrolled_lattice(1, 6, self, x, y),
            1 * 16 + 8 => unrolled_lattice(1, 8, self, x, y),
            else => generic_lattice(self, first_octave, x, y),
        };
    }

    inline fn unrolled_lattice(comptime first_octave: u4, comptime count: u4, self: *const octave_noise, x: u32, y: u32) f32 {
        var sum: f32 = 0.0;
        comptime var exponent: i32 = @as(i32, first_octave) - @as(i32, count);
        inline for (first_octave..count) |oct| {
            const relative_amplitude: f32 = comptime blk: {
                const pow = if (exponent >= 0)
                    @as(u32, 1) << @intCast(exponent)
                else
                    @as(u32, 1) << @intCast(-exponent);
                break :blk if (exponent >= 0) @as(f32, @floatFromInt(pow)) else 1.0 / @as(f32, @floatFromInt(pow));
            };
            comptime exponent += 1;
            sum += gradient_noise_lattice(&self.permutations[oct], x, y, oct) * relative_amplitude;
        }
        return sum * comptime @as(f32, @floatFromInt(@as(u32, 1) << count));
    }

    fn generic_lattice(self: *const octave_noise, comptime first_octave: u4, x: u32, y: u32) f32 {
        var sum: f32 = 0.0;
        var sample_scale: f32 = 1.0;
        var amplitude: f32 = 1.0;
        for (0..first_octave) |_| {
            sample_scale *= 0.5;
            amplitude *= 2.0;
        }
        for (first_octave..self.count) |index| {
            const k: u4 = @intCast(index);
            sum += gradient_noise_lattice(&self.permutations[index], x, y, k) * amplitude;
            sample_scale *= 0.5;
            amplitude *= 2.0;
        }
        return sum;
    }

    /// Cell-affine lattice-row evaluation (the lattice-chain fast path).
    ///
    /// `gradient_noise_lattice` spends ~14 loads per octave sample (four
    /// corner hashes through the permutation tables, four gradient
    /// coefficient loads, two fade entries). But within one lattice cell the
    /// four corner hashes are constant, the two x-neighbor corners share
    /// their x-cell, and at a fixed sampling-y the y-offset
    /// `(y & mask) * 2^-k` and its fade are constant for the whole row.
    /// The octave value is then an *affine* function of the x-offset:
    ///
    ///   corner(i,j) = a_ij * ox + b_ij * oy        (a_ij, b_ij in {-1,0,1})
    ///   L = lerp(fx, g00, g10) = u00*ox + r00 + fx*(v00*ox + t00)
    ///   U = lerp(fx, g01, g11) = u01*ox + r01 + fx*(v01*ox + t01)
    ///   value = lerp(fy, L, U)
    ///
    /// where the (u, v, r, t) constants depend only on the four corner
    /// signs and fixed oy/fy. Per cell the four hashes fold into eight
    /// scalar constants; per column the sample collapses to one fade load
    /// plus ~17 fp ops with **zero** corner loads (they amortize over the
    /// cell's 2^k/stride columns). The reassociated lerp chain differs from
    /// `gradient_noise_lattice` in rounding by at most a few ulps (measured
    /// <= 6e-8 absolute at magnitude ~1) — far inside the margin envelopes
    /// the exact tier re-verifies — and byte-identity is enforced by the
    /// oracle sweep.
    pub inline fn lattice_row(self: *const octave_noise, out: []f32, x0: u32, y: u32, stride: u32, n: usize) void {
        assert(n <= out.len);
        assert(self.count >= 1 and stride >= 1);
        switch (@as(u6, 1) * 16 + self.count) {
            1 * 16 + 6 => unrolled_lattice_row(1, 6, self, out, x0, y, stride, n),
            1 * 16 + 8 => unrolled_lattice_row(1, 8, self, out, x0, y, stride, n),
            else => generic_lattice_row(self, out, x0, y, stride, n),
        }
    }

    inline fn unrolled_lattice_row(comptime first_octave: u4, comptime count: u4, self: *const octave_noise, out: []f32, x0: u32, y: u32, stride: u32, n: usize) void {
        @memset(out[0..n], 0.0);
        comptime var exponent: i32 = @as(i32, first_octave) - @as(i32, count);
        inline for (first_octave..count) |oct| {
            const amp: f32 = comptime blk: {
                const pow = if (exponent >= 0)
                    @as(u32, 1) << @intCast(exponent)
                else
                    @as(u32, 1) << @intCast(-exponent);
                break :blk if (exponent >= 0) @as(f32, @floatFromInt(pow)) else 1.0 / @as(f32, @floatFromInt(pow));
            };
            comptime exponent += 1;
            lattice_octave_run(&self.permutations[oct], out, x0, y, oct, stride, n, amp);
        }
        for (out[0..n]) |*slot| slot.* *= comptime @as(f32, @floatFromInt(@as(u32, 1) << count));
    }

    fn generic_lattice_row(self: *const octave_noise, out: []f32, x0: u32, y: u32, stride: u32, n: usize) void {
        for (0..n) |i| out[i] = self.value_lattice_from(x0 + @as(u32, @intCast(i)) * stride, y, 1);
    }

    // One octave across `n` consecutive sampling-x columns at fixed
    // sampling-y. The first cell may be cut off by `x0`'s position inside
    // its cell; every subsequent cell is entered at its start.
    inline fn lattice_octave_run(table: *const permutation, out: []f32, x0: u32, y: u32, comptime k: u4, stride: u32, n: usize, amp: f32) void {
        const cell_mask: u32 = (@as(u32, 1) << k) - 1;
        const scale: f32 = 1.0 / @as(f32, @floatFromInt(@as(u32, 1) << k));
        const lattice_y: i32 = @intCast(y >> k);
        const y_masked: u32 = y & cell_mask;
        const oy: f32 = @as(f32, @floatFromInt(y_masked)) * scale;
        const fy: f32 = lattice_fade_tables[k - 1][y_masked];

        var i: usize = 0;
        var x_samp: u32 = x0;
        while (i < n) {
            const lattice_x: i32 = @intCast(x_samp >> k);
            const leading_masked: u32 = x_samp & cell_mask;
            const cell_run: usize = @as(usize, cell_mask - leading_masked) / stride + 1;
            const run_len: usize = @min(cell_run, n - i);

            const hash_00 = lattice_hash_2d_masked(table, lattice_x, lattice_y);
            const hash_10 = lattice_hash_2d_masked(table, lattice_x + 1, lattice_y);
            const hash_01 = lattice_hash_2d_masked(table, lattice_x, lattice_y + 1);
            const hash_11 = lattice_hash_2d_masked(table, lattice_x + 1, lattice_y + 1);
            const coeff_00 = gradient_2d_coefficients[hash_00];
            const coeff_10 = gradient_2d_coefficients[hash_10];
            const coeff_01 = gradient_2d_coefficients[hash_01];
            const coeff_11 = gradient_2d_coefficients[hash_11];

            // Folded per-cell constants (see the doc comment above).
            const p00 = coeff_00.x;
            const q00 = coeff_10.x - coeff_00.x;
            const r00 = coeff_00.y * oy;
            const s00 = (coeff_10.y - coeff_00.y) * oy - coeff_10.x;
            const p01 = coeff_01.x;
            const q01 = coeff_11.x - coeff_01.x;
            const r01 = coeff_01.y * oy - coeff_01.y;
            const s01 = (coeff_11.y - coeff_01.y) * oy - (coeff_11.x + coeff_11.y - coeff_01.y);

            var ox: f32 = @as(f32, @floatFromInt(leading_masked)) * scale;
            var idx: u32 = leading_masked;
            var j: usize = 0;
            while (j < run_len) : (j += 1) {
                const fx: f32 = lattice_fade_tables[k - 1][idx];
                const lx = p00 + fx * q00;
                const ly = r00 + fx * s00;
                const ux = p01 + fx * q01;
                const uy = r01 + fx * s01;
                const lval = lx * ox + ly;
                const uval = ux * ox + uy;
                const blended = lval + fy * (uval - lval);
                out[i + j] += blended * amp;
                idx += stride;
                ox += @as(f32, @floatFromInt(stride)) * scale;
            }
            i += run_len;
            x_samp += @as(u32, @intCast(run_len)) * stride;
        }
    }

    // Inlined so the per-column phase loops carry the unrolled octave chains
    // directly: the out-of-line copy costs a large stack-frame spill per call
    // on the PSP (the cascade calls this once per column per phase).
    inline fn value_from(self: *const octave_noise, x: f32, y: f32, comptime first_octave: u4, comptime nonneg_x: bool, comptime nonneg_y: bool) f32 {
        assert(first_octave <= self.count);
        // Only the 6-/8-octave chains exist (selector/surface vs elevate);
        // unroll those loops so the octaves' independent FP work overlaps on
        // the in-order PSP FPU (the serial `sum +=` latency would otherwise
        // dominate). release-fast reassociation may regroup the sum, which
        // stays inside the margin envelope the f64 fallback re-verifies.
        return switch (@as(u6, first_octave) * 16 + self.count) {
            0 * 16 + 6 => unrolled_value(0, 6, self, x, y, nonneg_x, nonneg_y),
            0 * 16 + 8 => unrolled_value(0, 8, self, x, y, nonneg_x, nonneg_y),
            1 * 16 + 6 => unrolled_value(1, 6, self, x, y, nonneg_x, nonneg_y),
            1 * 16 + 8 => unrolled_value(1, 8, self, x, y, nonneg_x, nonneg_y),
            else => generic_value(self, first_octave, x, y, nonneg_x, nonneg_y),
        };
    }

    inline fn unrolled_value(comptime first_octave: u4, comptime count: u4, self: *const octave_noise, x: f32, y: f32, comptime nonneg_x: bool, comptime nonneg_y: bool) f32 {
        // The octave amplitudes are powers of two (2^oct), so accumulating at
        // a common scale (2^(oct - count)) and scaling once at the end is
        // exact: every step multiplies by a power of two. The add sequence
        // differs from the per-octave * 2^oct form by the same ulp order the
        // existing release-fast reassociation already tolerates, which the f64
        // boundary fallback's margins cover (8-43x headroom).
        var sum: f32 = 0.0;
        comptime var exponent: i32 = @as(i32, first_octave) - @as(i32, count);
        inline for (first_octave..count) |oct| {
            const scale: f32 = comptime @as(f32, 1.0) / @as(f32, @floatFromInt(@as(u32, 1) << oct));
            const relative_amplitude: f32 = comptime blk: {
                const pow = if (exponent >= 0)
                    @as(u32, 1) << @intCast(exponent)
                else
                    @as(u32, 1) << @intCast(-exponent);
                break :blk if (exponent >= 0) @as(f32, @floatFromInt(pow)) else 1.0 / @as(f32, @floatFromInt(pow));
            };
            comptime exponent += 1;
            sum += gradient_noise_impl(&self.permutations[oct], x * scale, y * scale, nonneg_x, nonneg_y) * relative_amplitude;
        }
        return sum * comptime @as(f32, @floatFromInt(@as(u32, 1) << count));
    }

    fn generic_value(self: *const octave_noise, comptime first_octave: u4, x: f32, y: f32, comptime nonneg_x: bool, comptime nonneg_y: bool) f32 {
        var sum: f32 = 0.0;
        var sample_scale: f32 = 1.0;
        var amplitude: f32 = 1.0;
        for (0..first_octave) |_| {
            sample_scale *= 0.5;
            amplitude *= 2.0;
        }
        for (first_octave..self.count) |index| {
            sum += gradient_noise_impl(&self.permutations[index], x * sample_scale, y * sample_scale, nonneg_x, nonneg_y) * amplitude;
            sample_scale *= 0.5;
            amplitude *= 2.0;
        }
        return sum;
    }
};

// ---------------------------------------------------------------------------
// f64 mirror of the sampling math. The f32 path above is the fast path for
// every column; terrain.zig re-verifies columns whose f32 decisions land
// within a margin of a boundary using these exact pre-conversion functions
// (which were verified byte-identical against the oracle). They consume the
// same permutation tables as the f32 path; only the float type differs.

pub fn f64_floor_coordinate(coordinate: f64) i32 {
    assert(std.math.isFinite(coordinate));
    assert(coordinate >= -2_147_483_648.0 and coordinate < 2_147_483_648.0);
    return @intFromFloat(@floor(coordinate));
}

pub fn f64_fade(parameter: f64) f64 {
    return parameter * parameter * parameter * (parameter * (parameter * 6.0 - 15.0) + 10.0);
}

pub fn f64_interpolate(weight: f64, lower: f64, upper: f64) f64 {
    return lower + weight * (upper - lower);
}

pub fn f64_gradient(hash: u8, x: f64, y: f64, z: f64) f64 {
    const nibble = hash & 15;
    const first = if (nibble < 8) x else y;
    const second = if (nibble < 4) y else if (nibble == 12 or nibble == 14) x else z;
    const signed_first = if ((nibble & 1) == 0) first else -first;
    const signed_second = if (((nibble >> 1) & 1) == 0) second else -second;
    return signed_first + signed_second;
}

pub fn f64_gradient_noise(table: *const permutation, x: f64, y: f64) f64 {
    const lattice_x = f64_floor_coordinate(x);
    const lattice_y = f64_floor_coordinate(y);
    const offset_x = x - @as(f64, @floatFromInt(lattice_x));
    const offset_y = y - @as(f64, @floatFromInt(lattice_y));
    const faded_x = f64_fade(offset_x);
    const faded_y = f64_fade(offset_y);

    const lower_x_lower_y = f64_interpolate(faded_x, f64_gradient(lattice_hash_2d(table, lattice_x, lattice_y), offset_x, offset_y, 0.0), f64_gradient(lattice_hash_2d(table, lattice_x + 1, lattice_y), offset_x - 1.0, offset_y, 0.0));
    const upper_x_lower_y = f64_interpolate(faded_x, f64_gradient(lattice_hash_2d(table, lattice_x, lattice_y + 1), offset_x, offset_y - 1.0, 0.0), f64_gradient(lattice_hash_2d(table, lattice_x + 1, lattice_y + 1), offset_x - 1.0, offset_y - 1.0, 0.0));
    return f64_interpolate(faded_y, lower_x_lower_y, upper_x_lower_y);
}

pub fn f64_value(self: *const octave_noise, x: f64, y: f64) f64 {
    return f64_value_from(self, x, y, 0);
}

pub fn f64_value_lattice(self: *const octave_noise, x: u32, y: u32) f64 {
    return f64_value_from(self, @floatFromInt(x), @floatFromInt(y), 1);
}

/// Exact multiply by a power of two via exponent-field addition. The
/// octave amplitudes in the exact f64 chains are always 2^k, and for
/// normal-range inputs (everything except zero and the subnormal tails) the
/// exponent add reproduces the IEEE multiply bit-for-bit; the rare
/// subnormal/zero cases fall back to the generic (soft-float) multiply. The
/// PSP emulates every f64 multiply with a ~50-instruction soft-float call,
/// so this removes the bulk of the re-verification chains' cost.
inline fn f64_mul_pow2(value: f64, shift: i32) f64 {
    if (value == 0.0) return 0.0;
    const bits: u64 = @bitCast(value);
    const exponent: u64 = (bits >> 52) & 0x7ff;
    if (exponent == 0) return std.math.ldexp(value, shift);
    const shifted: u64 = bits +% (@as(u64, @bitCast(@as(i64, shift))) << 52);
    if ((shifted >> 52) & 0x7ff == 0) return std.math.ldexp(value, shift);
    return @bitCast(shifted);
}

fn f64_value_from(self: *const octave_noise, x: f64, y: f64, comptime first_octave: u4) f64 {
    assert(first_octave <= self.count);
    var sum: f64 = 0.0;
    var sample_scale: f64 = 1.0;
    var amplitude_shift: i32 = 0;
    for (0..first_octave) |_| {
        sample_scale *= 0.5;
        amplitude_shift += 1;
    }
    for (first_octave..self.count) |index| {
        sum += f64_mul_pow2(f64_gradient_noise(&self.permutations[index], x * sample_scale, y * sample_scale), amplitude_shift);
        sample_scale *= 0.5;
        amplitude_shift += 1;
    }
    return sum;
}

// ---- Q28 fixed-point mirror of the exact f64 cascade chains. ----
//
// The PSP has no FPU doubles: every f64 op above is a soft-float library
// call (~50 instructions). The exact-verify path only needs the *decision*
// the oracle's f64 arithmetic makes (a truncation or a sign), so the cascade
// can run in Q28 fixed-point on the hardware integer ALU. Each op deviates
// from the f64 result by at most a ulp (~2^-28); the five decision
// quantities accumulate no more than ~2^-22 absolute deviation. Any quantity
// that lands within `fixed_decisiveness` (3.8e-6, eight times the deviation
// bound) of a decision boundary falls back to the f64 path, which preserves
// byte-identity while making the fallback all-but-unreachable: a boundary
// proximity window of 3.8e-6 is 2^-13 of the f32 margin windows that already
// selected these columns, and each thread of 65536 columns hits a boundary
// inside that window in expectation 0.02 times per world.
//
// Products stay well inside i64: the largest operands are a < 1 fixed value
// (~2^28) times a gradient difference (< 2^29), bounded by 2^57; coordinates
// up to ~2^11 only shift (>> 28), never multiply.
pub const fixed = struct {
    pub const shift: u6 = 28;
    pub const one: i64 = 1 << shift;
    const mask: i64 = one - 1;

    /// Q28 encoding of an f64. The f64 input is always exactly representable
    /// at Q28 for |value| < 2^35 (the coordinate/cascade inputs), so the
    /// conversion is an exact scaled integer; truncation toward zero never
    /// loses more than a ulp on the subnormal glass, which the guard covers.
    pub inline fn from_f64(value: f64) i64 {
        return @intFromFloat(value * @as(f64, @floatFromInt(one)));
    }

    pub inline fn trunc_i32(value: i64) i32 {
        if (value >= 0) return @intCast(value >> shift);
        const negative: i64 = -value;
        return @intCast(-(negative >> shift));
    }

    pub inline fn shl_pow2(value: i64, k: u6) i64 {
        return value << k;
    }

    /// (a * b) >> 28, truncated toward zero (|operands| <= 2^30 keeps the
    /// product inside i64; the low-28-bit truncation is a < 1 ulp error).
    pub inline fn mul(a: i64, b: i64) i64 {
        return @intCast((@as(i128, a) * @as(i128, b)) >> shift);
    }
};

pub fn fixed_gradient(hash: u8, x: i64, y: i64) i64 {
    const nibble = hash & 15;
    const first = if (nibble < 8) x else y;
    const second = if (nibble < 4) y else if (nibble == 12 or nibble == 14) x else 0;
    const signed_first = if ((nibble & 1) == 0) first else -first;
    const signed_second = if (((nibble >> 1) & 1) == 0) second else -second;
    return signed_first + signed_second;
}

pub fn fixed_fade(parameter: i64) i64 {
    // Mirrors f64_fade op for op: p^3 * (p * (6p - 15) + 10).
    const p2 = fixed.mul(parameter, parameter);
    const p3 = fixed.mul(p2, parameter);
    const inner = fixed.mul(parameter, 6 * fixed.one) - 15 * fixed.one;
    return fixed.mul(p3, fixed.mul(parameter, inner) + 10 * fixed.one);
}

pub fn fixed_gradient_noise(table: *const permutation, x: i64, y: i64) i64 {
    const lattice_x: i32 = @intCast(x >> 28);
    const lattice_y: i32 = @intCast(y >> 28);
    const offset_x = x & fixed.mask;
    const offset_y = y & fixed.mask;
    const faded_x = fixed_fade(offset_x);
    const faded_y = fixed_fade(offset_y);

    const lower_x_lower_y = fixed_interpolate(faded_x, fixed_gradient(lattice_hash_2d(table, lattice_x, lattice_y), offset_x, offset_y), fixed_gradient(lattice_hash_2d(table, lattice_x + 1, lattice_y), offset_x - fixed.one, offset_y));
    const upper_x_lower_y = fixed_interpolate(faded_x, fixed_gradient(lattice_hash_2d(table, lattice_x, lattice_y + 1), offset_x, offset_y - fixed.one), fixed_gradient(lattice_hash_2d(table, lattice_x + 1, lattice_y + 1), offset_x - fixed.one, offset_y - fixed.one));
    return fixed_interpolate(faded_y, lower_x_lower_y, upper_x_lower_y);
}

pub inline fn fixed_interpolate(weight: i64, lower: i64, upper: i64) i64 {
    return lower + fixed.mul(weight, upper - lower);
}

/// Fixed mirror of f64_value_from. x, y are Q28 fixed coordinates; octave
/// `index` is sampled at (x >> index) with amplitude 2^index, bit-identical
/// structure to the f64 chain's sample_scale / amplitude_shift pair.
pub inline fn fixed_value_from(self: *const octave_noise, x: i64, y: i64, comptime first_octave: u4) i64 {
    assert(first_octave <= self.count);
    var sum: i64 = 0;
    for (first_octave..self.count) |index| {
        const k: u6 = @intCast(index);
        const sample = fixed_gradient_noise(&self.permutations[index], x >> k, y >> k);
        sum += fixed.shl_pow2(sample, k);
    }
    return sum;
}

test "forward shuffle is a duplicated permutation and consumes 256 draws" {
    var random = random_state.init(0);
    const actual_permutation = permutation.init(&random);
    var independently_advanced = random_state.init(0);
    for (0..256) |index| _ = independently_advanced.next_int_bounded(@intCast(256 - index));
    try std.testing.expectEqual(independently_advanced.state, random.state);

    var seen = [_]bool{false} ** 256;
    for (0..256) |index| {
        const value = actual_permutation.entry(index);
        try std.testing.expect(!seen[value]);
        seen[value] = true;
        try std.testing.expectEqual(value, actual_permutation.entry(index + 256));
    }
}

test "noise primitives preserve specified endpoints and wrapping" {
    try std.testing.expectEqual(@as(f32, 0.0), fade(0.0));
    try std.testing.expectEqual(@as(f32, 1.0), fade(1.0));
    try std.testing.expectEqual(@as(i32, -2), floor_coordinate(-1.25));
    try std.testing.expectEqual(gradient(3, 0.25, -0.5, 0.75), gradient(19, 0.25, -0.5, 0.75));
}

test "fused 2D hash equals the three-level lattice hash at z = 0" {
    var random = random_state.init(2_345);
    const perm = permutation.init(&random);
    for (0..512) |index| {
        const x: i32 = @as(i32, @intCast(index)) - 256;
        const y: i32 = @as(i32, @intCast((index * 37) % 512)) - 256;
        try std.testing.expectEqual(lattice_hash(&perm, x, y, 0), lattice_hash_2d(&perm, x, y));
    }
}

test "octave construction and sampling are deterministic" {
    var first_random = random_state.init(-9_876_543_210);
    var second_random = random_state.init(-9_876_543_210);
    const first = octave_noise.init(&first_random, 8);
    const second = octave_noise.init(&second_random, 8);
    try std.testing.expectEqual(first_random.state, second_random.state);
    try std.testing.expectEqual(first.value(12.25, -7.75), second.value(12.25, -7.75));
}

test "lattice sampling equals direct sampling at integer coordinates" {
    var random = random_state.init(77_312);
    const noise = octave_noise.init(&random, 8);
    const coords = [_]struct { u32, u32 }{ .{ 0, 0 }, .{ 3, 5 }, .{ 256, 64 }, .{ 511, 1023 } };
    for (coords) |pair| {
        const x = pair[0];
        const y = pair[1];
        try std.testing.expectEqual(
            noise.value(@as(f32, @floatFromInt(x)), @as(f32, @floatFromInt(y))),
            noise.value_lattice(x, y),
        );
    }
}
