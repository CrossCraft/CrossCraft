const std = @import("std");
const sp = @import("Spark");
const Core = sp.Core;
const Util = sp.Util;
const Rendering = sp.Rendering;
const Audio = sp.Audio;
const State = Core.State;

pub const std_options = Util.std_options;

const Vertex = struct {
    pos: [3]f32,
    color: [4]u8,
    uv: [2]f32,

    comptime {
        std.debug.assert(@sizeOf(@This()) % 24 == 0);
    }

    pub const Attributes = Rendering.Pipeline.attributes_from_struct(@This(), &[_]Rendering.Pipeline.AttributeSpec{
        .{ .field = "pos", .location = 0 },
        .{ .field = "color", .location = 1 },
        .{ .field = "uv", .location = 2 },
    });
    pub const Layout = Rendering.Pipeline.layout_from_struct(@This(), &Attributes);
};

const MyMesh = Rendering.Mesh(Vertex);

const MyState = struct {
    mesh: MyMesh,
    transform: Rendering.Transform,
    texture: Rendering.Texture,

    fn init(ctx: *anyopaque) anyerror!void {
        var self = Util.ctx_to_self(MyState, ctx);
        pipeline = try Rendering.Pipeline.new(Vertex.Layout, @embedFile("shaders/basic.vert"), @embedFile("shaders/basic.frag"));
        self.mesh = try MyMesh.new(Util.allocator(), pipeline);
        self.transform = Rendering.Transform.new();

        try self.mesh.vertices.appendSlice(Util.allocator(), &.{
            Vertex{
                .pos = .{ -0.5, -0.5, 0.0 },
                .color = .{ 255, 0, 0, 255 },
                .uv = .{ 0.0, 0.0 },
            },
            Vertex{
                .pos = .{ 0.5, -0.5, 0.0 },
                .color = .{ 0, 255, 0, 255 },
                .uv = .{ 1.0, 0.0 },
            },
            Vertex{
                .pos = .{ 0.0, 0.5, 0.0 },
                .color = .{ 0, 0, 255, 255 },
                .uv = .{ 0.5, 1.0 },
            },
        });
        self.mesh.update();

        self.texture = try Rendering.Texture.load(Util.allocator(), "test.png");
    }

    fn deinit(ctx: *anyopaque) void {
        var self = Util.ctx_to_self(MyState, ctx);
        self.mesh.deinit(Util.allocator());
        self.texture.deinit(Util.allocator());
        Rendering.Pipeline.deinit(pipeline);
    }

    fn tick(ctx: *anyopaque) anyerror!void {
        _ = ctx;
    }

    fn update(ctx: *anyopaque, dt: f32) anyerror!void {
        _ = ctx;
        _ = dt;
    }

    fn draw(ctx: *anyopaque, dt: f32) anyerror!void {
        var self = Util.ctx_to_self(MyState, ctx);
        Rendering.Pipeline.bind(pipeline);
        self.texture.bind();

        self.mesh.draw(&self.transform.get_matrix());
        _ = dt;
    }

    pub fn state(self: *MyState) State {
        return .{ .ptr = self, .tab = &.{
            .init = init,
            .deinit = deinit,
            .tick = tick,
            .update = update,
            .draw = draw,
        } };
    }
};

var pipeline: Rendering.Pipeline.Handle = undefined;

pub fn main() !void {
    var state: MyState = undefined;

    try sp.App.init(1280, 720, "CrossCraft Classic-Z", .opengl, false, false, &state.state());
    defer sp.App.deinit();

    defer Rendering.Pipeline.deinit(pipeline);

    try sp.App.main_loop();
}
