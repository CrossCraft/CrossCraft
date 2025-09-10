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

/// Starts the Graphics API. Must be called before any other graphics functions.
/// Returns an error if initialization fails.
pub inline fn init(self: *const Self) !void {
    try self.tab.init(self.ptr);
}

/// Shuts down the Graphics API and frees all associated resources.
/// After calling this, no other graphics functions should be called.
pub inline fn deinit(self: *const Self) void {
    self.tab.deinit(self.ptr);
}

/// Sets the color used to clear the screen each frame.
/// The color is specified as RGBA values in the range [0.0, 1.0].
/// These are automatically used when `start_frame` is called.
pub inline fn set_clear_color(self: *const Self, r: f32, g: f32, b: f32, a: f32) void {
    self.tab.set_clear_color(self.ptr, r, g, b, a);
}

/// Begins a new frame. This should be called once per frame before any drawing commands.
/// Returns true if the frame was successfully started, false otherwise (e.g., if the window
/// was minimized).
pub inline fn start_frame(self: *const Self) bool {
    return self.tab.start_frame(self.ptr);
}

/// Ends the current frame and presents the rendered content to the screen.
/// This should be called once per frame after all drawing commands.
pub inline fn end_frame(self: *const Self) void {
    self.tab.end_frame(self.ptr);
}

/// Sets the projection matrix used for rendering.
/// This matrix transforms 3D coordinates into 2D screen space.
/// Typically, this is set once per frame or when the window is resized.
/// TODO: Support setting 2D orthographic projection and make sure it's used when drawing 2D elements.
pub inline fn set_proj_matrix(self: *const Self, mat: *const zm.Mat) void {
    self.tab.set_proj_matrix(self.ptr, mat);
}

/// Sets the view matrix used for rendering.
/// This matrix represents the camera's position and orientation in the scene.
/// It is typically updated each frame based on camera movement.
pub inline fn set_view_matrix(self: *const Self, mat: *const zm.Mat) void {
    self.tab.set_view_matrix(self.ptr, mat);
}

/// Sets the model matrix used for rendering.
/// This matrix transforms object coordinates into world space.
/// It is typically updated for each object before drawing it.
pub inline fn set_model_matrix(self: *const Self, mat: *const zm.Mat) void {
    self.tab.set_model_matrix(self.ptr, mat);
}

const GraphicsAPI = @import("platform.zig").GraphicsAPI;

/// Factory function to create a GraphicsAPI instance based on the specified API type.
/// This is a comptime function that selects the appropriate implementation, runtime polymorphism is avoided for performance.
pub fn make_api(comptime api: GraphicsAPI) !Self {
    switch (api) {
        .default, .opengl => {
            const OpenGLAPI = @import("glfw/opengl/opengl_gfx.zig");
            var opengl = try Util.allocator().create(OpenGLAPI);
            return opengl.gfx_api();
        },
    }
}
