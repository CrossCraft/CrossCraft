const std = @import("std");
const builtin = @import("builtin");
const ae = @import("aether");

const sdk = if (ae.platform == .psp) @import("pspsdk") else void;

pub const aether_options: ae.Options = .{
    .title = "CrossCraft Classic Server",
    .psp = .{
        .module_name = "CrossCraft Classic Server",
        .stack_size = 256 * 1024,
        .async_stack_size = 64 * 1024,
        .heap_reserve_kb_size = 2048,
    },
};

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
    const total_bytes = total_mb * 1024 * 1024;
    const render_budget = 4 * 1024;
    const game_budget = 512 * 1024;
    const frame_budget = 0;
    const user_budget = total_bytes - render_budget - game_budget - frame_budget;
    const memory = try init.gpa.alloc(u8, total_mb * 1024 * 1024);
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

    if (ae.platform == .psp) sdk.kernel.exit_game();
}
