const Util = @import("../../util/util.zig");
const glfw = @import("glfw");
const gl = @import("gl");

const gfx = @import("../gfx.zig");
const GFXAPI = @import("../gfx_api.zig");
const Self = @This();

var procs: gl.ProcTable = undefined;

fn init(ctx: *anyopaque) !void {
    _ = ctx;

    if (!procs.init(glfw.getProcAddress)) @panic("Failed to initialize OpenGL");
    gl.makeProcTableCurrent(&procs);
}

fn deinit(ctx: *anyopaque) void {
    const self = Util.ctx_to_self(Self, ctx);

    gl.makeProcTableCurrent(null);
    procs = undefined;

    Util.allocator().destroy(self);
}

fn set_clear_color(ctx: *anyopaque, r: f32, g: f32, b: f32, a: f32) void {
    _ = ctx;
    gl.ClearColor(r, g, b, a);
}

fn start_frame(ctx: *anyopaque) bool {
    _ = ctx;

    if (gfx.surface.get_width() == 0 or gfx.surface.get_height() == 0) {
        return false;
    }

    gl.Viewport(
        0,
        0,
        @intCast(gfx.surface.get_width()),
        @intCast(gfx.surface.get_height()),
    );
    gl.Clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT);

    return true;
}

fn end_frame(ctx: *anyopaque) void {
    _ = ctx;
    gfx.surface.draw();
}

pub fn gfx_api(self: *Self) GFXAPI {
    return GFXAPI{
        .ptr = self,
        .tab = .{
            .init = init,
            .deinit = deinit,
            .set_clear_color = set_clear_color,
            .start_frame = start_frame,
            .end_frame = end_frame,
        },
    };
}
