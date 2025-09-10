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

    pub const Spec = [_]Rendering.mesh.AttributeSpec{
        .{ .field = "pos", .location = 0 },
        .{ .field = "color", .location = 1 },
        .{ .field = "uv", .location = 2 },
    };
};

const MyMesh = Rendering.Mesh(Vertex, &Vertex.Spec);

const MyState = struct {
    mesh: MyMesh,
    transform: Rendering.Transform,
    texture: Rendering.Texture,

    fn handle_escape(_: *anyopaque, event: Core.input.ButtonEvent) void {
        if (event == .pressed) {
            sp.App.quit();
        }
    }

    fn handle_move(_: *anyopaque, value: [2]f32) void {
        std.debug.print("Axis position: {any}\n", .{value});
    }

    fn init(ctx: *anyopaque) anyerror!void {
        var self = Util.ctx_to_self(MyState, ctx);
        self.mesh = try MyMesh.new(Util.allocator());
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

        try Core.input.register_action("escape", .button);
        try Core.input.bind_action("escape", .{ .source = .{ .key = .Escape } });
        try Core.input.add_button_callback("escape", self, handle_escape);

        try Core.input.register_action("move", .vector2);
        try Core.input.bind_action("move", .{ .source = .{ .key = .W }, .component = .y, .multiplier = 1.0, .deadzone = 0.0 });
        try Core.input.bind_action("move", .{ .source = .{ .key = .S }, .component = .y, .multiplier = -1.0, .deadzone = 0.0 });
        try Core.input.bind_action("move", .{ .source = .{ .key = .A }, .component = .x, .multiplier = -1.0, .deadzone = 0.0 });
        try Core.input.bind_action("move", .{ .source = .{ .key = .D }, .component = .x, .multiplier = 1.0, .deadzone = 0.0 });
        try Core.input.bind_action("move", .{ .source = .{ .gamepad_axis = .LeftX }, .component = .x, .multiplier = 1.0 });
        try Core.input.bind_action("move", .{ .source = .{ .gamepad_axis = .LeftY }, .component = .y, .multiplier = 1.0 });
        try Core.input.add_vector2_callback("move", self, handle_move);
    }

    fn deinit(ctx: *anyopaque) void {
        var self = Util.ctx_to_self(MyState, ctx);
        self.mesh.deinit(Util.allocator());
        self.texture.deinit(Util.allocator());
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

pub fn main() !void {
    var state: MyState = undefined;

    try sp.App.init(1280, 720, "CrossCraft Classic-Z", .opengl, false, false, &state.state());
    defer sp.App.deinit();

    try sp.App.main_loop();
}
