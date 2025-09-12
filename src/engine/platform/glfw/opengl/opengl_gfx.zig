const std = @import("std");
const Util = @import("../../../util/util.zig");
const glfw = @import("glfw");
const gl = @import("gl");
const zm = @import("zmath");

const shader = @import("shader.zig");
const gfx = @import("../../gfx.zig");

const Rendering = @import("../../../rendering/rendering.zig");
const Mesh = Rendering.mesh;
const Pipeline = Rendering.Pipeline;
const GFXAPI = @import("../../gfx_api.zig");
const Self = @This();

var procs: gl.ProcTable = undefined;
var last_width: u32 = 0;
var last_height: u32 = 0;
var pipelines = Util.CircularBuffer(PipelineData, 16).init();
var meshes = Util.CircularBuffer(MeshInternal, 2048).init();

const PipelineData = struct {
    layout: Pipeline.VertexLayout,
    vao: gl.uint,
    program: shader.Shader,
};

const MeshInternal = struct {
    pipeline: Pipeline.Handle,
    vbo: gl.uint,
};

fn init(ctx: *anyopaque) !void {
    _ = ctx;

    if (!procs.init(glfw.getProcAddress)) @panic("Failed to initialize OpenGL");
    gl.makeProcTableCurrent(&procs);
    gl.Enable(gl.FRAMEBUFFER_SRGB);

    Util.engine_logger.debug("OpenGL {s}", .{gl.GetString(gl.VERSION).?});
    Util.engine_logger.debug("GLSL {s}", .{gl.GetString(gl.SHADING_LANGUAGE_VERSION).?});
    Util.engine_logger.debug("Vendor: {s}", .{gl.GetString(gl.VENDOR).?});
    Util.engine_logger.debug("Renderer: {s}", .{gl.GetString(gl.RENDERER).?});

    gl.Viewport(0, 0, @intCast(gfx.surface.get_width()), @intCast(gfx.surface.get_height()));

    try shader.init();
    shader.state.proj = zm.identity();
    shader.state.view = zm.identity();
    shader.update_ubo();
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

    const new_width = gfx.surface.get_width();
    const new_height = gfx.surface.get_height();
    if (new_width != last_width or new_height != last_height) {
        @branchHint(.unlikely);

        last_width = new_width;
        last_height = new_height;
        gl.Viewport(0, 0, @intCast(new_width), @intCast(new_height));

        if (new_width == 0 or new_height == 0) {
            return false;
        }
    }

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

fn create_pipeline(ctx: *anyopaque, layout: Pipeline.VertexLayout, v_shader: ?[:0]const u8, f_shader: ?[:0]const u8) anyerror!Pipeline.Handle {
    _ = ctx;

    if (v_shader == null or f_shader == null) {
        return error.InvalidShader;
    }

    var vao: gl.uint = 0;
    gl.CreateVertexArrays(1, @ptrCast(&vao));
    for (layout.attributes) |a| {
        gl.EnableVertexArrayAttrib(vao, a.location);

        gl.VertexArrayAttribFormat(vao, a.location, @intCast(a.size), switch (a.format) {
            .f32x2, .f32x3 => gl.FLOAT,
            .unorm8x4 => gl.UNSIGNED_BYTE,
        }, switch (a.format) {
            .f32x2, .f32x3 => gl.FALSE,
            .unorm8x4 => gl.TRUE,
        }, @intCast(a.offset));
        gl.VertexArrayAttribBinding(vao, a.location, a.binding);
    }

    const pipeline = pipelines.add_element(.{
        .layout = layout,
        .vao = vao,
        .program = try shader.Shader.init(v_shader.?, f_shader.?),
    }) orelse return error.OutOfPipelines;

    return @intCast(pipeline);
}

fn bind_pipeline(ctx: *anyopaque, pipeline: Pipeline.Handle) void {
    _ = ctx;

    const pl = pipelines.get_element(pipeline) orelse return;
    gl.BindVertexArray(pl.vao);
    gl.UseProgram(pl.program.shader_program);
}

fn destroy_pipeline(ctx: *anyopaque, pipeline: Pipeline.Handle) void {
    _ = ctx;

    var pl = pipelines.get_element(pipeline) orelse return;
    gl.DeleteVertexArrays(1, @ptrCast(&pl.vao));
    pl.vao = 0;
    pl.program.deinit();

    _ = pipelines.remove_element(pipeline);
}

fn create_mesh(ctx: *anyopaque, pipeline: Pipeline.Handle) anyerror!Mesh.Handle {
    _ = ctx;

    const pl = pipelines.get_element(pipeline).?;
    var vbo: gl.uint = 0;
    gl.CreateBuffers(1, @ptrCast(&vbo));
    gl.NamedBufferData(vbo, 0, null, gl.STATIC_DRAW);
    gl.VertexArrayVertexBuffer(pl.vao, 0, vbo, 0, @intCast(pl.layout.stride));

    const mesh_idx = meshes.add_element(.{
        .pipeline = pipeline,
        .vbo = vbo,
    }) orelse return error.OutOfMeshes;

    return @intCast(mesh_idx);
}

fn destroy_mesh(ctx: *anyopaque, handle: Mesh.Handle) void {
    _ = ctx;

    var mesh = meshes.get_element(handle) orelse return;
    gl.DeleteBuffers(1, @ptrCast(&mesh.vbo));
    mesh.vbo = 0;

    _ = meshes.remove_element(handle);
}

fn update_mesh(ctx: *anyopaque, handle: Mesh.Handle, data: []const u8) void {
    _ = ctx;

    const mesh = meshes.get_element(handle) orelse return;

    gl.NamedBufferData(mesh.vbo, @intCast(data.len), null, gl.STATIC_DRAW);
    gl.NamedBufferSubData(mesh.vbo, 0, @intCast(data.len), data.ptr);
}

fn draw_mesh(ctx: *anyopaque, handle: Mesh.Handle, model: *const zm.Mat, count: usize) void {
    _ = ctx;

    const mesh = meshes.get_element(handle) orelse return;
    const pl = pipelines.get_element(mesh.pipeline) orelse return;

    pl.program.update_model(model);
    gl.VertexArrayVertexBuffer(pl.vao, 0, mesh.vbo, 0, @intCast(pl.layout.stride));
    gl.DrawArrays(gl.TRIANGLES, 0, @intCast(count));
}

fn create_texture(ctx: *anyopaque, width: u32, height: u32, data: []const u8) anyerror!u32 {
    _ = ctx;

    var tex: gl.uint = 0;
    gl.CreateTextures(gl.TEXTURE_2D, 1, @ptrCast(&tex));
    gl.TextureStorage2D(tex, 1, gl.RGBA8, @intCast(width), @intCast(height));
    gl.TextureSubImage2D(tex, 0, 0, 0, @intCast(width), @intCast(height), gl.RGBA, gl.UNSIGNED_BYTE, data.ptr);
    gl.TextureParameteri(tex, gl.TEXTURE_MIN_FILTER, gl.NEAREST);
    gl.TextureParameteri(tex, gl.TEXTURE_MAG_FILTER, gl.NEAREST);
    gl.TextureParameteri(tex, gl.TEXTURE_WRAP_S, gl.REPEAT);
    gl.TextureParameteri(tex, gl.TEXTURE_WRAP_T, gl.REPEAT);
    gl.GenerateTextureMipmap(tex);

    return tex;
}

fn bind_texture(ctx: *anyopaque, handle: u32) void {
    _ = ctx;
    gl.BindTextureUnit(0, handle);
}

fn destroy_texture(ctx: *anyopaque, handle: u32) void {
    _ = ctx;
    gl.DeleteTextures(1, @ptrCast(&handle));
}

pub fn gfx_api(self: *Self) GFXAPI {
    return GFXAPI{
        .ptr = self,
        .tab = &.{
            .init = init,
            .deinit = deinit,
            .set_clear_color = set_clear_color,
            .start_frame = start_frame,
            .end_frame = end_frame,
            .set_proj_matrix = set_proj_matrix,
            .set_view_matrix = set_view_matrix,
            .create_mesh = create_mesh,
            .destroy_mesh = destroy_mesh,
            .update_mesh = update_mesh,
            .draw_mesh = draw_mesh,
            .create_texture = create_texture,
            .bind_texture = bind_texture,
            .destroy_texture = destroy_texture,
            .create_pipeline = create_pipeline,
            .destroy_pipeline = destroy_pipeline,
            .bind_pipeline = bind_pipeline,
        },
    };
}
