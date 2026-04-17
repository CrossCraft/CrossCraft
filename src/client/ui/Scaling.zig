const std = @import("std");
const ae = @import("aether");
const Rendering = ae.Rendering;

pub const ref_width: u32 = 400;
pub const ref_height: u32 = 240;

comptime {
    std.debug.assert(ref_width > 0);
    std.debug.assert(ref_height > 0);
}

/// Returns the current integral scale derived from the active surface dimensions.
pub fn get() u32 {
    return compute(
        Rendering.gfx.surface.get_width(),
        Rendering.gfx.surface.get_height(),
    );
}

pub fn compute(screen_w: u32, screen_h: u32) u32 {
    if (screen_w == 0 or screen_h == 0) return 1;
    const sx = screen_w / ref_width;
    const sy = screen_h / ref_height;
    return @max(1, @min(sx, sy));
}
