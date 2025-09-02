const std = @import("std");
const sp = @import("Spark");
const State = sp.Core.State;

const MyState = struct {
    fn init(ctx: *anyopaque) anyerror!void {
        _ = ctx;
    }

    fn deinit(ctx: *anyopaque) void {
        _ = ctx;
    }

    fn update(ctx: *anyopaque, dt: f32) anyerror!void {
        _ = ctx;
        _ = dt;
    }

    fn draw(ctx: *anyopaque, dt: f32) anyerror!void {
        _ = ctx;
        _ = dt;
    }

    pub fn state(self: *MyState) State {
        return .{ .ptr = self, .tab = .{
            .init = init,
            .deinit = deinit,
            .update = update,
            .draw = draw,
        } };
    }
};

export var NvOptimusEnablement: u32 = 1;

pub fn main() !void {
    var state = MyState{};

    try sp.App.init(854, 480, "CrossCraft Classic-Z", .opengl, false, &state.state());
    defer sp.App.deinit();

    try sp.App.main_loop();
}
