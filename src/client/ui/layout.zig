/// Shared UI layout primitives used by SpriteBatcher and FontBatcher.
const std = @import("std");

pub const Anchor = enum(u8) {
    top_left,
    top_center,
    top_right,
    middle_left,
    middle_center,
    middle_right,
    bottom_left,
    bottom_center,
    bottom_right,
};

pub const Point = struct { x: i16, y: i16 };

pub fn anchor_point(anchor: Anchor, ex: i16, ey: i16) Point {
    return switch (anchor) {
        .top_left => .{ .x = 0, .y = 0 },
        .top_center => .{ .x = @divTrunc(ex, 2), .y = 0 },
        .top_right => .{ .x = ex, .y = 0 },
        .middle_left => .{ .x = 0, .y = @divTrunc(ey, 2) },
        .middle_center => .{ .x = @divTrunc(ex, 2), .y = @divTrunc(ey, 2) },
        .middle_right => .{ .x = ex, .y = @divTrunc(ey, 2) },
        .bottom_left => .{ .x = 0, .y = ey },
        .bottom_center => .{ .x = @divTrunc(ex, 2), .y = ey },
        .bottom_right => .{ .x = ex, .y = ey },
    };
}

/// Converts a logical X pixel to snorm NDC.
/// Origin (0,0) is the top-left corner of the window.
pub fn logical_to_snorm_x(x: i16, screen_w: u32, scale: u32) i16 {
    const s: i32 = @intCast(scale);
    const sw: i32 = @intCast(screen_w);
    return @intCast(@divTrunc((2 * @as(i32, x) * s - sw) * 32767, sw));
}

/// Converts a logical Y pixel to snorm NDC (Y-flipped for top-left origin).
/// Origin (0,0) is the top-left corner of the window.
pub fn logical_to_snorm_y(y: i16, screen_h: u32, scale: u32) i16 {
    const s: i32 = @intCast(scale);
    const sh: i32 = @intCast(screen_h);
    return @intCast(@divTrunc((sh - 2 * @as(i32, y) * s) * 32767, sh));
}
