const std = @import("std");
const game = @import("game");
const common = @import("common");

const Server = game.Server;
const Consts = common.consts;
const log = std.log.scoped(.server);

const ConnectionData = struct {
    stream: std.Io.net.Stream,
    reader: std.Io.net.Stream.Reader,
    writer: std.Io.net.Stream.Writer,
    read_buffer: [4096]u8,
    write_buffer: [4096]u8,
    connected: bool,
};

var conn_handles: [Consts.MAX_PLAYERS]?ConnectionData = @splat(null);
var running: bool = true;

const builtin = @import("builtin");

const sdk = if (builtin.os.tag == .psp) @import("pspsdk") else void;
comptime {
    if (sdk != void)
        asm (sdk.extra.module.module_info("CrossCraft Classic", .{ .mode = .User }, 1, 0));
}

pub const psp_stack_size: u32 = 512 * 1024;

pub const panic = if (builtin.os.tag == .psp) sdk.extra.debug.panic else std.debug.FullPanic(std.debug.defaultPanic);
pub const std_options_debug_threaded_io = if (builtin.os.tag == .psp) null else std.Io.Threaded.global_single_threaded;
pub const std_options_debug_io = if (builtin.os.tag == .psp) sdk.extra.Io.psp_io else std.Io.Threaded.global_single_threaded.io();
pub const std_options_cwd = if (builtin.os.tag == .psp) psp_cwd else null;
fn psp_cwd() std.Io.Dir {
    return .{ .handle = -1 };
}

pub const print = if (builtin.os.tag == .psp) sdk.extra.debug.print else std.debug.print;

var global_io: std.Io = undefined;
var tasks: std.Io.Group = .init;

fn tick_loop() std.Io.Cancelable!void {
    const tick_duration = std.Io.Duration.fromMilliseconds(50);

    while (running) {
        Server.tick();

        for (0..Consts.MAX_PLAYERS) |i| {
            if (conn_handles[i]) |*data| {
                if (!data.connected) {
                    log.info("Connection in slot {d} disconnected", .{i});
                    data.stream.close(global_io);
                    conn_handles[i] = null;
                }
            }
        }

        global_io.sleep(tick_duration, .boot) catch {};
    }
}

fn client_read_loop(client: *game.Server.Client) std.Io.Cancelable!void {
    client.read_loop();
}

pub fn main(init: std.process.Init) !void {
    if (builtin.os.tag == .psp) {
        sdk.extra.utils.enableHBCB();
        sdk.extra.debug.screenInit();
        sdk.extra.net.init() catch |err| {
            sdk.extra.debug.print("Net init failed: {s}\n", .{@errorName(err)});
            return;
        };

        sdk.extra.net.connectToApctl(1, 30_000_000) catch |err| {
            sdk.extra.debug.print("WiFi connect failed: {s}\n", .{@errorName(err)});
            return;
        };

        var ip_buf: [16]u8 = undefined;
        if (sdk.extra.net.getLocalIp(&ip_buf)) |ip| {
            sdk.extra.debug.print("Local IP: {s}\n", .{ip});
        } else {
            sdk.extra.debug.print("Could not get local IP\n", .{});
        }
    }

    defer blk: {
        if (builtin.os.tag == .psp) {
            sdk.extra.net.deinit();
        }

        break :blk;
    }

    const allocator = init.arena.allocator();
    const io = init.io;

    try Server.init(allocator, 1337);
    defer Server.deinit();

    global_io = io;

    log.info("Starting server on port 25565", .{});

    const server_ip = try std.Io.net.IpAddress.parseIp4("0.0.0.0", 25565);
    var listener = try server_ip.listen(io, .{});
    defer listener.deinit(io);

    tasks.concurrent(io, tick_loop, .{}) catch unreachable;

    while (running) {
        var conn = listener.accept(io) catch |err| {
            log.err("Error accepting connection: {}", .{err});
            continue;
        };
        log.info("Client connected: {}", .{conn.socket.address});

        var assigned = false;
        for (0..Consts.MAX_PLAYERS) |i| {
            if (conn_handles[i] != null) continue;

            log.info("Assigning connection to slot {d}", .{i});
            conn_handles[i] = .{
                .stream = conn,
                .reader = undefined,
                .writer = undefined,
                .read_buffer = undefined,
                .write_buffer = undefined,
                .connected = true,
            };

            conn_handles[i].?.reader = std.Io.net.Stream.Reader.init(conn, io, &conn_handles[i].?.read_buffer);
            conn_handles[i].?.writer = std.Io.net.Stream.Writer.init(conn, io, &conn_handles[i].?.write_buffer);

            if (Server.client_join(&conn_handles[i].?.reader.interface, &conn_handles[i].?.writer.interface, &conn_handles[i].?.connected)) |client| {
                tasks.concurrent(io, client_read_loop, .{client}) catch {
                    log.err("Failed to spawn read task for slot {d}", .{i});
                    conn_handles[i].?.connected = false;
                };
            }
            assigned = true;
            break;
        }

        if (!assigned) {
            log.info("Server full, rejecting connection", .{});
            conn.close(io);
        }
    }

    tasks.cancel(io);
    log.info("Shutting down server...", .{});
}
