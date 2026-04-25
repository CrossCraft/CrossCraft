const std = @import("std");
const builtin = @import("builtin");
const ae = @import("aether");
const Util = ae.Util;

pub const std_options = Util.std_options;

const sdk = if (ae.platform == .psp) @import("pspsdk") else void;
comptime {
    if (sdk != void)
        asm (sdk.extra.module.module_info("CrossCraft Classic Server", .{ .mode = .User }, 1, 0));
}

pub const psp_stack_size: u32 = 256 * 1024;
pub const psp_async_stack_size: u32 = 384 * 1024;
pub const psp_heap_reserve_kb_size: u32 = 3072;

pub const panic = if (ae.platform == .psp) sdk.extra.debug.panic else std.debug.FullPanic(std.debug.defaultPanic);
pub const std_options_debug_threaded_io = if (ae.platform == .psp) null else std.Io.Threaded.global_single_threaded;
pub const std_options_debug_io = if (ae.platform == .psp) sdk.extra.Io.psp_io else std.Io.Threaded.global_single_threaded.io();
pub const std_options_cwd = if (ae.platform == .psp) psp_cwd else null;
fn psp_cwd() std.Io.Dir {
    return .{ .handle = -1 };
}

const ServerState = @import("ServerState.zig");

pub fn main(init: std.process.Init) !void {
    if (builtin.os.tag == .psp) {
        sdk.extra.debug.screenInit();
        try sdk.power.set_clock_frequency(333, 333, 166);
        sdk.extra.net.init() catch |err| {
            sdk.extra.debug.print("Net init failed: {s}\n", .{@errorName(err)});
            sdk.kernel.exit_game();
        };

        sdk.extra.net.connectToApctl(1, 30_000_000) catch |err| {
            sdk.extra.debug.print("WiFi connect failed: {s}\n", .{@errorName(err)});
            sdk.kernel.exit_game();
        };

        var ip_buf: [16]u8 = undefined;
        if (sdk.extra.net.getLocalIp(&ip_buf)) |ip| {
            sdk.extra.debug.print("Local IP: {s}\n", .{ip});
        } else {
            sdk.extra.debug.print("Could not get local IP\n", .{});
        }
    }

    defer if (builtin.os.tag == .psp) sdk.extra.net.deinit();

    // PSP-1000 has ~24 MiB of user RAM after the kernel's reservation;
    // desktop has plenty so cap at a comfortable working set.
    const total_mb: usize = if (ae.platform == .psp) 18 else 32;
    const memory = try init.gpa.alloc(u8, total_mb * 1024 * 1024);
    defer init.gpa.free(memory);

    var server_state: ServerState = undefined;
    const state = server_state.state();

    var engine: ae.Engine = undefined;
    try engine.init(init.io, init.environ_map, memory, .{
        .memory = .{
            .render = 64, // Default texture TODO: Fix this in Aether?
            .audio = 0,
            .game = (total_mb - 1) * 1024 * 1024,
            .user = 512 * 1024,
        },
        .title = "CrossCraft Classic Server",
        .vsync = false,
        .resizable = false,
    }, &state);
    defer engine.deinit();

    try engine.run();

    if (ae.platform == .psp) sdk.kernel.exit_game();
}
