const std = @import("std");
const assert = std.debug.assert;

const random_state = @import("random.zig");
const noise_module = @import("noise.zig");

pub const air_id: u8 = 0;
pub const stone_id: u8 = 1;
pub const grass_id: u8 = 2;
pub const dirt_id: u8 = 3;
pub const flowing_water_id: u8 = 8;
pub const still_water_id: u8 = 9;
pub const flowing_lava_id: u8 = 10;
pub const still_lava_id: u8 = 11;
pub const sand_id: u8 = 12;
pub const gravel_id: u8 = 13;

pub const world_dimensions = struct {
    width: u32,
    height: u32,
    depth: u32,

    pub fn validate(self: world_dimensions) bool {
        const volume_wide = @as(u128, self.width) * self.height * self.depth;
        return self.width >= 16 and self.height >= 16 and self.depth >= 16 and
            std.math.isPowerOfTwo(self.width) and std.math.isPowerOfTwo(self.height) and
            std.math.isPowerOfTwo(self.depth) and volume_wide <= std.math.maxInt(i32);
    }

    pub fn volume(self: world_dimensions) usize {
        assert(self.validate());
        return @intCast(@as(u64, self.width) * self.height * self.depth);
    }

    pub fn sea_level(self: world_dimensions) u32 {
        return self.height / 2;
    }

    pub fn index(self: world_dimensions, x: u32, y: u32, z: u32) usize {
        assert(x < self.width and y < self.height and z < self.depth);
        // Validated volume bounds every intermediate to 31 bits.
        const result: usize = @intCast(x + self.width * (z + self.depth * y));
        assert(result < self.volume());
        return result;
    }
};

pub const block_position = struct {
    x: u32,
    y: u32,
    z: u32,
};

pub const block_field = struct {
    dimensions: world_dimensions,
    blocks: []u8,

    pub fn init(dimensions: world_dimensions, blocks: []u8) block_field {
        assert(dimensions.validate());
        assert(blocks.len == dimensions.volume());
        return .{ .dimensions = dimensions, .blocks = blocks };
    }

    pub fn at(self: block_field, x: u32, y: u32, z: u32) u8 {
        return self.blocks[self.dimensions.index(x, y, z)];
    }

    pub fn set(self: block_field, x: u32, y: u32, z: u32, material: u8) void {
        assert(material <= 49);
        self.blocks[self.dimensions.index(x, y, z)] = material;
    }

    pub fn inside(self: block_field, location: block_position) bool {
        return location.x < self.dimensions.width and location.y < self.dimensions.height and
            location.z < self.dimensions.depth;
    }
};

// Distance to the nearest integer/truncation boundary.
fn distance_to_integer(value: f32) f32 {
    const floored = noise_module.floor_f32(value);
    return @min(value - floored, noise_module.ceil_f32(value) - value);
}

// These margins are at least 8x the largest observed f32/f64 disagreement.
const margin_selector: f32 = 0x1p-15; // 3.05e-5 (max measured 7.0e-7)
const margin_selected: f32 = 0x1p-9; //  1.95e-3 (max measured 1.2e-4)
const margin_strength: f32 = 0x1p-11; // 4.88e-4 (max measured 5.7e-5)
const margin_parity: f32 = 0x1p-8; //    3.91e-3 (max measured 4.7e-4)
const margin_strata: f32 = 0x1p-15; // 3.05e-5 (max measured 1.15e-6)

fn near_boundary(q: elevation_noise.quantities_32) bool {
    if (@abs(q.selector) < margin_selector) return true;
    if (distance_to_integer(q.selected) < margin_selected) return true;
    if (@abs(q.strength - 2.0) < margin_strength) return true;
    if (q.parity_active and @abs(q.parity_value) < margin_parity) return true;
    return distance_to_integer(q.strata_value) < margin_strata;
}

pub const elevation_noise = struct {
    lower_carrier: noise_module.octave_noise,
    lower_displacement: noise_module.octave_noise,
    upper_carrier: noise_module.octave_noise,
    upper_displacement: noise_module.octave_noise,
    selector: noise_module.octave_noise,
    erosion_carrier: noise_module.octave_noise,
    erosion_displacement: noise_module.octave_noise,
    parity_carrier: noise_module.octave_noise,
    parity_displacement: noise_module.octave_noise,
    strata: noise_module.octave_noise,

    pub fn init(random: *random_state) elevation_noise {
        return .{
            .lower_carrier = noise_module.octave_noise.init(random, 8),
            .lower_displacement = noise_module.octave_noise.init(random, 8),
            .upper_carrier = noise_module.octave_noise.init(random, 8),
            .upper_displacement = noise_module.octave_noise.init(random, 8),
            .selector = noise_module.octave_noise.init(random, 6),
            .erosion_carrier = noise_module.octave_noise.init(random, 8),
            .erosion_displacement = noise_module.octave_noise.init(random, 8),
            .parity_carrier = noise_module.octave_noise.init(random, 8),
            .parity_displacement = noise_module.octave_noise.init(random, 8),
            .strata = noise_module.octave_noise.init(random, 8),
        };
    }

    fn distorted_value(carrier: *const noise_module.octave_noise, displacement: *const noise_module.octave_noise, x: f32, z: f32) f32 {
        // Only displaced x can cross below zero.
        return carrier.value_y_nonneg(x + displacement.value_nonneg(x, z), z);
    }

    fn raising_coordinate(coordinate: u32) f32 {
        return @as(f32, @floatFromInt(coordinate)) * @as(f32, 1.3);
    }

    fn lower_elevation_candidate(self: *const elevation_noise, x: u32, z: u32) f32 {
        return distorted_value(&self.lower_carrier, &self.lower_displacement, raising_coordinate(x), raising_coordinate(z)) * @as(f32, 1.0 / 6.0) - 4.0;
    }

    fn upper_elevation_candidate(self: *const elevation_noise, x: u32, z: u32) f32 {
        return (distorted_value(&self.upper_carrier, &self.upper_displacement, raising_coordinate(x), raising_coordinate(z)) * @as(f32, 1.0 / 5.0) + 10.0) - 4.0;
    }

    // Exact mirror of the cascade input; the raised f32 coordinate is widened.
    fn f64_distorted_value(carrier: *const noise_module.octave_noise, displacement: *const noise_module.octave_noise, x: f64, z: f64) f64 {
        return noise_module.f64_value(carrier, x + noise_module.f64_value(displacement, x, z), z);
    }

    fn f64_raising_coordinate(coordinate: u32) f64 {
        const coordinate_32: f32 = @floatFromInt(coordinate);
        const raised: f32 = coordinate_32 * @as(f32, 1.3);
        return @floatCast(raised);
    }

    fn f64_lower_elevation_candidate(self: *const elevation_noise, x: u32, z: u32) f64 {
        return f64_distorted_value(&self.lower_carrier, &self.lower_displacement, f64_raising_coordinate(x), f64_raising_coordinate(z)) / 6.0 - 4.0;
    }

    fn f64_upper_elevation_candidate(self: *const elevation_noise, x: u32, z: u32) f64 {
        return (f64_distorted_value(&self.upper_carrier, &self.upper_displacement, f64_raising_coordinate(x), f64_raising_coordinate(z)) / 5.0 + 10.0) - 4.0;
    }

    const quantities_32 = struct {
        selected: f32,
        selector: f32,
        strength: f32,
        // Parity is sampled only when erosion needs it.
        parity_value: f32 = 0.0,
        parity_active: bool = false,
        strata_value: f32,
    };

    const verification_needs = struct {
        selector: bool,
        selected: bool,
        strength: bool,
        parity: bool,
        strata: bool,

        fn init(q: quantities_32) verification_needs {
            const selector = @abs(q.selector) < margin_selector;
            const strength = @abs(q.strength - 2.0) < margin_strength;
            return .{
                .selector = selector,
                .selected = selector or distance_to_integer(q.selected) < margin_selected,
                .strength = strength,
                .parity = (q.parity_active and @abs(q.parity_value) < margin_parity) or strength,
                .strata = distance_to_integer(q.strata_value) < margin_strata,
            };
        }
    };

    // Compute each height decision input once for fast or verified evaluation.
    fn quantities32(self: *const elevation_noise, x: u32, z: u32) quantities_32 {
        const lower = self.lower_elevation_candidate(x, z);
        const selector = self.selector.value_lattice(x, z) * @as(f32, 1.0 / 8.0);
        const selected_candidate = if (selector > 0.0) lower else self.upper_elevation_candidate(x, z);
        var selected = @max(lower, selected_candidate) / 2.0;
        if (selected < 0.0) selected *= 0.8;
        assert(std.math.isFinite(selected));
        assert(selected >= -2_147_483_648.0 and selected < 2_147_483_648.0);
        const doubled_x: f32 = @floatFromInt(x * 2);
        const doubled_z: f32 = @floatFromInt(z * 2);
        const strength = distorted_value(&self.erosion_carrier, &self.erosion_displacement, doubled_x, doubled_z) * @as(f32, 1.0 / 8.0);
        const strata_value = self.strata.value_lattice(x, z) * @as(f32, 1.0 / 24.0);
        var result: quantities_32 = .{
            .selected = selected,
            .selector = selector,
            .strength = strength,
            .strata_value = strata_value,
        };
        if (strength > 2.0) {
            result.parity_value = distorted_value(&self.parity_carrier, &self.parity_displacement, doubled_x, doubled_z);
            result.parity_active = true;
        }
        return result;
    }

    fn erosion_result(comptime T: type, raised: i32, strength: T, parity_value: T) i32 {
        if (strength <= 2.0) return raised;

        const parity: i32 = if (parity_value > 0.0) 1 else 0;
        const result = @divTrunc(raised - parity, 2) * 2 + parity;
        assert(@mod(result - parity, 2) == 0);
        return result;
    }

    const elevation_result = struct { dirt: i32, stone: i32 };

    // Recompute only values inside the narrower trust guards.
    fn verified_heights(self: *const elevation_noise, x: u32, z: u32, sea: i32, q: quantities_32) elevation_result {
        const guard_selector: f32 = 5.0e-6;
        const guard_selected: f32 = 5.0e-4;
        const guard_strength: f32 = 4.0e-4;
        const guard_parity: f32 = 1.7e-3;
        const guard_strata: f32 = 7.0e-6;
        const needs = verification_needs.init(q);

        if ((needs.selector and @abs(q.selector) < guard_selector) or
            (needs.selected and distance_to_integer(q.selected) < guard_selected) or
            (needs.strength and @abs(q.strength - 2.0) < guard_strength) or
            (needs.parity and @abs(q.parity_value) < guard_parity) or
            (needs.strata and distance_to_integer(q.strata_value) < guard_strata))
        {
            return self.verified_heights_exact(x, z, sea, q);
        }

        const raised: i32 = @intFromFloat(q.selected);
        const eroded = erosion_result(f32, raised, q.strength, q.parity_value);
        const dirt = eroded + sea;
        const stone = dirt + @as(i32, @intFromFloat(q.strata_value)) - 4;
        return .{ .dirt = dirt, .stone = stone };
    }

    // Q28 avoids soft-float on PSP; ambiguous fixed-point results use exact f64.
    fn verified_heights_exact(self: *const elevation_noise, x: u32, z: u32, sea: i32, q: quantities_32) elevation_result {
        const needs = verification_needs.init(q);

        // Parity can cross zero before the generic Q28 guard detects it.
        if (needs.parity) return self.verified_heights_f64(x, z, sea, q);

        const fixed = noise_module.fixed;
        const guard = fixed.one >> 18; // 3.8e-6, > 8x the fixed-vs-f64 deviation bound

        const x_fixed = fixed.from_f64(@floatFromInt(x));
        const z_fixed = fixed.from_f64(@floatFromInt(z));
        const doubled_x = fixed.from_f64(@floatFromInt(@as(u64, x) * 2));
        const doubled_z = fixed.from_f64(@floatFromInt(@as(u64, z) * 2));

        const selector_p = if (needs.selector)
            @divTrunc(noise_module.fixed_value_from(&self.selector, x_fixed, z_fixed, 1), 8)
        else
            fixed.from_f64(@as(f64, q.selector));

        var selected_p: i64 = undefined;
        if (needs.selected) {
            const lower_p = self.fixed_lower_elevation_candidate(x, z);
            const selected_candidate = if (selector_p > 0) lower_p else self.fixed_upper_elevation_candidate(x, z);
            var selected = @divTrunc(@max(lower_p, selected_candidate), 2);
            if (selected < 0) selected = fixed.mul(selected, @divTrunc(4 * fixed.one, 5));
            selected_p = selected;
        }

        var strength_p: i64 = undefined;
        var parity_p: i64 = undefined;
        if (needs.strength or needs.parity) {
            if (needs.strength) strength_p = @divTrunc(fixed_distorted_value(&self.erosion_carrier, &self.erosion_displacement, doubled_x, doubled_z), 8);
            if (needs.parity) parity_p = fixed_distorted_value(&self.parity_carrier, &self.parity_displacement, doubled_x, doubled_z);
        }

        const strata_p = if (needs.strata)
            @divTrunc(noise_module.fixed_value_from(&self.strata, x_fixed, z_fixed, 1), 24)
        else
            fixed.from_f64(@as(f64, q.strata_value));

        // The guard is over 8x the largest measured Q28/f64 deviation.
        const distance_to_integer_fixed = struct {
            fn distance(value: i64) i64 {
                const frac = value & (fixed.one - 1);
                return @min(frac, fixed.one - frac);
            }
        }.distance;
        if ((needs.selector and @abs(selector_p) < guard) or
            (needs.selected and distance_to_integer_fixed(selected_p) < guard) or
            (needs.strength and @abs(strength_p - 2 * fixed.one) < guard) or
            (needs.parity and @abs(parity_p) < guard) or
            (needs.strata and distance_to_integer_fixed(strata_p) < guard))
        {
            return self.verified_heights_f64(x, z, sea, q);
        }

        const raised: i32 = if (needs.selected) fixed.trunc_i32(selected_p) else @intFromFloat(q.selected);
        const eroded = erosion_result_fixed(raised, if (needs.strength) strength_p else fixed.from_f64(@as(f64, q.strength)), if (needs.parity) parity_p else fixed.from_f64(@as(f64, q.parity_value)));
        const dirt = eroded + sea;
        const stone = dirt + (if (needs.strata) fixed.trunc_i32(strata_p) else @as(i32, @intFromFloat(q.strata_value))) - 4;
        return .{ .dirt = dirt, .stone = stone };
    }

    fn erosion_result_fixed(raised: i32, strength: i64, parity_value: i64) i32 {
        if (strength <= 2 * noise_module.fixed.one) return raised;
        const parity: i32 = if (parity_value > 0) 1 else 0;
        const result = @divTrunc(raised - parity, 2) * 2 + parity;
        assert(@mod(result - parity, 2) == 0);
        return result;
    }

    fn fixed_raise(coordinate: u32) i64 {
        return noise_module.fixed.from_f64(f64_raising_coordinate(coordinate));
    }

    fn fixed_distorted_value(carrier: *const noise_module.octave_noise, displacement: *const noise_module.octave_noise, x: i64, z: i64) i64 {
        return noise_module.fixed_value_from(carrier, x + noise_module.fixed_value_from(displacement, x, z, 0), z, 0);
    }

    fn fixed_lower_elevation_candidate(self: *const elevation_noise, x: u32, z: u32) i64 {
        const raise_x = fixed_raise(x);
        const raise_z = fixed_raise(z);
        return @divTrunc(fixed_distorted_value(&self.lower_carrier, &self.lower_displacement, raise_x, raise_z), 6) - 4 * noise_module.fixed.one;
    }

    fn fixed_upper_elevation_candidate(self: *const elevation_noise, x: u32, z: u32) i64 {
        const raise_x = fixed_raise(x);
        const raise_z = fixed_raise(z);
        return (@divTrunc(fixed_distorted_value(&self.upper_carrier, &self.upper_displacement, raise_x, raise_z), 5) + 10 * noise_module.fixed.one) - 4 * noise_module.fixed.one;
    }

    fn verified_heights_f64(self: *const elevation_noise, x: u32, z: u32, sea: i32, q: quantities_32) elevation_result {
        const needs = verification_needs.init(q);

        const selector_64: f64 = if (needs.selector) noise_module.f64_value_lattice(&self.selector, x, z) / 8.0 else @as(f64, q.selector);

        var selected_64: f64 = undefined;
        if (needs.selected) {
            const lower_64 = self.f64_lower_elevation_candidate(x, z);
            const selected_candidate = if (selector_64 > 0.0) lower_64 else self.f64_upper_elevation_candidate(x, z);
            var selected = @max(lower_64, selected_candidate) / 2.0;
            if (selected < 0.0) selected *= 0.8;
            assert(std.math.isFinite(selected));
            assert(selected >= -2_147_483_648.0 and selected < 2_147_483_648.0);
            selected_64 = selected;
        }

        var strength_64: f64 = undefined;
        var parity_64: f64 = undefined;
        if (needs.strength or needs.parity) {
            const doubled_x: f64 = @floatFromInt(@as(u64, x) * 2);
            const doubled_z: f64 = @floatFromInt(@as(u64, z) * 2);
            if (needs.strength) strength_64 = f64_distorted_value(&self.erosion_carrier, &self.erosion_displacement, doubled_x, doubled_z) / 8.0;
            if (needs.parity) parity_64 = f64_distorted_value(&self.parity_carrier, &self.parity_displacement, doubled_x, doubled_z);
        }

        const strata_64: f64 = if (needs.strata) noise_module.f64_value_lattice(&self.strata, x, z) / 24.0 else @as(f64, q.strata_value);

        const raised: i32 = if (needs.selected) @intFromFloat(selected_64) else @intFromFloat(q.selected);
        const eroded = erosion_result(f64, raised, if (needs.strength) strength_64 else @as(f64, q.strength), if (needs.parity) parity_64 else @as(f64, q.parity_value));
        const dirt = eroded + sea;
        const stone = dirt + @as(i32, @intFromFloat(strata_64)) - 4;
        return .{ .dirt = dirt, .stone = stone };
    }

    pub fn heights(self: *const elevation_noise, dimensions: world_dimensions, x: u32, z: u32) elevation_result {
        const q = self.quantities32(x, z);
        return self.height_from_quantities(dimensions, x, z, q);
    }

    fn height_from_quantities(self: *const elevation_noise, dimensions: world_dimensions, x: u32, z: u32, q: quantities_32) elevation_result {
        const sea: i32 = @intCast(dimensions.sea_level());
        const fallback_needed = near_boundary(q);
        if (!fallback_needed) {
            const raised: i32 = @intFromFloat(q.selected);
            const eroded = erosion_result(f32, raised, q.strength, q.parity_value);
            const dirt = eroded + sea;
            const stone = dirt + @as(i32, @intFromFloat(q.strata_value)) - 4;
            return .{ .dirt = dirt, .stone = stone };
        }
        return self.verified_heights(x, z, sea, q);
    }

    // Evaluate up to 32 columns per noise chain so its tables remain in the PSP cache.
    pub fn heights_chunk(self: *const elevation_noise, dimensions: world_dimensions, start: usize, dirt: []i16, stone: []i16) void {
        const chunk_size: usize = 32;
        const count = dirt.len;
        assert(stone.len == count);
        assert(@as(usize, dimensions.width) >= chunk_size);
        assert(start % chunk_size == 0);
        assert(start + count <= @as(usize, dimensions.width) * dimensions.depth);

        const column_at = struct {
            fn at(column: usize, dims: world_dimensions) struct { x: u32, z: u32 } {
                const z: u32 = @intCast(column / dims.width);
                const x: u32 = @intCast(column % dims.width);
                return .{ .x = x, .z = z };
            }
        }.at;

        var offset: usize = 0;
        while (offset < count) {
            const n = @min(chunk_size, count - offset);
            const base = start + offset;
            const x_row: u32 = @intCast(base % dimensions.width);
            const z_row: u32 = @intCast(base / dimensions.width);
            var lower: [chunk_size]f32 = undefined;
            var lower_dsp: [chunk_size]f32 = undefined;
            var selector: [chunk_size]f32 = undefined;
            var upper: [chunk_size]f32 = undefined;
            var upper_dsp: [chunk_size]f32 = undefined;
            var strength: [chunk_size]f32 = undefined;
            var strength_dsp: [chunk_size]f32 = undefined;
            var parity: [chunk_size]f32 = undefined;
            var parity_dsp: [chunk_size]f32 = undefined;
            var strata_buf: [chunk_size]f32 = undefined;
            var upper_needed: [chunk_size]bool = undefined;
            var parity_active: [chunk_size]bool = undefined;

            for (0..n) |i| {
                lower_dsp[i] = self.lower_displacement.value_nonneg(raising_coordinate(x_row + @as(u32, @intCast(i))), raising_coordinate(z_row));
            }
            for (0..n) |i| {
                lower[i] = self.lower_carrier.value_y_nonneg(raising_coordinate(x_row + @as(u32, @intCast(i))) + lower_dsp[i], raising_coordinate(z_row)) * @as(f32, 1.0 / 6.0) - 4.0;
            }
            self.selector.lattice_row(selector[0..n], x_row, z_row, 1, n);
            for (0..n) |i| {
                selector[i] *= @as(f32, 1.0 / 8.0);
                upper_needed[i] = selector[i] <= 0.0;
                if (upper_needed[i]) upper_dsp[i] = self.upper_displacement.value_nonneg(raising_coordinate(x_row + @as(u32, @intCast(i))), raising_coordinate(z_row));
            }
            for (0..n) |i| {
                if (upper_needed[i])
                    upper[i] = self.upper_carrier.value_y_nonneg(raising_coordinate(x_row + @as(u32, @intCast(i))) + upper_dsp[i], raising_coordinate(z_row)) * @as(f32, 1.0 / 5.0) + 10.0 - 4.0;
            }
            self.erosion_displacement.lattice_row(strength_dsp[0..n], x_row * 2, z_row * 2, 2, n);
            for (0..n) |i| {
                const doubled_x: f32 = @floatFromInt(x_row * 2 + i * 2);
                const doubled_z: f32 = @floatFromInt(z_row * 2);
                strength[i] = self.erosion_carrier.value_y_nonneg(doubled_x + strength_dsp[i], doubled_z) * @as(f32, 1.0 / 8.0);
                parity_active[i] = strength[i] > 2.0;
            }
            // Preserve lazy parity sampling because most columns do not use it.
            for (0..n) |i| {
                if (parity_active[i]) parity_dsp[i] = self.parity_displacement.value_lattice(x_row * 2 + @as(u32, @intCast(i)) * 2, z_row * 2);
            }
            for (0..n) |i| {
                const doubled_x: f32 = @floatFromInt(x_row * 2 + i * 2);
                const doubled_z: f32 = @floatFromInt(z_row * 2);
                if (parity_active[i]) parity[i] = self.parity_carrier.value_y_nonneg(doubled_x + parity_dsp[i], doubled_z);
            }
            self.strata.lattice_row(strata_buf[0..n], x_row, z_row, 1, n);
            for (0..n) |i| strata_buf[i] *= @as(f32, 1.0 / 24.0);

            for (0..n) |i| {
                const at = column_at(start + offset + i, dimensions);
                const selected_candidate = if (upper_needed[i]) upper[i] else lower[i];
                var selected = @max(lower[i], selected_candidate) / 2.0;
                if (selected < 0.0) selected *= 0.8;
                assert(std.math.isFinite(selected));
                assert(selected >= -2_147_483_648.0 and selected < 2_147_483_648.0);
                var q: quantities_32 = .{
                    .selected = selected,
                    .selector = selector[i],
                    .strength = strength[i],
                    .strata_value = strata_buf[i],
                };
                if (parity_active[i]) {
                    q.parity_value = parity[i];
                    q.parity_active = true;
                }
                const result = self.height_from_quantities(dimensions, at.x, at.z, q);
                dirt[offset + i] = @intCast(result.dirt);
                stone[offset + i] = @intCast(result.stone);
            }
            offset += n;
        }
    }
};

pub const elevation_cache = struct {
    dirt: []i16,
    stone: []i16,

    pub fn init(allocator: std.mem.Allocator, elevation: *const elevation_noise, dimensions: world_dimensions) std.mem.Allocator.Error!elevation_cache {
        const count = @as(usize, dimensions.width) * dimensions.depth;
        var self: elevation_cache = .{
            .dirt = try allocator.alloc(i16, count),
            .stone = try allocator.alloc(i16, count),
        };
        errdefer allocator.free(self.dirt);
        errdefer allocator.free(self.stone);
        // Narrow rows use scalar arithmetic to preserve their exact rounding.
        if (dimensions.width < 32) {
            for (0..dimensions.depth) |z| {
                for (0..dimensions.width) |x| {
                    const result = elevation.heights(dimensions, @intCast(x), @intCast(z));
                    const column_index = x + @as(usize, dimensions.width) * z;
                    self.dirt[column_index] = @intCast(result.dirt);
                    self.stone[column_index] = @intCast(result.stone);
                }
            }
            return self;
        }
        var column: usize = 0;
        while (column < count) {
            const n = @min(@as(usize, 32), count - column);
            elevation.heights_chunk(dimensions, column, self.dirt[column..][0..n], self.stone[column..][0..n]);
            column += n;
        }
        return self;
    }

    pub fn deinit(self: *elevation_cache, allocator: std.mem.Allocator) void {
        allocator.free(self.dirt);
        allocator.free(self.stone);
        self.* = undefined;
    }

    fn index(self: *const elevation_cache, dimensions: world_dimensions, x: u32, z: u32) usize {
        _ = self;
        assert(x < dimensions.width and z < dimensions.depth);
        return @as(usize, x) + @as(usize, dimensions.width) * z;
    }

    pub fn dirt_top(self: *const elevation_cache, dimensions: world_dimensions, x: u32, z: u32) i32 {
        return @as(i32, self.dirt[self.index(dimensions, x, z)]);
    }

    pub fn stone_top(self: *const elevation_cache, dimensions: world_dimensions, x: u32, z: u32) i32 {
        return @as(i32, self.stone[self.index(dimensions, x, z)]);
    }

    pub fn surface_height(self: *const elevation_cache, dimensions: world_dimensions, x: u32, z: u32) u32 {
        const raw = @max(self.dirt_top(dimensions, x, z), self.stone_top(dimensions, x, z));
        const lower_clamped = @max(raw, 1);
        const upper: i32 = @intCast(dimensions.height - 2);
        const result: u32 = @intCast(@min(lower_clamped, upper));
        assert(result >= 1 and result <= dimensions.height - 2);
        return result;
    }
};

pub fn soil(field: block_field, elevation: *const elevation_cache) void {
    const dimensions = field.dimensions;
    assert(field.blocks.len == dimensions.volume());
    const pitch: usize = @as(usize, dimensions.width) * dimensions.depth;
    var min_stone_top: i32 = @intCast(dimensions.height);
    var max_material_top: i32 = -1;
    for (0..dimensions.depth) |z_usize| {
        const z: u32 = @intCast(z_usize);
        for (0..dimensions.width) |x_usize| {
            const x: u32 = @intCast(x_usize);
            const stone_top = elevation.stone_top(dimensions, x, z);
            const dirt_top = elevation.dirt_top(dimensions, x, z);
            min_stone_top = @min(min_stone_top, stone_top);
            max_material_top = @max(max_material_top, @max(stone_top, dirt_top));
        }
    }
    // Whole uniform planes are contiguous in the x-major layout.
    @memset(field.blocks[0..pitch], flowing_lava_id);
    var stone_y: i32 = 1;
    while (stone_y <= min_stone_top) : (stone_y += 1) {
        @memset(field.blocks[@as(usize, @intCast(stone_y)) * pitch ..][0..pitch], stone_id);
    }
    // Cache each row's terrain tops while filling its mixed band.
    const start_y = @max(@as(i32, 1), min_stone_top + 1);
    if (start_y <= max_material_top and dimensions.width <= 512) {
        const width_usize: usize = @intCast(dimensions.width);
        var z: usize = 0;
        while (z < dimensions.depth) : (z += 1) {
            var row_stone: [512]i16 = undefined;
            var row_dirt: [512]i16 = undefined;
            var row_min_stone: i32 = std.math.maxInt(i32);
            var row_max_material_top: i32 = -1;
            const z_u32: u32 = @intCast(z);
            var x: usize = 0;
            while (x < width_usize) : (x += 1) {
                const top_stone = elevation.stone_top(dimensions, @intCast(x), z_u32);
                const top_dirt = elevation.dirt_top(dimensions, @intCast(x), z_u32);
                row_stone[x] = @intCast(top_stone);
                row_dirt[x] = @intCast(top_dirt);
                row_min_stone = @min(row_min_stone, top_stone);
                row_max_material_top = @max(row_max_material_top, @max(top_stone, top_dirt));
            }
            const height_i32: i32 = @intCast(dimensions.height);
            var y: i32 = start_y;
            while (y <= max_material_top and y < height_i32) : (y += 1) {
                const y_signed = y;
                const row = field.blocks[@as(usize, @intCast(y)) * pitch + z * width_usize ..][0..width_usize];
                if (y_signed <= row_min_stone) {
                    @memset(row, stone_id);
                    continue;
                }
                if (y_signed > row_max_material_top) continue; // air: zero-filled already
                var i: usize = 0;
                while (i < width_usize) : (i += 1) {
                    if (y_signed <= row_stone[i])
                        row[i] = stone_id
                    else if (y_signed <= row_dirt[i])
                        row[i] = dirt_id;
                }
            }
        }
        return;
    }
    var y: i32 = 1;
    while (y < dimensions.height) : (y += 1) {
        if (y <= min_stone_top) continue; // already memset
        if (y > max_material_top) return;
        const y_signed = y;
        const plane = field.blocks[@as(usize, @intCast(y)) * pitch ..][0..pitch];
        var z: usize = 0;
        while (z < dimensions.depth) : (z += 1) {
            const z_offset = z * dimensions.width;
            var x: usize = 0;
            while (x < dimensions.width) : (x += 1) {
                const idx = z_offset + x;
                if (y_signed <= elevation.stone_top(dimensions, @intCast(x), @intCast(z)))
                    plane[idx] = stone_id
                else if (y_signed <= elevation.dirt_top(dimensions, @intCast(x), @intCast(z)))
                    plane[idx] = dirt_id;
            }
        }
    }
}

// Scanline flood fill stores one work item per x span instead of per cell.
const flood_span = struct { x0: u32, x1: u32, y: u32, z: u32 };

fn flood_scan_row(allocator: std.mem.Allocator, field: block_field, stack: *std.ArrayList(flood_span), y: u32, z: u32, x0: u32, x1: u32, fluid_id: u8, comptime downward: bool) std.mem.Allocator.Error!void {
    const dimensions = field.dimensions;
    var x = x0;
    while (x < x1) : (x += 1) {
        const material = field.at(x, y, z);
        if (material == air_id) {
            var run_start = x;
            while (run_start > 0 and field.at(run_start - 1, y, z) == air_id) run_start -= 1;
            var run_end = x + 1;
            while (run_end < dimensions.width and field.at(run_end, y, z) == air_id) run_end += 1;
            var fill_x = run_start;
            while (fill_x < run_end) : (fill_x += 1) field.set(fill_x, y, z, fluid_id);
            try stack.append(allocator, .{ .x0 = run_start, .x1 = run_end, .y = y, .z = z });
            x = run_end - 1; // the loop's x += 1 lands past the run
        } else if (downward and (fluid_id == flowing_lava_id or fluid_id == still_lava_id) and
            (material == flowing_water_id or material == still_water_id))
        {
            field.set(x, y, z, stone_id);
        }
    }
}

pub fn flood_fill(allocator: std.mem.Allocator, field: block_field, source: block_position, fluid_id: u8) std.mem.Allocator.Error!void {
    assert(fluid_id == still_water_id or fluid_id == still_lava_id or
        fluid_id == flowing_water_id or fluid_id == flowing_lava_id);
    if (!field.inside(source) or field.at(source.x, source.y, source.z) != air_id) return;

    var work: std.ArrayList(flood_span) = .empty;
    defer work.deinit(allocator);

    try work.ensureTotalCapacity(allocator, @min(@as(usize, field.dimensions.width) * field.dimensions.depth / 8, @as(usize, 1 << 14)));

    const dimensions = field.dimensions;
    var x0 = source.x;
    while (x0 > 0 and field.at(x0 - 1, source.y, source.z) == air_id) x0 -= 1;
    var x1 = source.x + 1;
    while (x1 < dimensions.width and field.at(x1, source.y, source.z) == air_id) x1 += 1;
    var fill_x = x0;
    while (fill_x < x1) : (fill_x += 1) field.set(fill_x, source.y, source.z, fluid_id);
    try work.append(allocator, .{ .x0 = x0, .x1 = x1, .y = source.y, .z = source.z });

    while (work.pop()) |span| {
        assert(span.x1 > span.x0);
        assert(field.at(span.x0, span.y, span.z) == fluid_id);
        if (span.z > 0)
            try flood_scan_row(allocator, field, &work, span.y, span.z - 1, span.x0, span.x1, fluid_id, false);
        if (span.z + 1 < dimensions.depth)
            try flood_scan_row(allocator, field, &work, span.y, span.z + 1, span.x0, span.x1, fluid_id, false);
        if (span.y > 0)
            try flood_scan_row(allocator, field, &work, span.y - 1, span.z, span.x0, span.x1, fluid_id, true);
    }
}

// Find the west edge of the air interval connected to a boundary source.
fn boundary_water_submission_entry(field: block_field, source: block_position) ?block_position {
    assert(field.inside(source));

    var entry_x = source.x;
    if (field.at(source.x, source.y, source.z) != air_id) {
        if (source.x == 0 or field.at(source.x - 1, source.y, source.z) != air_id) return null;
        entry_x -= 1;
    }

    while (entry_x > 0 and field.at(entry_x - 1, source.y, source.z) == air_id) {
        entry_x -= 1;
    }

    const entry: block_position = .{ .x = entry_x, .y = source.y, .z = source.z };
    assert(field.inside(entry));
    assert(entry.y == source.y and entry.z == source.z and entry.x <= source.x);
    assert(field.at(entry.x, entry.y, entry.z) == air_id);
    var interval_x = entry.x;
    while (interval_x < source.x) : (interval_x += 1) {
        assert(field.at(interval_x, source.y, source.z) == air_id);
    }
    return entry;
}

fn submit_boundary_water(allocator: std.mem.Allocator, field: block_field, source: block_position) std.mem.Allocator.Error!void {
    if (boundary_water_submission_entry(field, source)) |entry| {
        try flood_fill(allocator, field, entry, still_water_id);
    }
}

pub fn boundary_water_pass(allocator: std.mem.Allocator, field: block_field) std.mem.Allocator.Error!void {
    const dimensions = field.dimensions;
    const y = dimensions.sea_level() - 1;
    for (0..dimensions.width) |x_usize| {
        const x: u32 = @intCast(x_usize);
        try submit_boundary_water(allocator, field, .{ .x = x, .y = y, .z = 0 });
        try submit_boundary_water(allocator, field, .{ .x = x, .y = y, .z = dimensions.depth - 1 });
    }
    for (0..dimensions.depth) |z_usize| {
        const z: u32 = @intCast(z_usize);
        try submit_boundary_water(allocator, field, .{ .x = 0, .y = y, .z = z });
        try submit_boundary_water(allocator, field, .{ .x = dimensions.width - 1, .y = y, .z = z });
    }
}

pub fn inland_water_pass(allocator: std.mem.Allocator, random: *random_state, field: block_field) std.mem.Allocator.Error!void {
    const dimensions = field.dimensions;
    const attempts = @as(u64, dimensions.width) * dimensions.depth / 8000;
    for (0..@as(usize, @intCast(attempts))) |_| {
        const x = random.next_int_bounded(dimensions.width);
        const y_offset = random.next_int_bounded(2);
        const z = random.next_int_bounded(dimensions.depth);
        const y = dimensions.sea_level() - 1 - y_offset;
        try flood_fill(allocator, field, .{ .x = x, .y = y, .z = z }, still_water_id);
    }
}

pub fn lava_pass(allocator: std.mem.Allocator, random: *random_state, field: block_field) std.mem.Allocator.Error!void {
    const dimensions = field.dimensions;
    const attempts = @as(u64, dimensions.width) * dimensions.height * dimensions.depth / 20_000;
    for (0..@as(usize, @intCast(attempts))) |_| {
        const x = random.next_int_bounded(dimensions.width);
        const first = random.next_float();
        const second = random.next_float();
        const z = random.next_int_bounded(dimensions.depth);
        const source_scale: f32 = @floatFromInt(dimensions.sea_level() - 3);
        const product: f32 = first * second;
        const scaled: f32 = product * source_scale;
        assert(scaled >= 0.0);
        const y: u32 = @intFromFloat(scaled);
        assert(y < dimensions.height);
        try flood_fill(allocator, field, .{ .x = x, .y = y, .z = z }, still_lava_id);
    }
}

pub const surface_noise = struct {
    sand: noise_module.octave_noise,
    gravel: noise_module.octave_noise,

    pub fn init(random: *random_state) surface_noise {
        return .{
            .sand = noise_module.octave_noise.init(random, 8),
            .gravel = noise_module.octave_noise.init(random, 8),
        };
    }
};

// Recheck values close enough to a surface threshold to alter later tree draws.
fn surface_exceeds(oct: *const noise_module.octave_noise, x: u32, z: u32, threshold: f32) bool {
    const margin_surface: f32 = 0x1p-11; // 4.88e-4, ~17x observed max 2.8e-5
    const value: f32 = oct.value_lattice(x, z);
    if (@abs(value - threshold) < margin_surface) return noise_module.f64_value_lattice(oct, x, z) > threshold;
    return value > threshold;
}

pub fn surface(field: block_field, elevation: *const elevation_cache, noise: *const surface_noise) void {
    const dimensions = field.dimensions;
    for (0..dimensions.depth) |z_usize| {
        const z: u32 = @intCast(z_usize);
        for (0..dimensions.width) |x_usize| {
            const x: u32 = @intCast(x_usize);
            const top = elevation.surface_height(dimensions, x, z);
            const above = field.at(x, top + 1, z);
            if ((above == flowing_water_id or above == still_water_id) and
                top <= dimensions.sea_level() - 1 and
                surface_exceeds(&noise.gravel, x, z, 12.0))
            {
                field.set(x, top, z, gravel_id);
            } else if (above == air_id) {
                const material: u8 = if (top <= dimensions.sea_level() - 1 and
                    surface_exceeds(&noise.sand, x, z, 8.0))
                    sand_id
                else
                    grass_id;
                field.set(x, top, z, material);
            }
        }
    }
}

fn test_field(dimensions: world_dimensions, material: u8) !block_field {
    const blocks = try std.testing.allocator.alloc(u8, dimensions.volume());
    @memset(blocks, material);
    return .init(dimensions, blocks);
}

test "block indexing follows the oracle x-major layout" {
    const dimensions: world_dimensions = .{ .width = 16, .height = 16, .depth = 32 };
    try std.testing.expectEqual(@as(usize, 3 + 16 * (5 + 32 * 7)), dimensions.index(3, 7, 5));
    try std.testing.expectEqual(@as(usize, 16 * 16 * 32), dimensions.volume());
}

test "largest supervisor-tested dimensions preserve the final index" {
    const dimensions: world_dimensions = .{ .width = 512, .height = 128, .depth = 512 };
    try std.testing.expect(dimensions.validate());
    try std.testing.expectEqual(@as(usize, 512 * 128 * 512), dimensions.volume());
    try std.testing.expectEqual(dimensions.volume() - 1, dimensions.index(511, 127, 511));
}

test "elevation construction consumes the exact octave sequence" {
    var actual_random = random_state.init(44);
    _ = elevation_noise.init(&actual_random);

    var expected_random = random_state.init(44);
    const counts = [_]u4{ 8, 8, 8, 8, 6, 8, 8, 8, 8, 8 };
    for (counts) |count| _ = noise_module.octave_noise.init(&expected_random, count);
    try std.testing.expectEqual(expected_random.state, actual_random.state);
}

test "flood fill moves horizontally and downward but never upward" {
    const dimensions: world_dimensions = .{ .width = 16, .height = 16, .depth = 16 };
    const field = try test_field(dimensions, stone_id);
    defer std.testing.allocator.free(field.blocks);

    field.set(4, 8, 4, air_id);
    field.set(5, 8, 4, air_id);
    field.set(5, 7, 4, air_id);
    field.set(5, 9, 4, air_id);
    try flood_fill(std.testing.allocator, field, .{ .x = 4, .y = 8, .z = 4 }, still_water_id);
    try std.testing.expectEqual(still_water_id, field.at(5, 7, 4));
    try std.testing.expectEqual(air_id, field.at(5, 9, 4));
}

test "lava over water converts the lower cell to stone" {
    const dimensions: world_dimensions = .{ .width = 16, .height = 16, .depth = 16 };
    const field = try test_field(dimensions, stone_id);
    defer std.testing.allocator.free(field.blocks);

    field.set(3, 4, 3, air_id);
    field.set(3, 3, 3, still_water_id);
    try flood_fill(std.testing.allocator, field, .{ .x = 3, .y = 4, .z = 3 }, still_lava_id);
    try std.testing.expectEqual(stone_id, field.at(3, 3, 3));
}

test "boundary water fills only boundary-connected downward air" {
    const dimensions: world_dimensions = .{ .width = 16, .height = 16, .depth = 16 };
    const field = try test_field(dimensions, stone_id);
    defer std.testing.allocator.free(field.blocks);

    const water_y = dimensions.sea_level() - 1;
    field.set(0, water_y, 6, air_id);
    field.set(1, water_y, 6, air_id);
    field.set(1, water_y - 1, 6, air_id);
    field.set(8, water_y, 8, air_id);
    try boundary_water_pass(std.testing.allocator, field);
    try std.testing.expectEqual(still_water_id, field.at(0, water_y, 6));
    try std.testing.expectEqual(still_water_id, field.at(1, water_y - 1, 6));
    try std.testing.expectEqual(air_id, field.at(8, water_y, 8));
}

test "boundary water submits a westward air interval behind a blocked source" {
    const dimensions: world_dimensions = .{ .width = 16, .height = 16, .depth = 16 };
    const field = try test_field(dimensions, stone_id);
    defer std.testing.allocator.free(field.blocks);

    const water_y = dimensions.sea_level() - 1;

    // The right boundary source is blocked, but its westward air interval is valid.
    field.set(dimensions.width - 2, water_y, 6, air_id);
    field.set(dimensions.width - 2, water_y - 1, 6, air_id);

    // A stone break in the interval must prevent a more-western pocket from flooding.
    field.set(dimensions.width - 3, water_y, 9, air_id);
    field.set(dimensions.width - 3, water_y - 1, 9, air_id);

    try boundary_water_pass(std.testing.allocator, field);

    try std.testing.expectEqual(stone_id, field.at(dimensions.width - 1, water_y, 6));
    try std.testing.expectEqual(still_water_id, field.at(dimensions.width - 2, water_y, 6));
    try std.testing.expectEqual(still_water_id, field.at(dimensions.width - 2, water_y - 1, 6));
    try std.testing.expectEqual(air_id, field.at(dimensions.width - 3, water_y, 9));
    try std.testing.expectEqual(air_id, field.at(dimensions.width - 3, water_y - 1, 9));
}

test "fluid passes consume their exact random draws" {
    const dimensions: world_dimensions = .{ .width = 128, .height = 16, .depth = 64 };
    const field = try test_field(dimensions, stone_id);
    defer std.testing.allocator.free(field.blocks);

    var actual = random_state.init(903);
    try inland_water_pass(std.testing.allocator, &actual, field);
    var expected = random_state.init(903);
    for (0..@as(u64, dimensions.width) * dimensions.depth / 8000) |_| {
        _ = expected.next_int_bounded(dimensions.width);
        _ = expected.next_int_bounded(2);
        _ = expected.next_int_bounded(dimensions.depth);
    }
    try std.testing.expectEqual(expected.state, actual.state);

    try lava_pass(std.testing.allocator, &actual, field);
    for (0..@as(u64, dimensions.width) * dimensions.height * dimensions.depth / 20_000) |_| {
        _ = expected.next_int_bounded(dimensions.width);
        _ = expected.next_float();
        _ = expected.next_float();
        _ = expected.next_int_bounded(dimensions.depth);
    }
    try std.testing.expectEqual(expected.state, actual.state);
}

test "surface pass changes only the computed top to a dry surface material" {
    const dimensions: world_dimensions = .{ .width = 16, .height = 16, .depth = 16 };
    const field = try test_field(dimensions, air_id);
    defer std.testing.allocator.free(field.blocks);

    var random = random_state.init(55);
    const elevation = elevation_noise.init(&random);
    const sampled_surface_noise = surface_noise.init(&random);
    var heights = try elevation_cache.init(std.testing.allocator, &elevation, dimensions);
    defer heights.deinit(std.testing.allocator);

    soil(field, &heights);

    const x: u32 = 7;
    const z: u32 = 9;
    const top = heights.surface_height(dimensions, x, z);
    field.set(x, top + 1, z, air_id);
    const preserved = field.at(x, top - 1, z);
    surface(field, &heights, &sampled_surface_noise);
    const material = field.at(x, top, z);
    try std.testing.expect(material == grass_id or material == sand_id);
    try std.testing.expectEqual(preserved, field.at(x, top - 1, z));
}

test "soil preserves stone above a column's dirt top" {
    const dimensions: world_dimensions = .{ .width = 16, .height = 16, .depth = 16 };
    const count = @as(usize, dimensions.width) * dimensions.depth;
    const dirt = try std.testing.allocator.alloc(i16, count);
    defer std.testing.allocator.free(dirt);

    const stone = try std.testing.allocator.alloc(i16, count);
    defer std.testing.allocator.free(stone);

    @memset(dirt, 3);
    @memset(stone, 3);

    const x: u32 = 7;
    const z: u32 = 9;
    const column = @as(usize, x) + @as(usize, dimensions.width) * z;
    stone[column] = 8;

    const field = try test_field(dimensions, air_id);
    defer std.testing.allocator.free(field.blocks);

    const cache: elevation_cache = .{ .dirt = dirt, .stone = stone };
    soil(field, &cache);

    try std.testing.expectEqual(flowing_lava_id, field.at(x, 0, z));
    try std.testing.expectEqual(stone_id, field.at(x, 8, z));
    try std.testing.expectEqual(air_id, field.at(x, 9, z));
}

test "selector exact fallback recomputes the dependent elevation" {
    const dimensions: world_dimensions = .{ .width = 256, .height = 32, .depth = 64 };
    const x: u32 = 38;
    const z: u32 = 18;
    var random = random_state.init(-8538291137141558894);
    const elevation = elevation_noise.init(&random);
    const q = elevation.quantities32(x, z);
    const selector64: f64 = noise_module.f64_value_lattice(&elevation.selector, x, z) / 8.0;
    try std.testing.expect(near_boundary(q));
    try std.testing.expect(q.selector < 0.0);
    try std.testing.expect(selector64 > 0.0);

    const result = elevation.heights(dimensions, x, z);
    try std.testing.expectEqual(@as(i32, 12), result.dirt);
    try std.testing.expectEqual(@as(i32, 7), result.stone);
}

test "parity exact fallback preserves the f64 sign" {
    const dimensions: world_dimensions = .{ .width = 512, .height = 64, .depth = 512 };
    const x: u32 = 85;
    const z: u32 = 363;
    var random = random_state.init(1196335011672411797);
    const elevation = elevation_noise.init(&random);
    const q = elevation.quantities32(x, z);
    try std.testing.expect(near_boundary(q));
    try std.testing.expect(q.parity_active);
    try std.testing.expect(q.parity_value > 0.0);

    const result = elevation.heights(dimensions, x, z);
    try std.testing.expectEqual(@as(i32, 33), result.dirt);
    try std.testing.expectEqual(@as(i32, 29), result.stone);
}
