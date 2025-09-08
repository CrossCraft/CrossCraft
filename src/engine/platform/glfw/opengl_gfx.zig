const std = @import("std");
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

var vaos = Util.CircularBuffer(VAOData, 16).init();
var meshes = Util.CircularBuffer(MeshInternal, 2048).init();

const VAOData = struct {
    layout: Mesh.VertexLayout,
    vao: gl.uint,
};

const MeshInternal = struct {
    vao: usize,
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

fn find_layout(layout: Mesh.VertexLayout) ?gl.uint {
    return for (1..16) |i| {
        if (vaos.buffer[i]) |v| {
            if (std.meta.eql(v.layout, layout)) {
                break @intCast(i);
            }
        }
    } else null;
}

fn create_mesh(ctx: *anyopaque, layout: Mesh.VertexLayout) anyerror!Mesh.Handle {
    _ = ctx;
    const vao_idx: usize = find_layout(layout) orelse blk: {
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

        const idx = vaos.add_element(.{
            .layout = layout,
            .vao = vao,
        }) orelse @panic("Out of VAOs");

        break :blk idx;
    };

    const vao = vaos.get_element(vao_idx).?.vao;
    var vbo: gl.uint = 0;
    gl.CreateBuffers(1, @ptrCast(&vbo));
    gl.NamedBufferData(vbo, 0, null, gl.STATIC_DRAW);
    gl.VertexArrayVertexBuffer(vao, 0, vbo, 0, @intCast(layout.stride));

    const mesh_idx = meshes.add_element(.{
        .vao = vao_idx,
        .vbo = vbo,
    }) orelse @panic("Out of Meshes");

    return @intCast(mesh_idx);
}

fn destroy_mesh(ctx: *anyopaque, handle: Mesh.Handle) void {
    _ = ctx;

    var mesh = meshes.get_element(handle) orelse return;
    gl.DeleteBuffers(1, @ptrCast(&mesh.vbo));
    mesh.vbo = 0;

    _ = meshes.remove_element(handle);
}

fn update_mesh(ctx: *anyopaque, handle: Mesh.Handle, offset: usize, data: []const u8) void {
    _ = ctx;

    const mesh = meshes.get_element(handle) orelse return;
    var sz: gl.int64 = 0;
    gl.GetNamedBufferParameteri64v(mesh.vbo, gl.BUFFER_SIZE, &sz);
    const need = @as(gl.int64, @intCast(offset + data.len));
    if (need > sz) {
        gl.NamedBufferData(mesh.vbo, need, null, gl.DYNAMIC_DRAW);
    }

    gl.NamedBufferSubData(mesh.vbo, @intCast(offset), @intCast(data.len), data.ptr);
}

fn draw_mesh(ctx: *anyopaque, handle: Mesh.Handle, count: usize) void {
    _ = ctx;

    const mesh = meshes.get_element(handle) orelse return;
    const vao_data = vaos.get_element(mesh.vao) orelse return;

    gl.BindVertexArray(vao_data.vao);
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
            .set_model_matrix = set_model_matrix,
            .create_mesh = create_mesh,
            .destroy_mesh = destroy_mesh,
            .update_mesh = update_mesh,
            .draw_mesh = draw_mesh,
            .create_texture = create_texture,
            .bind_texture = bind_texture,
        },
    };
}
