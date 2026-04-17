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

/// Logical (UI-space) screen width in integer pixels.
/// Uses ceiling division so bottom/right anchors land inside the last partial
/// logical pixel when `screen_w` is not a multiple of `scale`. This is the
/// canonical value -- match it anywhere you need to place a sprite relative
/// to a screen edge.
pub fn logical_width(screen_w: u32, scale: u32) u32 {
    return (screen_w + scale - 1) / scale;
}

pub fn logical_height(screen_h: u32, scale: u32) u32 {
    return (screen_h + scale - 1) / scale;
}

/// Converts a logical X pixel to snorm NDC.
/// Origin (0,0) is the top-left corner of the window.
pub fn logical_to_snorm_x(x: i16, screen_w: u32, scale: u32) i16 {
    const s: i32 = @intCast(scale);
    const sw: i32 = @intCast(screen_w);
    const v = @divTrunc((2 * @as(i32, x) * s - sw) * 32767, sw);
    return @intCast(std.math.clamp(v, -32767, 32767));
}

/// Converts a logical Y pixel to snorm NDC (Y-flipped for top-left origin).
/// Origin (0,0) is the top-left corner of the window.
pub fn logical_to_snorm_y(y: i16, screen_h: u32, scale: u32) i16 {
    const s: i32 = @intCast(scale);
    const sh: i32 = @intCast(screen_h);
    const v = @divTrunc((sh - 2 * @as(i32, y) * s) * 32767, sh);
    return @intCast(std.math.clamp(v, -32767, 32767));
}
