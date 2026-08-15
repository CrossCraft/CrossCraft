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
const Heartbeat = @import("Heartbeat.zig");
const PlayersDb = game.PlayersDb;
const AccessControl = game.AccessControl;
const Commands = game.Commands;
const Consts = common.consts;

const log = std.log.scoped(.server);
const sdk = if (ae.platform == .psp) @import("pspsdk") else void;

const SERVER_PORT: u16 = 25565;
const HEARTBEAT_INTERVAL_MS: i64 = 45_000;
const SALT_ALPHABET = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";

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
heartbeat_config: Heartbeat.Config,
heartbeat_salt: [16]u8,
heartbeat_users: std.atomic.Value(u32),

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
    errdefer alloc.free(self.conn_handles);
    @memset(self.conn_handles, null);

    self.tasks = .init;
    self.heartbeat_users = .init(0);

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

    self.heartbeat_config = Heartbeat.Config.load(engine.io, engine.dirs.data);
    if (self.heartbeat_config.count > 0) {
        generate_salt(engine.io, &self.heartbeat_salt) catch |err| {
            log.warn("Heartbeat disabled: could not generate a salt: {}", .{err});
            self.heartbeat_config.count = 0;
        };
    }

    global_engine = engine;
    install_signal_handlers();

    log.info("Starting server on port {d}", .{SERVER_PORT});

    const server_ip = try std.Io.net.IpAddress.parseIp4("0.0.0.0", SERVER_PORT);
    // SO_REUSEADDR so a fresh server can rebind immediately after a client
    // disconnects - otherwise the listening socket sits in TIME_WAIT for
    // up to a minute and the next `zig build run-server` hits AddressInUse.
    self.listener = try server_ip.listen(engine.io, .{ .reuse_address = true });
    global_listener = &self.listener;

    self.tasks.concurrent(engine.io, accept_loop, .{ self, engine }) catch unreachable;
    if (self.heartbeat_config.count > 0) {
        self.tasks.concurrent(engine.io, heartbeat_loop, .{ self, engine }) catch |err| {
            log.err("Failed to start heartbeat sender: {}", .{err});
            return err;
        };
    }

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

    if (self.heartbeat_config.count > 0) {
        self.heartbeat_users.store(count_initialized_users(), .release);
    }
}

fn update(_: *anyopaque, _: *Engine, _: f32, _: *const Util.BudgetContext) anyerror!void {
    PlayersDb.flush_if_due();
}
fn draw(_: *anyopaque, _: *Engine, _: f32, _: *const Util.BudgetContext) anyerror!void {}

fn generate_salt(io: std.Io, out: *[16]u8) !void {
    var random_bytes: [32]u8 = undefined;
    var written: usize = 0;
    const rejection_limit: u16 = (256 / SALT_ALPHABET.len) * SALT_ALPHABET.len;

    while (written < out.len) {
        try io.randomSecure(&random_bytes);
        for (random_bytes) |byte| {
            if (@as(u16, byte) >= rejection_limit) continue;
            out[written] = SALT_ALPHABET[byte % SALT_ALPHABET.len];
            written += 1;
            if (written == out.len) break;
        }
    }
}

fn count_initialized_users() u32 {
    var count: u32 = 0;
    for (Server.players.items) |maybe_client| {
        if (maybe_client) |client| {
            if (client.initialized and client.connected.*) count += 1;
        }
    }
    return count;
}

fn heartbeat_loop(self: *Self, engine: *Engine) std.Io.Cancelable!void {
    var client: std.http.Client = .{
        .allocator = engine.allocator(.user),
        .io = engine.io,
    };
    defer client.deinit();

    while (true) {
        const request = Heartbeat.RequestData{
            .server_name = &Server.server_name,
            .port = SERVER_PORT,
            .users = self.heartbeat_users.load(.acquire),
            .max_players = Consts.MAX_PLAYERS,
            .salt = &self.heartbeat_salt,
        };

        for (0..self.heartbeat_config.count) |index| {
            const endpoint_len: usize = self.heartbeat_config.lens[index];
            const endpoint = self.heartbeat_config.urls[index][0..endpoint_len];
            Heartbeat.send(engine.io, &client, endpoint, request) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                else => log.warn("Heartbeat endpoint {d} failed after retries: {}", .{ index + 1, err }),
            };
        }
        try engine.io.sleep(.{ .nanoseconds = @as(i96, HEARTBEAT_INTERVAL_MS) * std.time.ns_per_ms }, .real);
    }
}

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

        // Canonicalise the peer IP and look up durable policy. This is a
        // snapshot-only check: accepting a TCP connection never creates a
        // recent-player record or writes players.json.
        // Done before any slot assignment so banned IPs cannot consume
        // a slot and whitelist mode rejects strangers cheaply.
        var ip_buf: [PlayersDb.ip_str_len]u8 = undefined;
        const ip = PlayersDb.format_ip(conn.socket.address, &ip_buf) orelse "";
        const policy = AccessControl.lookup(ip);

        if (Server.whitelist_enabled and !policy.whitelisted) {
            log.info("Rejecting {s}: not whitelisted", .{ip});
            reject_connection(conn, engine, "Not whitelisted");
            continue;
        }
        if (policy.banned) {
            const reason = if (policy.ban_reason_slice().len > 0) policy.ban_reason_slice() else "Banned";
            log.info("Rejecting {s}: banned ({s})", .{ ip, reason });
            reject_connection(conn, engine, reason);
            continue;
        }
        const is_op = policy.op;

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
