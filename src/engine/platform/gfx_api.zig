const zm = @import("zmath");
const Util = @import("../util/util.zig");
const Mesh = @import("../rendering/mesh.zig");
const Texture = @import("../rendering/texture.zig");
const Self = @This();

ptr: *anyopaque,
tab: *const VTable,

pub const VTable = struct {
    // --- API Setup / Lifecycle ---
    init: *const fn (ctx: *anyopaque) anyerror!void,
    deinit: *const fn (ctx: *anyopaque) void,

    // --- API State ---
    set_clear_color: *const fn (ctx: *anyopaque, r: f32, g: f32, b: f32, a: f32) void,
    set_proj_matrix: *const fn (ctx: *anyopaque, mat: *const zm.Mat) void,
    set_view_matrix: *const fn (ctx: *anyopaque, mat: *const zm.Mat) void,
    set_model_matrix: *const fn (ctx: *anyopaque, mat: *const zm.Mat) void,

    // --- Frame Management ---
    start_frame: *const fn (ctx: *anyopaque) bool,
    end_frame: *const fn (ctx: *anyopaque) void,

    // --- Mesh API (raw) ---
    // These are intentionally not exposed directly to the user.
    // Use the Mesh abstraction instead.
    create_mesh: *const fn (ctx: *anyopaque, layout: Mesh.VertexLayout) anyerror!Mesh.Handle,
    destroy_mesh: *const fn (ctx: *anyopaque, mesh: Mesh.Handle) void,
    update_mesh: *const fn (ctx: *anyopaque, mesh: Mesh.Handle, offset: usize, data: []const u8) void,
    draw_mesh: *const fn (ctx: *anyopaque, mesh: Mesh.Handle, count: usize) void,

    // --- Texture API (raw) ---
    create_texture: *const fn (ctx: *anyopaque, width: u32, height: u32, data: []const u8) anyerror!Texture.Handle,
    bind_texture: *const fn (ctx: *anyopaque, handle: Texture.Handle) void,
};

pub inline fn init(self: *Self) !void {
    try self.tab.init(self.ptr);
}

pub inline fn deinit(self: *Self) void {
    self.tab.deinit(self.ptr);
}

pub inline fn set_clear_color(self: *Self, r: f32, g: f32, b: f32, a: f32) void {
    self.tab.set_clear_color(self.ptr, r, g, b, a);
}

pub inline fn start_frame(self: *Self) bool {
    return self.tab.start_frame(self.ptr);
}

pub inline fn end_frame(self: *Self) void {
    self.tab.end_frame(self.ptr);
}

pub inline fn set_proj_matrix(self: *Self, mat: *const zm.Mat) void {
    self.tab.set_proj_matrix(self.ptr, mat);
}

pub inline fn set_view_matrix(self: *Self, mat: *const zm.Mat) void {
    self.tab.set_view_matrix(self.ptr, mat);
}

pub inline fn set_model_matrix(self: *Self, mat: *const zm.Mat) void {
    self.tab.set_model_matrix(self.ptr, mat);
}

const GraphicsAPI = @import("platform.zig").GraphicsAPI;
pub fn make_api(comptime api: GraphicsAPI) !Self {
    switch (api) {
        .default, .opengl => {
            const OpenGLAPI = @import("glfw/opengl_gfx.zig");
            var opengl = try Util.allocator().create(OpenGLAPI);
            return opengl.gfx_api();
        },
    }
}
