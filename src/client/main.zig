const std = @import("std");
const ae = @import("aether");
const caps = @import("capabilities").ClientType(ae);

pub const aether_options: ae.Options = .{
    .title = "CrossCraft Classic",
    .app_name = caps.resources.app_name,
    .psp = .{
        .module_name = "CrossCraft",
        .stack_size = 512 * 1024,
        .async_stack_size = 64 * 1024,
        .heap_reserve_kb_size = 2048,
    },
};

pub const build_options = @import("build_options");

const MenuState = @import("state/MenuState.zig");
const ResourcePack = @import("ResourcePack.zig");
const game_config = @import("config.zig");

pub fn main(init: std.process.Init) !void {
    game_config.init();

    const memory = try init.gpa.alignedAlloc(u8, .fromByteUnits(16), game_config.main_memory_bytes());
    defer init.gpa.free(memory);

    var menu_state: MenuState = undefined;
    const state = menu_state.state();

    var engine: ae.Engine = undefined;
    try engine.init(init.io, init.environ_map, memory, &.{
        .memory = game_config.init_memory(),
        .width = 854,
        .height = 480,
        .title = aether_options.title,
        .app_name = ae.AppOptions.resolveAppName(aether_options),
        .vsync = true,
        .resizable = true,
    }, &state);
    defer engine.deinit();
    defer ResourcePack.deinit();

    try engine.run();
}
