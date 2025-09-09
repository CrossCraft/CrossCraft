const Util = @import("../../util/util.zig");
const glfw = @import("glfw");
const builtin = @import("builtin");

const Surface = @import("../surface.zig");
const Self = @This();

window: *glfw.Window,
width: c_int,
height: c_int,

fn init(ctx: *anyopaque, width: u32, height: u32, title: [:0]const u8, fullscreen: bool, sync: bool, _: u8) !void {
    const self = Util.ctx_to_self(Self, ctx);

    if (builtin.os.tag == .linux) {
        glfw.initHint(glfw.Platform, glfw.PlatformX11);
    }

    try glfw.init();

    Util.engine_logger.debug("GLFW {s}", .{glfw.getVersionString()});
    glfw.windowHint(glfw.OpenGLProfile, glfw.OpenGLCoreProfile);
    glfw.windowHint(glfw.ContextVersionMajor, 4);
    glfw.windowHint(glfw.ContextVersionMinor, 6);
    Util.engine_logger.debug("Requesting OpenGL Core 4.6!", .{});

    glfw.windowHint(glfw.Resizable, 0);
    glfw.windowHint(glfw.SRGBCapable, 1);

    if (fullscreen) {
        const monitor = glfw.getPrimaryMonitor();
        const mode = glfw.getVideoMode(monitor).?;
        self.window = try glfw.createWindow(mode.width, mode.height, title.ptr, monitor, null);
        self.width = mode.width;
        self.height = mode.height;
    } else {
        self.width = @intCast(width);
        self.height = @intCast(height);

        self.window = try glfw.createWindow(@intCast(width), @intCast(height), title.ptr, null, null);
    }

    // OpenGL
    glfw.makeContextCurrent(self.window);
    glfw.swapInterval(@intFromBool(sync));

    // Trigger initial size fetch
    glfw.getWindowSize(self.window, &self.width, &self.height);
}

fn deinit(ctx: *anyopaque) void {
    const self = Util.ctx_to_self(Self, ctx);

    glfw.destroyWindow(self.window);

    Util.allocator().destroy(self);
}

fn update(ctx: *anyopaque) bool {
    const self = Util.ctx_to_self(Self, ctx);
    glfw.pollEvents();
    glfw.getWindowSize(self.window, &self.width, &self.height);

    return !glfw.windowShouldClose(self.window);
}

fn draw(ctx: *anyopaque) void {
    const self = Util.ctx_to_self(Self, ctx);

    glfw.swapBuffers(self.window);
}

fn get_width(ctx: *anyopaque) u32 {
    const self = Util.ctx_to_self(Self, ctx);
    return @intCast(self.width);
}

fn get_height(ctx: *anyopaque) u32 {
    const self = Util.ctx_to_self(Self, ctx);
    return @intCast(self.height);
}

pub fn surface(self: *Self) Surface {
    return Surface{ .ptr = self, .tab = &.{
        .init = init,
        .deinit = deinit,
        .update = update,
        .draw = draw,
        .get_width = get_width,
        .get_height = get_height,
    } };
}
