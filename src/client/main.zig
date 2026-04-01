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

pub const psp_stack_size: u32 = 256 * 1024;

// PSP: override panic/IO handlers that would otherwise pull in posix symbols.
pub const panic = if (ae.platform == .psp) sdk.extra.debug.panic else std.debug.FullPanic(std.debug.defaultPanic);
pub const std_options_debug_threaded_io = if (ae.platform == .psp) null else std.Io.Threaded.global_single_threaded;
pub const std_options_debug_io = if (ae.platform == .psp) sdk.extra.Io.psp_io else std.Io.Threaded.global_single_threaded.io();
pub const std_options_cwd = if (ae.platform == .psp) psp_cwd else null;
fn psp_cwd() std.Io.Dir {
    return .{ .handle = -1 };
}

const MenuState = @import("state/MenuState.zig");

pub fn main(init: std.process.Init) !void {
    const memory = try init.gpa.alloc(u8, 20 * 1024 * 1024);
    defer init.gpa.free(memory);

    var state: MenuState = undefined;
    try ae.App.init(init.io, memory, .{
        .memory = .{
            .render = 4 * 1024 * 1024,
            .audio = 2 * 1024 * 1024,
            .game = 2 * 1024 * 1024,
            .user = 8 * 1024 * 1024,
            .scratch = 4 * 1024 * 1024,
        },
        .vsync = false,
        .resizable = if (ae.gfx == .vulkan) false else true,
    }, &state.state());
    defer ae.App.deinit();
    try ae.App.main_loop();
}
