const std = @import("std");
const game = @import("game");
const common = @import("common");

const Server = game.Server;
const Consts = common.consts;
const CountingAllocator = common.counting_allocator;
const log = std.log.scoped(.server);

const ConnectionData = struct {
    stream: std.Io.net.Stream,
    reader: std.Io.net.Stream.Reader,
    writer: std.Io.net.Stream.Writer,
    read_buffer: [4096]u8,
    write_buffer: [4096]u8,
    connected: bool,
};

var conn_handles: []?ConnectionData = undefined;
var running: bool = true;

const builtin = @import("builtin");

const sdk = if (builtin.os.tag == .psp) @import("pspsdk") else void;
comptime {
    if (sdk != void)
        asm (sdk.extra.module.module_info("CrossCraft Classic", .{ .mode = .User }, 1, 0));
}

pub const psp_stack_size: u32 = 256 * 1024;
pub const psp_async_stack_size: u32 = 384 * 1024;
pub const psp_heap_reserve_kb_size: u32 = 3072;

pub const panic = if (builtin.os.tag == .psp) sdk.extra.debug.panic else std.debug.FullPanic(std.debug.defaultPanic);
pub const std_options_debug_threaded_io = if (builtin.os.tag == .psp) null else std.Io.Threaded.global_single_threaded;
pub const std_options_debug_io = if (builtin.os.tag == .psp) sdk.extra.Io.psp_io else std.Io.Threaded.global_single_threaded.io();
pub const std_options_cwd = if (builtin.os.tag == .psp) psp_cwd else null;
fn psp_cwd() std.Io.Dir {
    return .{ .handle = -1 };
}

pub const print = if (builtin.os.tag == .psp) sdk.extra.debug.print else std.debug.print;

pub const std_options: std.Options = .{
    .log_level = if (builtin.mode == .Debug) .debug else .info,
    .logFn = server_log,
};

fn server_log(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    const prefix = "(" ++ @tagName(scope) ++ ") [" ++ comptime level.asText() ++ "]: ";
    print(prefix ++ format ++ "\n", args);
}

var global_io: std.Io = undefined;
var tasks: std.Io.Group = .init;
var global_listener: ?*std.Io.net.Server = null;

fn install_signal_handlers() void {
    if (comptime builtin.os.tag == .psp) {
        const kernel = sdk.kernel;

        const exit_cb = struct {
            fn cb(_: c_int, _: c_int, _: ?*anyopaque) callconv(.c) c_int {
                running = false;
                return 0;
            }
        }.cb;

        const cb_thread = struct {
            fn entry(_: usize, _: ?*anyopaque) callconv(.c) c_int {
                const cbid = kernel.create_callback("server_exit_cb", exit_cb, null) catch
                    @panic("Could not create exit callback!");
                kernel.register_exit_callback(cbid) catch
                    @panic("Could not register exit callback!");
                kernel.sleep_thread_cb() catch {};
                return 0;
            }
        }.entry;

        const tid = kernel.create_thread("server_exit_thread", cb_thread, 0x11, 0xFA0, .{ .user = true }, null) catch
            @panic("Could not create exit callback thread!");
        kernel.start_thread(tid, 0, null) catch {};
    } else if (comptime builtin.os.tag == .windows) {
        const windows = std.os.windows;
        const ws2_shutdown = struct {
            extern "ws2_32" fn shutdown(s: *anyopaque, how: c_int) callconv(.winapi) c_int;
        }.shutdown;
        const SetConsoleCtrlHandler = struct {
            extern "kernel32" fn SetConsoleCtrlHandler(
                HandlerRoutine: ?*const fn (windows.DWORD) callconv(.winapi) windows.BOOL,
                Add: windows.BOOL,
            ) callconv(.winapi) windows.BOOL;
        }.SetConsoleCtrlHandler;
        const handler = struct {
            fn handler(_: std.os.windows.DWORD) callconv(.winapi) std.os.windows.BOOL {
                running = false;
                if (global_listener) |l| {
                    _ = ws2_shutdown(l.socket.handle, 2);
                }
                return std.os.windows.BOOL.TRUE;
            }
        }.handler;
        _ = SetConsoleCtrlHandler(handler, std.os.windows.BOOL.TRUE);
    } else {
        const handler = struct {
            fn handler(_: std.posix.SIG) callconv(.c) void {
                running = false;
                // Shutdown the listener socket to unblock accept().
                if (global_listener) |l| {
                    _ = std.os.linux.shutdown(l.socket.handle, 2);
                }
            }
        }.handler;

        const act: std.posix.Sigaction = .{
            .handler = .{ .handler = handler },
            .mask = std.mem.zeroes(std.posix.sigset_t),
            .flags = 0,
        };
        std.posix.sigaction(std.posix.SIG.INT, &act, null);
        std.posix.sigaction(std.posix.SIG.TERM, &act, null);
    }
}

fn tick_loop() void {
    const tick_ns: i64 = 50 * std.time.ns_per_ms;
    // If the server falls more than max_catchup behind, skip ticks instead
    // of trying to run them all back-to-back (which cascades the overload).
    const max_catchup_ns: i64 = 10 * tick_ns;

    var deadline: i64 = @truncate(std.Io.Clock.Timestamp.now(global_io, .boot).raw.nanoseconds);
    deadline += tick_ns;

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

        const after: i64 = @truncate(std.Io.Clock.Timestamp.now(global_io, .boot).raw.nanoseconds);
        const remaining_ns = deadline - after;

        if (remaining_ns > 0) {
            const sleep_ms: u32 = @intCast(@divTrunc(remaining_ns, std.time.ns_per_ms));
            if (sleep_ms > 0) {
                global_io.sleep(std.Io.Duration.fromMilliseconds(sleep_ms), .boot) catch {};
            }
        }

        deadline += tick_ns;

        // Cap catch-up: if we've fallen too far behind, accept the loss
        const now: i64 = @truncate(std.Io.Clock.Timestamp.now(global_io, .boot).raw.nanoseconds);
        if (deadline < now - max_catchup_ns) {
            const skipped = @divTrunc(now - deadline, tick_ns);
            log.warn("Skipping {d} ticks to recover from overload", .{skipped});
            deadline = now;
        }
    }
}

fn client_read_loop(client: *game.Server.Client) std.Io.Cancelable!void {
    client.read_loop();
}

fn accept_loop(listener: *std.Io.net.Server) std.Io.Cancelable!void {
    while (running) {
        var conn = listener.accept(global_io) catch |err| {
            if (!running) return;
            log.err("Error accepting connection: {}", .{err});
            continue;
        };
        if (!running) {
            conn.close(global_io);
            return;
        }
        log.info("Client connected: {}", .{conn.socket.address});

        if (builtin.os.tag == .psp) {
            sdk.extra.net.disableNagle(@intCast(conn.socket.handle)) catch |err|
                log.warn("TCP_NODELAY failed: {}", .{err});
        }

        var assigned = false;
        for (0..Consts.MAX_PLAYERS) |i| {
            if (conn_handles[i] != null) continue;

            log.info("Assigning connection to slot {d}", .{i});
            conn_handles[i] = .{
                .stream = conn,
                .reader = undefined,
                .writer = undefined,
                .read_buffer = @splat(0),
                .write_buffer = @splat(0),
                .connected = true,
            };

            conn_handles[i].?.reader = std.Io.net.Stream.Reader.init(conn, global_io, &conn_handles[i].?.read_buffer);
            conn_handles[i].?.writer = std.Io.net.Stream.Writer.init(conn, global_io, &conn_handles[i].?.write_buffer);

            if (Server.client_join(&conn_handles[i].?.reader.interface, &conn_handles[i].?.writer.interface, &conn_handles[i].?.connected)) |client| {
                tasks.concurrent(global_io, client_read_loop, .{client}) catch {
                    log.err("Failed to spawn read task for slot {d}", .{i});
                    conn_handles[i].?.connected = false;
                };
            }
            assigned = true;
            break;
        }

        if (!assigned) {
            log.info("Server full, rejecting connection", .{});
            conn.close(global_io);
        }
    }
}

/// Binary search for the largest single contiguous allocation the allocator
/// can satisfy right now. Halves the probe size down to 256 bytes (PSP
/// minimum block size).
fn psp_max_linear_alloc(alloc: std.mem.Allocator) u32 {
    var size: u32 = 0;
    var probe: u32 = 1024 * 1024;

    while (probe >= 256) : (probe >>= 1) {
        size += probe;
        if (alloc.alloc(u8, size)) |buf| {
            alloc.free(buf);
        } else |_| {
            size -= probe;
        }
    }
    return size;
}

/// Measure total free memory by repeatedly grabbing the largest possible
/// block until nothing remains, then freeing everything.
fn psp_measure_free_memory(alloc: std.mem.Allocator) u32 {
    const MAX_BLOCKS = 128;
    var blocks: [MAX_BLOCKS][]u8 = undefined;
    var count: u32 = 0;
    var total: u32 = 0;

    defer for (0..count) |i| {
        alloc.free(blocks[i]);
    };

    while (count < MAX_BLOCKS) {
        const size = psp_max_linear_alloc(alloc);
        if (size == 0) break;
        blocks[count] = alloc.alloc(u8, size) catch break;
        total += size;
        count += 1;
    }

    return total;
}

fn run_server(backing_allocator: std.mem.Allocator, io: std.Io) !void {
    var counting = CountingAllocator.init(backing_allocator);
    const allocator = counting.allocator();

    conn_handles = try allocator.alloc(?ConnectionData, Consts.MAX_PLAYERS);
    @memset(conn_handles, null);
    defer allocator.free(conn_handles);

    const seed: u64 = @bitCast(@as(i64, @truncate(std.Io.Clock.Timestamp.now(io, .boot).raw.nanoseconds)));
    // Standalone server uses CWD for world.dat / server.properties — the
    // process is typically launched from its own install dir so there's
    // no Finder-style CWD=/ hazard the client has to deal with. If we
    // ever ship a Server.app or Vita server, wire ae.Core.paths.resolve
    // here like the client does.
    try Server.init(allocator, allocator, seed, io, std.Io.Dir.cwd(), false);
    defer Server.deinit();

    counting.print();

    if (comptime builtin.os.tag == .psp) {
        const free_bytes = psp_measure_free_memory(backing_allocator);
        print("Memory after init: free={d} KiB\n", .{free_bytes / 1024});
    }

    global_io = io;

    install_signal_handlers();

    log.info("Starting server on port 25565", .{});

    const server_ip = try std.Io.net.IpAddress.parseIp4("0.0.0.0", 25565);
    // SO_REUSEADDR so a fresh server can rebind immediately after a client
    // disconnects - otherwise the listening socket sits in TIME_WAIT for
    // up to a minute and the next `zig build run-server` hits AddressInUse.
    var listener = try server_ip.listen(io, .{ .reuse_address = true });
    global_listener = &listener;
    defer {
        global_listener = null;
        listener.deinit(io);
    }

    tasks.concurrent(io, accept_loop, .{&listener}) catch unreachable;

    tick_loop();

    tasks.cancel(io);
    log.info("Shutting down server...", .{});
}

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

    defer blk: {
        if (builtin.os.tag == .psp) {
            sdk.extra.net.deinit();
        }

        break :blk;
    }

    try run_server(init.gpa, init.io);

    if (comptime builtin.os.tag == .psp) {
        sdk.kernel.exit_game();
    }
}
