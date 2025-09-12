const Util = @import("../../util/util.zig");
const glfw = @import("glfw");
const builtin = @import("builtin");

const Surface = @import("../surface.zig");
const Self = @This();
const API = @import("../api.zig").Graphics;

window: *glfw.Window,
width: c_int,
height: c_int,
active_joystick: c_int,

pub var curr_scroll: f32 = 0;
pub var mouse_delta: [2]f32 = @splat(0);
pub var cursor_x: f64 = 0;
pub var cursor_y: f64 = 0;

fn init(ctx: *anyopaque, width: u32, height: u32, title: [:0]const u8, fullscreen: bool, sync: bool, api: API) !void {
    const self = Util.ctx_to_self(Self, ctx);

    self.active_joystick = 0;

    if (builtin.os.tag == .linux) {
        glfw.initHint(glfw.Platform, glfw.PlatformX11);
    }
    glfw.initHint(glfw.JoystickHatButtons, 1);

    try glfw.init();

    Util.engine_logger.debug("GLFW {s}", .{glfw.getVersionString()});

    if (api == .opengl) {
        glfw.windowHint(glfw.OpenGLProfile, glfw.OpenGLCoreProfile);
        glfw.windowHint(glfw.ContextVersionMajor, 4);
        glfw.windowHint(glfw.ContextVersionMinor, 6);
        Util.engine_logger.debug("Requesting OpenGL Core 4.6!", .{});
    } else if (api == .vulkan) {
        glfw.windowHint(glfw.ClientAPI, glfw.NoAPI);

        if (!glfw.vulkanSupported()) {
            return error.VulkanNotSupported;
        }

        Util.engine_logger.debug("Requesting Vulkan!", .{});
    }

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
    if (api == .opengl) {
        glfw.makeContextCurrent(self.window);
        glfw.swapInterval(@intFromBool(sync));
    }

    // Trigger initial size fetch
    glfw.getFramebufferSize(self.window, &self.width, &self.height);

    // Input
    _ = glfw.updateGamepadMappings(@embedFile("gamecontrollerdb.txt"));
    _ = glfw.setScrollCallback(self.window, scroll_callback);
}

export fn scroll_callback(_: *c_long, _: f64, yoffset: f64) void {
    curr_scroll += @floatCast(yoffset);
}

fn deinit(ctx: *anyopaque) void {
    const self = Util.ctx_to_self(Self, ctx);

    glfw.destroyWindow(self.window);

    Util.allocator().destroy(self);
}

fn update(ctx: *anyopaque) bool {
    const self = Util.ctx_to_self(Self, ctx);
    glfw.pollEvents();
    glfw.getFramebufferSize(self.window, &self.width, &self.height);

    for (0..16) |joystick| {
        if (glfw.joystickPresent(@intCast(joystick))) {
            self.active_joystick = @intCast(joystick);

            break;
        }
    }

    glfw.getCursorPos(self.window, &cursor_x, &cursor_y);
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
