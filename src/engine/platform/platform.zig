const std = @import("std");
const builtin = @import("builtin");
pub const gfx = @import("gfx.zig");
pub const audio = @import("audio.zig");
pub const input = @import("glfw/input.zig");

const App = @import("../app.zig");

pub const GraphicsAPI = @import("options").@"build.Gfx";

/// Initializes the platform subsystems: graphics and audio.
pub fn init(width: u32, height: u32, title: [:0]const u8, fullscreen: bool, sync: bool, comptime api: GraphicsAPI) !void {
    try gfx.init(width, height, title, fullscreen, sync, api);
    try audio.init();
}

/// Updates the platform subsystems. This should be called once per frame.
pub fn update() void {
    if (!gfx.surface.update()) {
        // Window should close
        App.running = false;
    }
}

/// Deinitializes the platform subsystems: graphics and audio.
pub fn deinit() void {
    audio.deinit();
    gfx.deinit();
}
