const Util = @import("../util/util.zig");

const Self = @This();

ptr: *anyopaque,
tab: VTable,

pub const VTable = struct {
    init: *const fn (ctx: *anyopaque) anyerror!void,
    deinit: *const fn (ctx: *anyopaque) void,

    set_clear_color: *const fn (ctx: *anyopaque, r: f32, g: f32, b: f32, a: f32) void,

    start_frame: *const fn (ctx: *anyopaque) bool,
    end_frame: *const fn (ctx: *anyopaque) void,
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
