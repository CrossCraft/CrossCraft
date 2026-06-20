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

const is_freestanding_console = ae.platform == .psp or ae.platform == .nintendo_switch;

// PSP and Switch override panic/IO handlers that would otherwise pull in
// posix symbols unavailable on their targets. 3DS is handled by Aether's
// zitrus entry root, not by C stdio.
pub const panic = if (ae.platform == .psp) sdk.extra.debug.panic else if (ae.platform == .nintendo_switch) @import("root").panic else std.debug.FullPanic(std.debug.defaultPanic);
pub const std_options_debug_threaded_io = if (is_freestanding_console) null else std.Io.Threaded.global_single_threaded;
pub const std_options_debug_io: std.Io = if (ae.platform == .psp) sdk.extra.Io.psp_io else if (ae.platform == .nintendo_switch) ae.Cio.io() else std.Io.Threaded.global_single_threaded.io();
pub const std_options_cwd = if (ae.platform == .psp)
    psp_cwd
else if (ae.platform == .nintendo_switch)
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
    boot_stage(init.io, "main.enter");
    game_config.init();
    boot_stage(init.io, "config.init.done");

    const memory = try init.gpa.alignedAlloc(u8, .fromByteUnits(16), game_config.main_memory_bytes());
    defer init.gpa.free(memory);
    boot_stage(init.io, "arena.alloc.done");

    var menu_state: MenuState = undefined;
    const state = menu_state.state();
    boot_stage(init.io, "menu.state.ready");

    var engine: ae.Engine = undefined;
    boot_stage(init.io, "engine.init.begin");
    engine.init(init.io, init.environ_map, memory, .{
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
    }, &state) catch |err| return fail_stage("engine.init", err);
    boot_stage(init.io, "engine.init.done");
    defer engine.deinit();
    defer ResourcePack.deinit();

    boot_stage(init.io, "engine.run.begin");
    engine.run() catch |err| return fail_stage("engine.run", err);
}

fn boot_stage(io: std.Io, comptime stage: []const u8) void {
    if (comptime ae.platform != .nintendo_3ds) return;

    const file = std.Io.Dir.cwd().createFile(io, "sdmc:/crosscraft_boot_stage.txt", .{ .truncate = true }) catch
        return;
    defer file.close(io);
    file.writeStreamingAll(io, stage ++ "\n") catch {};
}

fn fail_stage(comptime stage: []const u8, err: anyerror) anyerror {
    if (comptime ae.platform == .nintendo_3ds) {
        std.log.err("CrossCraft 3DS failed at {s}: {s}", .{ stage, @errorName(err) });
        if (err == error.Unexpected) {
            if (comptime std.mem.eql(u8, stage, "engine.init")) return error.CrossCraftEngineInitUnexpected;
            if (comptime std.mem.eql(u8, stage, "engine.run")) return error.CrossCraftEngineRunUnexpected;
        }
    }
    return err;
}
