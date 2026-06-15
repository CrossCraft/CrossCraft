const std = @import("std");
const ae = @import("aether");
const Util = ae.Util;

// TODO: Make these options stuff nice
pub const std_options: std.Options = .{
    .log_level = Util.std_options.log_level,
    .log_scope_levels = Util.std_options.log_scope_levels,
    .logFn = locked_log_fn,
    .page_size_min = if (ae.platform == .nintendo_3ds) 4 * 1024 else null,
};

var log_lock: std.atomic.Value(bool) = .init(false);

fn locked_log_fn(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    if (comptime ae.platform == .nintendo_switch) {
        if (log_lock.cmpxchgStrong(false, true, .acquire, .monotonic) != null) {
            return;
        }
    } else {
        while (log_lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
            std.atomic.spinLoopHint();
        }
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

const is_freestanding_console = ae.platform == .psp or ae.platform == .nintendo_3ds or ae.platform == .nintendo_switch;

// PSP, 3DS, and Switch override panic/IO handlers that would otherwise pull in
// posix symbols unavailable on their targets.
pub const panic = if (ae.platform == .psp) sdk.extra.debug.panic else if (ae.platform == .nintendo_3ds) ae.ThreeDS.panic else if (ae.platform == .nintendo_switch) @import("root").panic else std.debug.FullPanic(std.debug.defaultPanic);
pub const std_options_debug_threaded_io = if (is_freestanding_console) null else std.Io.Threaded.global_single_threaded;
pub const std_options_debug_io: std.Io = if (ae.platform == .psp) sdk.extra.Io.psp_io else if (ae.platform == .nintendo_3ds or ae.platform == .nintendo_switch) ae.Cio.io() else std.Io.Threaded.global_single_threaded.io();
pub const std_options_cwd = if (ae.platform == .psp)
    psp_cwd
else if (ae.platform == .nintendo_3ds or ae.platform == .nintendo_switch)
    ae.Cio.cwd
else
    null;
fn psp_cwd() std.Io.Dir {
    return .{ .handle = -1 };
}

pub const build_options = @import("build_options");

const MenuState = @import("state/MenuState.zig");
const ResourcePack = @import("ResourcePack.zig");
const game_config = @import("config.zig");

pub fn main(init: std.process.Init) !void {
    game_config.init();
    const memory = try init.gpa.alloc(u8, game_config.main_memory_bytes());
    defer init.gpa.free(memory);

    var menu_state: MenuState = undefined;
    const state = menu_state.state();

    var engine: ae.Engine = undefined;
    try engine.init(init.io, init.environ_map, memory, .{
        .memory = game_config.init_memory(),
        .width = 854,
        .height = 480,
        .title = "CrossCraft Classic",
        .app_name = switch (ae.platform) {
            .nintendo_3ds => "CrossCraft-Classic-3DS",
            .nintendo_switch => "CrossCraft-Classic-Switch",
            else => null,
        },
        .vsync = true,
        .resizable = true,
    }, &state);
    defer engine.deinit();
    defer ResourcePack.deinit();

    try engine.run();
}
