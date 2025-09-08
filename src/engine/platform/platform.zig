const std = @import("std");
const builtin = @import("builtin");
pub const gfx = @import("gfx.zig");
pub const audio = @import("audio.zig");
const App = @import("../app.zig");

pub const GraphicsAPI = @import("api.zig").Graphics;

pub fn init(width: u32, height: u32, title: [:0]const u8, sync: bool, comptime api: GraphicsAPI) !void {
    try gfx.init(width, height, title, sync, api);
    try audio.init();
}

pub fn update() void {
    if (!gfx.surface.update()) {
        // Window should close
        App.running = false;
    }
}

pub fn deinit() void {
    audio.deinit();
    gfx.deinit();
}
