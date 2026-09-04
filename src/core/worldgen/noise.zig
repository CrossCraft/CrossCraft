const std = @import("std");
const assert = std.debug.assert;
const builtin = @import("builtin");

const random_state = @import("random.zig");

// Avoid compiler_rt floor/ceil calls on MIPS while preserving finite f32 results.
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
    // Collapses the implicit z=0 hash from three table reads to two.
    fused: [512]u8,
    // The f32 kernel only uses the low four hash bits.
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

// Octaves 1...7 use at most 128 distinct dyadic offsets.
const lattice_fade_tables: [7][128]f32 = blk: {
    @setEvalBranchQuota(16_000);
    var tables: [7][128]f32 = undefined;
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

// Integer coordinates and dyadic scales make this bit-identical to float sampling.
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

// With z=0, each Perlin gradient is a coefficient pair in {-1, 0, 1} squared.
// Precomputing the pairs avoids branchy gradient selection on MIPS.
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
            else => .{ .x = 0.0, .y = sign_first },
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

fn lattice_hash_2d(table: *const permutation, x: i32, y: i32) u8 {
    const x_hash = table.entry(wrap_coordinate(x));
    return table.fused[@as(usize, x_hash) + wrap_coordinate(y)];
}

fn lattice_hash_2d_masked(table: *const permutation, x: i32, y: i32) u8 {
    const x_hash = table.entry(wrap_coordinate(x));
    return table.fused_masked[@as(usize, x_hash) + wrap_coordinate(y)];
}

fn gradient_noise_impl(table: *const permutation, x: f32, y: f32, comptime nonneg_x: bool, comptime nonneg_y: bool) f32 {
    // The omitted z=1 plane contributes zero when the implicit z offset is zero.
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
        assert(count == 6 or count == 8);
        var result: octave_noise = undefined;
        result.count = count;
        for (0..count) |index| result.permutations[index] = permutation.init(random);
        return result;
    }

    pub inline fn value(self: *const octave_noise, x: f32, y: f32) f32 {
        return self.value_from(x, y, false, false);
    }

    // Skips floor sign correction for a non-negative sampling grid.
    pub inline fn value_nonneg(self: *const octave_noise, x: f32, y: f32) f32 {
        return self.value_from(x, y, true, true);
    }

    // Displaced x can be negative; the y/z sampling grid cannot.
    pub inline fn value_y_nonneg(self: *const octave_noise, x: f32, y: f32) f32 {
        return self.value_from(x, y, false, true);
    }

    // Octave zero is always zero at integer coordinates and can be skipped.
    pub inline fn value_lattice(self: *const octave_noise, x: u32, y: u32) f32 {
        return switch (self.count) {
            6 => unrolled_lattice(1, 6, self, x, y),
            8 => unrolled_lattice(1, 8, self, x, y),
            else => unreachable,
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

    // Reuses hashes and y terms across one lattice row. Within a cell:
    //   L = u00*ox + r00 + fx*(v00*ox + t00)
    //   U = u01*ox + r01 + fx*(v01*ox + t01)
    // Reassociation differs by at most 6e-8, inside the verified margins.
    pub inline fn lattice_row(self: *const octave_noise, out: []f32, x0: u32, y: u32, stride: u32, n: usize) void {
        assert(n <= out.len);
        assert(stride >= 1);
        switch (self.count) {
            6 => unrolled_lattice_row(1, 6, self, out, x0, y, stride, n),
            8 => unrolled_lattice_row(1, 8, self, out, x0, y, stride, n),
            else => unreachable,
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

    // Samples an x run at fixed y using the supplied stride.
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

    // Inlining avoids a large PSP stack spill in the per-column loop.
    inline fn value_from(self: *const octave_noise, x: f32, y: f32, comptime nonneg_x: bool, comptime nonneg_y: bool) f32 {
        return switch (self.count) {
            6 => unrolled_value(6, self, x, y, nonneg_x, nonneg_y),
            8 => unrolled_value(8, self, x, y, nonneg_x, nonneg_y),
            else => unreachable,
        };
    }

    inline fn unrolled_value(comptime count: u4, self: *const octave_noise, x: f32, y: f32, comptime nonneg_x: bool, comptime nonneg_y: bool) f32 {
        var sum: f32 = 0.0;
        comptime var exponent: i32 = -@as(i32, count);
        inline for (0..count) |oct| {
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
};

// f64 mirror used to recheck f32 results near a decision boundary.

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

// Exact power-of-two scaling without the PSP's emulated f64 multiply.
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

// Q28 mirror for boundary decisions on targets without hardware f64. Values
// too close to a boundary fall back to the exact f64 path in terrain.zig.
pub const fixed = struct {
    pub const shift: u6 = 28;
    pub const one: i64 = 1 << shift;
    const mask: i64 = one - 1;

    // Worldgen coordinates are exactly representable in Q28.
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

    // Intermediate products require i128 before returning to Q28.
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

// Fixed mirror of f64_value_from for Q28 coordinates.
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

test "noise primitives preserve specified endpoints" {
    try std.testing.expectEqual(@as(f32, 0.0), fade(0.0));
    try std.testing.expectEqual(@as(f32, 1.0), fade(1.0));
    try std.testing.expectEqual(@as(i32, -2), floor_coordinate(-1.25));
}

test "fused 2D hash equals the three-level lattice hash at z = 0" {
    var random = random_state.init(2_345);
    const perm = permutation.init(&random);
    for (0..512) |index| {
        const x: i32 = @as(i32, @intCast(index)) - 256;
        const y: i32 = @as(i32, @intCast((index * 37) % 512)) - 256;
        const x_hash = perm.entry(wrap_coordinate(x));
        const xy_hash = perm.entry(@as(usize, x_hash) + wrap_coordinate(y));
        try std.testing.expectEqual(perm.entry(xy_hash), lattice_hash_2d(&perm, x, y));
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
