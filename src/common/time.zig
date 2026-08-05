const std = @import("std");

/// Construct a constant millisecond duration without routing through
/// std.Io.Duration.fromMilliseconds. On 3DS/C backend builds that path can
/// lower through an i128 checked-multiply helper with a bad ARM ABI call.
pub fn ms(comptime value: i64) std.Io.Duration {
    return .{ .nanoseconds = comptime @as(i96, value) * std.time.ns_per_ms };
}
