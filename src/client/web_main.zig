const std = @import("std");
const ae = @import("aether");

const client_main = @import("main.zig");
const game_config = @import("config.zig");
const MenuState = @import("state/MenuState.zig");

pub const aether_options = client_main.aether_options;

// The page drives frames after main returns, so everything the engine borrows
// must outlive main.
var menu_state: MenuState = undefined;
var engine: ae.Engine = undefined;

pub fn main(init: std.process.Init) !void {
    game_config.init();

    const memory = try init.gpa.alignedAlloc(u8, .fromByteUnits(16), game_config.main_memory_bytes());
    errdefer init.gpa.free(memory);

    const state = menu_state.state();
    try engine.init(init.io, init.environ_map, memory, &.{
        .memory = game_config.init_memory(),
        .width = 854,
        .height = 480,
        .title = aether_options.title,
        .app_name = ae.AppOptions.resolve_app_name(aether_options),
        .vsync = true,
        .resizable = true,
    }, &state);
    try engine.run();
}
