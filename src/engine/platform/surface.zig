const builtin = @import("builtin");
const Util = @import("../util/util.zig");
const Self = @This();

ptr: *anyopaque,
tab: *const VTable,

pub const VTable = struct {
    init: *const fn (ctx: *anyopaque, width: u32, height: u32, title: [:0]const u8, fullscreen: bool, sync: bool, api: u8) anyerror!void,
    deinit: *const fn (ctx: *anyopaque) void,

    update: *const fn (ctx: *anyopaque) bool,
    draw: *const fn (ctx: *anyopaque) void,

    get_width: *const fn (ctx: *anyopaque) u32,
    get_height: *const fn (ctx: *anyopaque) u32,
};

pub inline fn init(self: *Self, width: u32, height: u32, title: [:0]const u8, fullscreen: bool, sync: bool, api: u8) !void {
    try self.tab.init(self.ptr, width, height, title, fullscreen, sync, api);
}

pub inline fn deinit(self: *Self) void {
    self.tab.deinit(self.ptr);
}

pub inline fn update(self: *Self) bool {
    return self.tab.update(self.ptr);
}

pub inline fn draw(self: *Self) void {
    self.tab.draw(self.ptr);
}

pub inline fn get_width(self: *Self) u32 {
    return self.tab.get_width(self.ptr);
}

pub inline fn get_height(self: *Self) u32 {
    return self.tab.get_height(self.ptr);
}

pub fn make_surface() !Self {
    if (builtin.os.tag == .windows or builtin.os.tag == .linux or builtin.os.tag == .macos) {
        const GLFWSurface = @import("glfw/surface.zig");
        var glfw_surface = try Util.allocator().create(GLFWSurface);
        return glfw_surface.surface();
    } else {
        @compileError("No surface implementation for this platform");
    }
}
