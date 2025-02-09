/// Wraps a Fixed point integer in order to provide common arithmetic functions
pub fn Fixed(comptime bits: u16, comptime frac_bits: u16, comptime signed: bool) type {
    // [0, 64]
    // Not sure if you'd need more bits
    if (bits < 1 or bits > 64) {
        @compileError("Bits must be between 1 and 64");
    }

    if (frac_bits >= bits) {
        @compileError("Fractional bits cannot be more than total bits");
    }

    const IntType = switch (bits) {
        8 => if (signed) i8 else u8,
        16 => if (signed) i16 else u16,
        32 => if (signed) i32 else u32,
        64 => if (signed) i64 else u64,
        else => @compileError("Only supporting 8, 16, 32, or 64 bits currently"),
    };

    return struct {
        const Self = @This();
        value: IntType,

        pub fn from(value: IntType) Self {
            return .{ .value = value << frac_bits };
        }

        pub fn neg(self: Self) Self {
            return .{ .value = -%self.value };
        }

        pub fn add(self: Self, other: Self) Self {
            return .{ .value = self.value +% other.value };
        }

        pub fn sub(self: Self, other: Self) Self {
            return .{ .value = self.value -% other.value };
        }

        pub fn mul(self: Self, other: Self) Self {
            return .{ .value = @truncate(@divTrunc(@as(isize, self.value) * @as(isize, other.value), @as(isize, 1) << frac_bits)) };
        }

        pub fn div(self: Self, other: Self) Self {
            return .{ .value = @divTrunc(self.value << frac_bits, other.value) };
        }

        pub fn int(self: Self) IntType {
            return self.value >> frac_bits;
        }

        pub fn frac(self: Self) IntType {
            return self.sub(Self.from(self.int())).value;
        }

        pub fn toFloat(self: Self) f64 {
            return @as(f64, @floatFromInt(self.value)) / @as(f64, 1 << frac_bits);
        }
    };
}
