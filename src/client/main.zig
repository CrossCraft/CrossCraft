const std = @import("std");
const ae = @import("aether");
const Util = ae.Util;

// TODO: Make these options stuff nice
pub const std_options = Util.std_options;

const sdk = if (ae.platform == .psp) @import("pspsdk") else void;
comptime {
    if (sdk != void)
        asm (sdk.extra.module.module_info("CrossCraft", .{ .mode = .User }, 1, 0));
}

pub const psp_stack_size: u32 = 512 * 1024;
pub const psp_async_stack_size: u32 = 384 * 1024;
pub const psp_heap_reserve_kb_size: u32 = 2048;

// PSP: override panic/IO handlers that would otherwise pull in posix symbols.
pub const panic = if (ae.platform == .psp) sdk.extra.debug.panic else std.debug.FullPanic(std.debug.defaultPanic);
pub const std_options_debug_threaded_io = if (ae.platform == .psp) null else std.Io.Threaded.global_single_threaded;
pub const std_options_debug_io = if (ae.platform == .psp) sdk.extra.Io.psp_io else std.Io.Threaded.global_single_threaded.io();
pub const std_options_cwd = if (ae.platform == .psp) psp_cwd else null;
fn psp_cwd() std.Io.Dir {
    return .{ .handle = -1 };
}

pub const build_options = @import("build_options");

const MenuState = @import("state/MenuState.zig");
const ResourcePack = @import("ResourcePack.zig");

pub fn main(init: std.process.Init) !void {
    if (ae.platform == .psp) {
        sdk.extra.utils.enableHBCB();
        try sdk.power.set_clock_frequency(333, 333, 166);
    }

    const game_config = @import("config.zig");
    const memory = try init.gpa.alloc(u8, game_config.current.total_memory_mb * 1024 * 1024);
    defer init.gpa.free(memory);

    var menu_state: MenuState = undefined;
    const state = menu_state.state();

    var engine: ae.Engine = undefined;
    try engine.init(init.io, memory, .{
        .memory = game_config.init_memory(),
        .width = 854,
        .height = 480,
        .title = "CrossCraft Classic",
        .vsync = false,
        .resizable = true,
    }, &state);
    defer engine.deinit();
    defer ResourcePack.deinit();

    try engine.run();
}
