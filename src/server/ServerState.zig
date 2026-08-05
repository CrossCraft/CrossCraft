const std = @import("std");
const builtin = @import("builtin");
const ae = @import("aether");
const game = @import("game");
const common = @import("common");

const Util = ae.Util;
const Engine = ae.Engine;
const State = ae.Core.State;

const Server = game.Server;
const CompressWorker = game.CompressWorker;
const CompressorThread = @import("CompressorThread.zig");
const PlayersDb = game.PlayersDb;
const Commands = game.Commands;
const Consts = common.consts;

const log = std.log.scoped(.server);
const sdk = if (ae.platform == .psp) @import("pspsdk") else void;

const ConnectionData = struct {
    stream: std.Io.net.Stream,
    reader: std.Io.net.Stream.Reader,
    writer: std.Io.net.Stream.Writer,
    read_buffer: [4096]u8,
    write_buffer: [4096]u8,
    connected: bool,
};

// Signal handlers run with C calling conventions and cannot carry
// context, so the engine and listener pointers live at module scope.
// `init` populates them; `deinit` clears them.
var global_engine: ?*Engine = null;
var global_listener: ?*std.Io.net.Server = null;

// --- Admin console ---
//
// Stdout carries chat broadcasts and command replies; server logging
// stays on stderr/aether.log so the two streams remain separate. PSPLink
// surfaces both streams on the developer host, so no platform gates are
// needed here.
var stdout_buf: [512]u8 = undefined;
var stdout_writer: std.Io.File.Writer = undefined;
var stdout_iface: ?*std.Io.Writer = null;

const Self = @This();

conn_handles: []?ConnectionData,
tasks: std.Io.Group,
listener: std.Io.net.Server,
compressor_thread: CompressorThread.Thread,

pub fn state(self: *Self) State {
    return .{ .ptr = self, .tab = &.{
        .init = init,
        .deinit = deinit,
        .tick = tick,
        .update = update,
        .draw = draw,
    } };
}

fn init(ctx: *anyopaque, engine: *Engine) anyerror!void {
    var self = Util.ctx_to_self(Self, ctx);

    const alloc = engine.allocator(.user);

    self.conn_handles = try alloc.alloc(?ConnectionData, Consts.MAX_PLAYERS);
    @memset(self.conn_handles, null);

    self.tasks = .init;

    const seed: u64 = @bitCast(@as(i64, @truncate(std.Io.Clock.Timestamp.now(engine.io, .boot).raw.nanoseconds)));
    const config: Server.GameConfig = .{
        .standalone = .{
            .world = .{ .seed = seed, .save_location = Server.default_save_location },
        },
    };
    try Server.init(alloc, alloc, engine.io, engine.dirs.data, config);

    // Dedicated thread for world compression -- shared across world-send
    // (network) and world-save (disk). Off-loads save dispatch from
    // std.Io task spawning and keeps deep `flate` call frames out of small
    // per-task IO stacks.
    self.compressor_thread = try CompressorThread.spawn(alloc);

    engine.report();

    global_engine = engine;
    install_signal_handlers();

    log.info("Starting server on port 25565", .{});

    const server_ip = try std.Io.net.IpAddress.parseIp4("0.0.0.0", 25565);
    // SO_REUSEADDR so a fresh server can rebind immediately after a client
    // disconnects - otherwise the listening socket sits in TIME_WAIT for
    // up to a minute and the next `zig build run-server` hits AddressInUse.
    self.listener = try server_ip.listen(engine.io, .{ .reuse_address = true });
    global_listener = &self.listener;

    self.tasks.concurrent(engine.io, accept_loop, .{ self, engine }) catch unreachable;

    const stdout_file = platform_stdout();
    stdout_writer = stdout_file.writer(engine.io, &stdout_buf);
    stdout_iface = &stdout_writer.interface;
    Server.on_broadcast_chat = stdout_chat_hook;
    self.tasks.concurrent(engine.io, console_loop, .{ self, engine }) catch unreachable;
}

// Standard library exposes std.Io.File.stdin/stdout via posix.STD*_FILENO,
// which the PSP target doesn't define. The pspsdk routes those through
// SceUID handles instead, and the engine's io vtable already speaks that
// dialect, so wrapping them in a File here works on both targets.
fn platform_stdin() std.Io.File {
    if (comptime ae.platform == .psp) {
        return .{ .handle = sdk.io.stdin(), .flags = .{ .nonblocking = false } };
    }
    return std.Io.File.stdin();
}

fn platform_stdout() std.Io.File {
    if (comptime ae.platform == .psp) {
        return .{ .handle = sdk.io.stdout(), .flags = .{ .nonblocking = false } };
    }
    return std.Io.File.stdout();
}

fn stdout_chat_hook(line: []const u8) void {
    write_stripped_line(line);
}

fn stdout_console_write(_: *anyopaque, line: []const u8) void {
    write_stripped_line(line);
}

/// Strip Minecraft color codes ('&' + [0-9a-fk-or]) before writing to a
/// terminal. The codes are meaningful in-game but just show up as literal
/// "&e" noise in the operator's console.
fn write_stripped_line(line: []const u8) void {
    const w = stdout_iface orelse return;
    var i: usize = 0;
    while (i < line.len) {
        if (line[i] == '&' and i + 1 < line.len and is_color_code(line[i + 1])) {
            i += 2;
            continue;
        }
        const next_amp = std.mem.indexOfScalarPos(u8, line, i, '&') orelse line.len;
        w.writeAll(line[i..next_amp]) catch return;
        i = next_amp;
    }
    w.writeAll("\n") catch return;
    w.flush() catch return;
}

fn is_color_code(c: u8) bool {
    return (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or
        (c >= 'k' and c <= 'o') or c == 'r';
}

fn tick(ctx: *anyopaque, engine: *Engine) anyerror!void {
    var self = Util.ctx_to_self(Self, ctx);

    Server.tick();

    for (0..Consts.MAX_PLAYERS) |i| {
        if (self.conn_handles[i]) |*data| {
            if (!data.connected) {
                log.info("Connection in slot {d} disconnected", .{i});
                data.stream.close(engine.io);
                self.conn_handles[i] = null;
            }
        }
    }
}

fn update(_: *anyopaque, _: *Engine, _: f32, _: *const Util.BudgetContext) anyerror!void {}
fn draw(_: *anyopaque, _: *Engine, _: f32, _: *const Util.BudgetContext) anyerror!void {}

fn deinit(ctx: *anyopaque, engine: *Engine) void {
    var self = Util.ctx_to_self(Self, ctx);

    self.tasks.cancel(engine.io);
    log.info("Shutting down server...", .{});

    global_listener = null;
    self.listener.deinit(engine.io);

    // Server.deinit triggers the final world save and waits for it. That
    // save runs on the compressor thread, so the thread must still be alive
    // here. Tear it down only after Server.deinit returns. Any in-flight
    // world-send job aborts with WriteFailed because tasks.cancel above
    // drained the IO read loops.
    Server.deinit();

    CompressWorker.signal_exit();
    self.compressor_thread.join();
    CompressWorker.deinit();

    engine.allocator(.user).free(self.conn_handles);

    global_engine = null;
}

fn client_read_loop(client: *Server.Client) std.Io.Cancelable!void {
    client.read_loop();
}

fn reject_connection(conn: std.Io.net.Stream, engine: *Engine, reason: []const u8) void {
    var write_buf: [128]u8 = undefined;
    var writer = std.Io.net.Stream.Writer.init(conn, engine.io, &write_buf);
    common.protocol.send_disconnect_to_client(&writer.interface, reason) catch {};
    var c = conn;
    c.close(engine.io);
}

fn accept_loop(self: *Self, engine: *Engine) std.Io.Cancelable!void {
    while (engine.running) {
        var conn = self.listener.accept(engine.io) catch |err| {
            if (!engine.running) return;
            log.err("Error accepting connection: {}", .{err});
            continue;
        };
        if (!engine.running) {
            conn.close(engine.io);
            return;
        }
        log.info("Client connected: {}", .{conn.socket.address});

        if (builtin.os.tag == .psp) {
            sdk.extra.net.disableNagle(@intCast(conn.socket.handle)) catch |err|
                log.warn("TCP_NODELAY failed: {}", .{err});
        }

        // Canonicalise the peer IP and look up the persistent record.
        // Done before any slot assignment so banned IPs cannot consume
        // a slot and whitelist mode rejects strangers cheaply.
        var ip_buf: [PlayersDb.ip_str_len]u8 = undefined;
        const ip = PlayersDb.format_ip(conn.socket.address, &ip_buf) orelse "";
        const rec = PlayersDb.lookup_by_ip(ip);

        if (Server.whitelist_enabled and (rec == null or !rec.?.whitelisted)) {
            log.info("Rejecting {s}: not whitelisted", .{ip});
            reject_connection(conn, engine, "Not whitelisted");
            continue;
        }
        if (rec) |r| {
            if (r.banned) {
                const reason = if (r.ban_reason_slice().len > 0) r.ban_reason_slice() else "Banned";
                log.info("Rejecting {s}: banned ({s})", .{ ip, reason });
                reject_connection(conn, engine, reason);
                continue;
            }
        }
        const is_op = if (rec) |r| r.op else false;
        PlayersDb.touch_seen(ip);

        var assigned = false;
        for (0..Consts.MAX_PLAYERS) |i| {
            if (self.conn_handles[i] != null) continue;

            log.info("Assigning connection to slot {d}", .{i});
            self.conn_handles[i] = .{
                .stream = conn,
                .reader = undefined,
                .writer = undefined,
                .read_buffer = @splat(0),
                .write_buffer = @splat(0),
                .connected = true,
            };

            self.conn_handles[i].?.reader = std.Io.net.Stream.Reader.init(conn, engine.io, &self.conn_handles[i].?.read_buffer);
            self.conn_handles[i].?.writer = std.Io.net.Stream.Writer.init(conn, engine.io, &self.conn_handles[i].?.write_buffer);

            if (Server.client_join(&self.conn_handles[i].?.reader.interface, &self.conn_handles[i].?.writer.interface, &self.conn_handles[i].?.connected, ip, is_op)) |client| {
                self.tasks.concurrent(engine.io, client_read_loop, .{client}) catch {
                    log.err("Failed to spawn read task for slot {d}", .{i});
                    self.conn_handles[i].?.connected = false;
                };
            }
            assigned = true;
            break;
        }

        if (!assigned) {
            log.info("&4Server full, rejecting connection", .{});
            reject_connection(conn, engine, "Server is full!");
        }
    }
}

fn console_loop(self: *Self, engine: *Engine) std.Io.Cancelable!void {
    const stdin_file = platform_stdin();
    var reader_scratch: [512]u8 = undefined;
    var file_reader = stdin_file.reader(engine.io, &reader_scratch);
    const r = &file_reader.interface;

    while (engine.running) {
        const raw = r.takeDelimiterExclusive('\n') catch |err| switch (err) {
            error.EndOfStream => return,
            error.ReadFailed => return,
            error.StreamTooLong => {
                // Discard the over-long line and keep going.
                r.toss(r.bufferedLen());
                continue;
            },
        };
        // Skip past the newline so the next take() starts on fresh input.
        r.toss(1);

        const line = std.mem.trimEnd(u8, raw, " \t\r");
        if (line.len == 0) continue;

        if (line[0] == '/') {
            const sink: Commands.Sink = .{ .ctx = self, .write_fn = stdout_console_write };
            Commands.dispatch(sink, line[1..], true);
        } else {
            // Server chat: prefix and broadcast. The broadcast hook will
            // also echo to stdout, so no need to print locally first.
            var msg_buf: Consts.Message = @splat(' ');
            const prefix = "&4[Server]: ";
            const n_pre = @min(prefix.len, msg_buf.len);
            @memcpy(msg_buf[0..n_pre], prefix[0..n_pre]);
            const space = msg_buf.len - n_pre;
            const n_msg = @min(line.len, space);
            @memcpy(msg_buf[n_pre .. n_pre + n_msg], line[0..n_msg]);
            Server.broadcast_chat_message(-1, &msg_buf);
        }
    }
}

fn install_signal_handlers() void {
    if (comptime builtin.os.tag == .psp) {
        const kernel = sdk.kernel;

        const exit_cb = struct {
            fn cb(_: c_int, _: c_int, _: ?*anyopaque) callconv(.c) c_int {
                if (global_engine) |e| e.quit();
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
                if (global_engine) |e| e.quit();
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
                if (global_engine) |e| e.quit();
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
