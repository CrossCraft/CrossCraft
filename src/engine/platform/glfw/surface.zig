const Util = @import("../../util/util.zig");
const glfw = @import("glfw");
const builtin = @import("builtin");

const Surface = @import("../surface.zig");
const Self = @This();

window: *glfw.Window,
width: c_int,
height: c_int,
opengl: bool,

fn init(ctx: *anyopaque, width: u32, height: u32, title: [:0]const u8, sync: bool, api: u8) !void {
    const self = Util.ctx_to_self(Self, ctx);

    if (builtin.os.tag == .linux) {
        glfw.initHint(glfw.Platform, glfw.PlatformX11);
    }

    try glfw.init();

    if (api == 1) {
        // OpenGL
        glfw.windowHint(glfw.OpenGLProfile, glfw.OpenGLCoreProfile);
        glfw.windowHint(glfw.ContextVersionMajor, 4);
        glfw.windowHint(glfw.ContextVersionMinor, 6);
        self.opengl = true;
    } else {
        // Vulkan
        glfw.windowHint(glfw.ClientAPI, glfw.NoAPI);
        self.opengl = false;
    }

    glfw.windowHint(glfw.Resizable, 0);
    glfw.windowHint(glfw.SRGBCapable, 1);

    self.window = try glfw.createWindow(@intCast(width), @intCast(height), title.ptr, null, null);

    if (api == 1) {
        // OpenGL
        glfw.makeContextCurrent(self.window);
        glfw.swapInterval(@intFromBool(sync));
    }
}

fn deinit(ctx: *anyopaque) void {
    const self = Util.ctx_to_self(Self, ctx);

    glfw.destroyWindow(self.window);

    Util.allocator().destroy(self);
}

fn update(ctx: *anyopaque) bool {
    const self = Util.ctx_to_self(Self, ctx);
    glfw.pollEvents();

    return !glfw.windowShouldClose(self.window);
}

fn draw(ctx: *anyopaque) void {
    const self = Util.ctx_to_self(Self, ctx);

    if (self.opengl) {
        glfw.swapBuffers(self.window);
    }
}

fn get_width(ctx: *anyopaque) u32 {
    const self = Util.ctx_to_self(Self, ctx);

    glfw.getWindowSize(self.window, &self.width, &self.height);
    return @intCast(self.width);
}

fn get_height(ctx: *anyopaque) u32 {
    const self = Util.ctx_to_self(Self, ctx);

    glfw.getWindowSize(self.window, &self.width, &self.height);
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
