const std = @import("std");
const Util = @import("../../../util/util.zig");
const glfw = @import("glfw");
const zm = @import("zmath");

const gfx = @import("../../gfx.zig");
const Mesh = @import("../../../rendering/mesh.zig");
const GFXAPI = @import("../../gfx_api.zig");
const Self = @This();

fn init(ctx: *anyopaque) !void {
    _ = ctx;
}

fn deinit(ctx: *anyopaque) void {
    _ = ctx;
}

fn set_clear_color(ctx: *anyopaque, r: f32, g: f32, b: f32, a: f32) void {
    _ = ctx;
    _ = r;
    _ = g;
    _ = b;
    _ = a;
}

fn start_frame(ctx: *anyopaque) bool {
    _ = ctx;
    return true;
}

fn end_frame(ctx: *anyopaque) void {
    _ = ctx;
}

fn set_proj_matrix(ctx: *anyopaque, mat: *const zm.Mat) void {
    _ = ctx;
    _ = mat;
}

fn set_view_matrix(ctx: *anyopaque, mat: *const zm.Mat) void {
    _ = ctx;
    _ = mat;
}

fn set_model_matrix(ctx: *anyopaque, mat: *const zm.Mat) void {
    _ = ctx;
    _ = mat;
}

fn create_mesh(ctx: *anyopaque, layout: Mesh.VertexLayout) anyerror!Mesh.Handle {
    _ = ctx;
    _ = layout;
    return 0;
}

fn destroy_mesh(ctx: *anyopaque, handle: Mesh.Handle) void {
    _ = ctx;
    _ = handle;
}

fn update_mesh(ctx: *anyopaque, handle: Mesh.Handle, offset: usize, data: []const u8) void {
    _ = ctx;
    _ = handle;
    _ = offset;
    _ = data;
}

fn draw_mesh(ctx: *anyopaque, handle: Mesh.Handle, count: usize) void {
    _ = ctx;
    _ = handle;
    _ = count;
}

fn create_texture(ctx: *anyopaque, width: u32, height: u32, data: []const u8) anyerror!u32 {
    _ = ctx;
    _ = width;
    _ = height;
    _ = data;
    return 0;
}

fn bind_texture(ctx: *anyopaque, handle: u32) void {
    _ = ctx;
    _ = handle;
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
