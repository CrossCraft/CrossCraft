const std = @import("std");
const ae = @import("aether");

pub const aether_options: ae.Options = .{
    .title = "CrossCraft Classic Server",
};

const ServerState = @import("ServerState.zig");

pub fn main(init: std.process.Init) !void {
    const total_bytes = 96 * 1024 * 1024;
    const render_budget = 4 * 1024;
    const game_budget = 512 * 1024;
    const frame_budget = 0;
    const user_budget = total_bytes - render_budget - game_budget - frame_budget;
    const memory = try init.gpa.alloc(u8, total_bytes);
    defer init.gpa.free(memory);

    var server_state: ServerState = undefined;
    const state = server_state.state();

    var engine: ae.Engine = undefined;
    try engine.init(init.io, init.environ_map, memory, &.{
        .memory = .{
            .render = render_budget,
            .audio = 0,
            .game = game_budget,
            .frame = frame_budget,
            .user = user_budget,
        },
        .title = aether_options.title,
        .app_name = ae.AppOptions.resolveAppName(aether_options),
        .vsync = false,
        .resizable = false,
    }, &state);
    defer engine.deinit();

    try engine.run();
}
