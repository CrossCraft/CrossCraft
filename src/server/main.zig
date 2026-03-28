const std = @import("std");
// const net = @import("net");
// const core = @import("core");
// const Consts = core.Consts;
// const Server = core.Server;

// const ConnectionData = struct {
//     handle: net.IO.Listener.ConnectionHandle,
//     read_buffer: [4096]u8,
//     write_buffer: [4096]u8,
// };

// var conn_handles: [Consts.MAX_PLAYERS]?ConnectionData = @splat(null);
// var running: bool = true;

// fn quit(_: i32) callconv(.c) void {
//     running = false;
// }
//
const builtin = @import("builtin");

const sdk = if (builtin.os.tag == .psp) @import("pspsdk") else void;
comptime {
    if (sdk != void)
        asm (sdk.extra.module.module_info("CrossCraft Classic", .{ .mode = .User }, 1, 0));
}

pub const psp_stack_size: u32 = 256 * 1024;

pub const panic = if (builtin.os.tag == .psp) sdk.extra.debug.panic else std.debug.FullPanic(std.debug.defaultPanic);
pub const std_options_debug_threaded_io = if (builtin.os.tag == .psp) null else std.Io.Threaded.global_single_threaded;
pub const std_options_debug_io = if (builtin.os.tag == .psp) sdk.extra.Io.psp_io else std.Io.Threaded.global_single_threaded.io();
pub const std_options_cwd = if (builtin.os.tag == .psp) psp_cwd else null;
fn psp_cwd() std.Io.Dir {
    return .{ .handle = -1 };
}

pub fn main() !void {
    // var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    // defer _ = gpa.deinit();
    // const allocator = gpa.allocator();

    // try Server.init(allocator, 1337);
    // defer Server.deinit();

    // const server_address = try std.net.Address.parseIp("0.0.0.0", 25565);
    // var listener = try net.IO.Listener.init(server_address);
    // defer listener.deinit();

    // if (builtin.os.tag != .windows) {
    //     std.posix.sigaction(std.posix.SIG.INT, &.{
    //         .flags = 0,
    //         .handler = .{
    //             .handler = quit,
    //         },
    //         .mask = std.posix.sigemptyset(),
    //     }, null);
    // }

    // std.debug.print("Starting server on {f}\n", .{listener.listen_address});

    // const ticks_per_second: i64 = 20;
    // const tick_us: i64 = @intCast(std.time.us_per_s / ticks_per_second);

    // var prev_time: i64 = std.time.microTimestamp();
    // var acc_us: i64 = 0;

    // var tps: usize = 0;
    // var next_report_time: i64 = prev_time + std.time.us_per_s;

    // const max_acc_us: i64 = std.time.us_per_s;

    // while (running) {
    //     const now = std.time.microTimestamp();
    //     var dt = now - prev_time;
    //     if (dt < 0) dt = 0;
    //     prev_time = now;

    //     acc_us += dt;
    //     if (acc_us > max_acc_us) acc_us = max_acc_us;

    //     var connection: ?net.IO.Listener.ConnectionHandle = null;
    //     if (listener.accept()) |conn| {
    //         std.debug.print("Accepted connection from {f}\n", .{conn.address});
    //         connection = conn;

    //         for (0..Consts.MAX_PLAYERS) |i| {
    //             if (conn_handles[i] != null) continue;

    //             std.debug.print("Assigning connection to slot {d}\n", .{i});
    //             conn_handles[i] = .{
    //                 .handle = conn,
    //                 .read_buffer = undefined,
    //                 .write_buffer = undefined,
    //             };

    //             conn_handles[i].?.handle.init_stream(&conn_handles[i].?.read_buffer, &conn_handles[i].?.write_buffer);
    //             Server.client_join(conn_handles[i].?.handle.reader, conn_handles[i].?.handle.writer, &conn_handles[i].?.handle.connected);
    //             break;
    //         } else {
    //             std.debug.print("Server full, rejecting connection from {f}\n", .{conn.address});
    //             conn.close();
    //         }
    //     } else |err| switch (err) {
    //         error.WouldBlock => {},
    //         else => {
    //             std.debug.print("Error accepting connection: {}\n", .{err});
    //         },
    //     }

    //     while (acc_us >= tick_us) {
    //         Server.tick();
    //         acc_us -= tick_us;
    //         tps += 1;
    //     }

    //     for (0..Consts.MAX_PLAYERS) |i| {
    //         if (conn_handles[i]) |conn| {
    //             if (!conn.handle.connected) {
    //                 std.debug.print("Connection in slot {d} disconnected\n", .{i});
    //                 conn.handle.close();
    //                 conn_handles[i] = null;
    //             }
    //         }
    //     }

    //     if (now >= next_report_time) {
    //         tps = 0;
    //         next_report_time += std.time.us_per_s;
    //         if (now > next_report_time + (10 * std.time.us_per_ms))
    //             next_report_time = now + std.time.us_per_s;
    //     }
    // }

    // std.debug.print("\nShutting down server...\n", .{});
}
