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

/// Initializes the surface with the given parameters.
/// Must be called before any other surface functions.
/// Returns an error if initialization fails.
pub inline fn init(self: *Self, width: u32, height: u32, title: [:0]const u8, fullscreen: bool, sync: bool, api: u8) !void {
    try self.tab.init(self.ptr, width, height, title, fullscreen, sync, api);
}

/// Shuts down the surface and frees all associated resources.
pub inline fn deinit(self: *Self) void {
    self.tab.deinit(self.ptr);
}

/// Updates the surface. Should be called once per frame.
pub inline fn update(self: *Self) bool {
    return self.tab.update(self.ptr);
}

/// Draws the current frame to the surface. Should be called once per frame after update.
pub inline fn draw(self: *Self) void {
    self.tab.draw(self.ptr);
}

/// Gets the current width of the surface in pixels.
pub inline fn get_width(self: *Self) u32 {
    return self.tab.get_width(self.ptr);
}

/// Gets the current height of the surface in pixels.
pub inline fn get_height(self: *Self) u32 {
    return self.tab.get_height(self.ptr);
}

/// Creates a new surface instance appropriate for the current platform.
/// Returns an error if the platform is unsupported or initialization fails.
pub fn make_surface() !Self {
    if (builtin.os.tag == .windows or builtin.os.tag == .linux or builtin.os.tag == .macos) {
        const GLFWSurface = @import("glfw/surface.zig");
        var glfw_surface = try Util.allocator().create(GLFWSurface);
        return glfw_surface.surface();
    } else {
        @compileError("No surface implementation for this platform");
    }
}
