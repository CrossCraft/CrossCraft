const std = @import("std");
const ae = @import("aether");
const Util = ae.Util;

// TODO: Make these options stuff nice
pub const std_options: std.Options = .{
    .log_level = Util.std_options.log_level,
    .log_scope_levels = Util.std_options.log_scope_levels,
    .logFn = locked_log_fn,
};

var log_lock: std.atomic.Value(bool) = .init(false);

fn locked_log_fn(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    while (log_lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
        std.atomic.spinLoopHint();
    }
    defer log_lock.store(false, .release);

    Util.std_options.logFn(level, scope, format, args);
}

const sdk = if (ae.platform == .psp) @import("pspsdk") else void;
comptime {
    if (sdk != void)
        asm (sdk.extra.module.module_info("CrossCraft", .{ .mode = .User }, 1, 0));
}

pub const psp_stack_size: u32 = 512 * 1024;
pub const psp_async_stack_size: u32 = 64 * 1024;
pub const psp_heap_reserve_kb_size: u32 = 2048 + 512;

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
const game_config = @import("config.zig");

pub fn main(init: std.process.Init) !void {
    game_config.init();
    const profile = game_config.current();
    const memory = try init.gpa.alloc(u8, profile.total_memory_mb * 1024 * 1024);
    defer init.gpa.free(memory);

    var menu_state: MenuState = undefined;
    const state = menu_state.state();

    var engine: ae.Engine = undefined;
    try engine.init(init.io, init.environ_map, memory, .{
        .memory = game_config.init_memory(),
        .width = 854,
        .height = 480,
        .title = "CrossCraft Classic",
        .vsync = true,
        .resizable = true,
    }, &state);
    defer engine.deinit();
    defer ResourcePack.deinit();

    try engine.run();
}
