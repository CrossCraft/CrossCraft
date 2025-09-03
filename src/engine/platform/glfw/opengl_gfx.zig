const Util = @import("../../util/util.zig");
const glfw = @import("glfw");
const gl = @import("gl");
const zm = @import("zmath");

const shader = @import("shader.zig");
const gfx = @import("../gfx.zig");
const Mesh = @import("../../rendering/mesh.zig");
const GFXAPI = @import("../gfx_api.zig");
const Self = @This();

var procs: gl.ProcTable = undefined;

fn init(ctx: *anyopaque) !void {
    _ = ctx;

    if (!procs.init(glfw.getProcAddress)) @panic("Failed to initialize OpenGL");
    gl.makeProcTableCurrent(&procs);

    try shader.init();
}

fn deinit(ctx: *anyopaque) void {
    const self = Util.ctx_to_self(Self, ctx);

    shader.deinit();

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

fn set_proj_matrix(ctx: *anyopaque, mat: *const zm.Mat) void {
    _ = ctx;
    shader.state.proj = mat.*;
    shader.update_ubo();
}

fn set_view_matrix(ctx: *anyopaque, mat: *const zm.Mat) void {
    _ = ctx;
    shader.state.view = mat.*;
    shader.update_ubo();
}

fn set_model_matrix(ctx: *anyopaque, mat: *const zm.Mat) void {
    _ = ctx;
    shader.update_model(mat);
}

fn create_mesh(ctx: *anyopaque, _: Mesh.VertexLayout) anyerror!Mesh.Handle {
    _ = ctx;
    return 0;
}

fn destroy_mesh(ctx: *anyopaque, _: Mesh.Handle) void {
    _ = ctx;
}

fn update_mesh(ctx: *anyopaque, _: Mesh.Handle, _: usize, _: []const u8) void {
    _ = ctx;
}

fn draw_mesh(ctx: *anyopaque, _: Mesh.Handle) void {
    _ = ctx;
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
            .set_proj_matrix = set_proj_matrix,
            .set_view_matrix = set_view_matrix,
            .set_model_matrix = set_model_matrix,
            .create_mesh = create_mesh,
            .destroy_mesh = destroy_mesh,
            .update_mesh = update_mesh,
            .draw_mesh = draw_mesh,
        },
    };
}
