const std = @import("std");
const assert = std.debug.assert;
const caps = @import("capabilities");
const ae = @import("aether");
const core = @import("core");

const Util = ae.Util;
const Engine = ae.Engine;
const State = ae.Core.State;

const Server = core.Server;
const CompressWorker = core.CompressWorker;
const ServerConfig = @import("Config.zig");
const Heartbeat = @import("Heartbeat.zig");
const Backup = @import("Backup.zig");
const PlayersDb = @import("PlayersDb.zig");
const AccessControl = @import("AccessControl.zig");
const Commands = @import("Commands.zig");
const outbound_queue = core.OutboundQueue;

const log = std.log.scoped(.server);

const ServerPort: u16 = 25565;
const HeartbeatIntervalMs: i64 = 45_000;
const SaltAlphabet = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";
const LoginFrameLen: usize = 131;

const ConnectionState = enum {
    free,
    pending,
    ready,
    active,
    failed,
};

const ConnectionData = struct {
    stream: std.Io.net.Stream,
    reader: std.Io.net.Stream.Reader,
    writer: std.Io.net.Stream.Writer,
    read_buffer: [4096]u8,
    write_buffer: [4096]u8,
    // Only the connection worker writes to the socket; producers enqueue here.
    out_queue: outbound_queue.OutboundQueue,
    transport: std.atomic.Value(Server.Client.TransportState),
    ip: [PlayersDb.ip_str_len:0]u8,
    is_op: bool,
    closed: bool = false,
};

// Stable addresses preserve prefetched bytes when a pending login is admitted.
const ConnectionSlot = struct {
    data: ConnectionData = undefined,
    state: ConnectionState = .free,
    worker_done: bool = true,
    login: Server.LoginRequest = undefined,
    player_handle: ?Server.PlayerHandle = null,
};

// C signal handlers cannot carry context.
var global_engine: ?*Engine = null;
var global_listener: ?*std.Io.net.Server = null;

var stdout_buf: [512]u8 = undefined;
var stdout_writer: std.Io.File.Writer = undefined;
var stdout_mutex: std.Io.Mutex = .init;

const ServerState = @This();

inited: bool = false,
connection_pool: []ConnectionSlot,
connections_mutex: std.Io.Mutex,
tasks: std.Io.Group,
listener: std.Io.net.Server,
compressor_thread: Util.Thread,
server_config: ServerConfig,
heartbeat_salt: [16]u8,
heartbeat_users: std.atomic.Value(u32),
backup: Backup,

pub fn state(self: *ServerState) State {
    return .{ .ptr = self, .tab = &.{
        .init = init,
        .deinit = deinit,
        .tick = tick,
        .update = update,
        .draw = draw,
    } };
}

fn init(ctx: *anyopaque, engine: *Engine) anyerror!void {
    var self = Util.ctx_to_self(ServerState, ctx);
    self.inited = false;

    const alloc = engine.allocator(.user);

    self.tasks = .init;
    self.connections_mutex = .init;
    self.heartbeat_users = .init(0);
    stdout_mutex = .init;

    const seed: u64 = @bitCast(@as(i64, @truncate(std.Io.Clock.Timestamp.now(engine.io, .boot).raw.nanoseconds)));
    self.server_config = ServerConfig.load(engine.io, engine.dirs.data, seed);
    const config: Server.GameConfig = .{ .standalone = self.server_config.core_config() };
    Backup.pre_init_validate_and_restore(
        engine.io,
        engine.dirs.data,
        alloc,
        self.server_config.save_location_slice(),
    );
    try Server.init(alloc, alloc, engine.io, engine.dirs.data, config);

    self.compressor_thread = Util.Thread.spawn(.{
        .name = "world_compress",
        .stack_size = 512 * 1024,
        .priority = .lowest,
        .allocator = alloc,
    }, CompressWorker.worker_main, .{}) catch |err| {
        Server.deinit_after_init_error();
        return err;
    };
    errdefer {
        Server.deinit();
        CompressWorker.signal_exit();
        self.compressor_thread.join();
        CompressWorker.deinit();
    }

    try AccessControl.init(alloc, engine.io, Server.save_dir, self.server_config.max_policy_records);
    errdefer AccessControl.deinit();
    try PlayersDb.init(alloc, engine.io, Server.save_dir, self.server_config.max_players_saved);
    errdefer PlayersDb.deinit();
    try AccessControl.finish_legacy_migration();

    const pending_len: usize = @intCast(self.server_config.max_pending_logins);
    self.connection_pool = try alloc.alloc(ConnectionSlot, Server.MaxPlayers + pending_len);
    errdefer alloc.free(self.connection_pool);
    for (self.connection_pool) |*slot| slot.* = .{};

    self.backup = Backup.init(engine.io, self.server_config.autosave_seconds);

    engine.report();

    if (self.server_config.heartbeat.count > 0) {
        generate_salt(engine.io, &self.heartbeat_salt) catch |err| {
            log.warn("Heartbeat disabled: could not generate a salt: {}", .{err});
            self.server_config.heartbeat.count = 0;
        };
    }

    global_engine = engine;
    errdefer global_engine = null;
    install_signal_handlers();

    log.info("Starting server on port {d}", .{ServerPort});

    const server_ip = try std.Io.net.IpAddress.parseIp4("0.0.0.0", ServerPort);
    self.listener = try server_ip.listen(engine.io, .{ .reuse_address = true });
    errdefer self.listener.deinit(engine.io);
    global_listener = &self.listener;
    errdefer global_listener = null;

    const stdout_file = std.Io.File.stdout();
    stdout_writer = stdout_file.writer(engine.io, &stdout_buf);
    Server.on_broadcast_chat = write_stripped_line;
    Server.on_command = dispatch_player_command;
    errdefer {
        Server.on_broadcast_chat = null;
        Server.on_command = null;
    }
    errdefer {
        self.tasks.cancel(engine.io);
        for (self.connection_pool) |*slot| {
            if (slot.state != .free) release_slot_locked(slot, engine);
        }
    }

    try self.tasks.concurrent(engine.io, Backup.loop, .{ &self.backup, engine });
    try self.tasks.concurrent(engine.io, accept_loop, .{ self, engine });
    if (self.server_config.heartbeat.count > 0) {
        self.tasks.concurrent(engine.io, heartbeat_loop, .{ self, engine }) catch |err| {
            log.err("Failed to start heartbeat sender: {}", .{err});
            return err;
        };
    }

    try self.tasks.concurrent(engine.io, console_loop, .{ self, engine });
    self.inited = true;
}

fn dispatch_player_command(client: *Server.Client, line: []const u8) void {
    Commands.dispatch(.{ .ctx = client, .write_fn = player_command_write }, line, client.is_op.load(.acquire));
}

fn player_command_write(ctx: *anyopaque, line: []const u8) void {
    const client: *Server.Client = @ptrCast(@alignCast(ctx));
    client.send_message(client.id, line) catch {};
}

fn stdout_console_write(_: *anyopaque, line: []const u8) void {
    write_stripped_line(line);
}

fn write_stripped_line(line: []const u8) void {
    const w = &stdout_writer.interface;
    const engine = global_engine orelse return;
    stdout_mutex.lockUncancelable(engine.io);
    defer stdout_mutex.unlock(engine.io);

    write_without_color_codes(w, line) catch return;
    w.writeAll("\n") catch return;
    w.flush() catch return;
}

fn write_without_color_codes(writer: *std.Io.Writer, line: []const u8) std.Io.Writer.Error!void {
    var start: usize = 0;
    var i: usize = 0;
    while (i < line.len) {
        if (line[i] == '&' and i + 1 < line.len and
            std.mem.indexOfScalar(u8, "0123456789abcdefklmnor", line[i + 1]) != null)
        {
            try writer.writeAll(line[start..i]);
            i += 2;
            start = i;
        } else {
            i += 1;
        }
    }
    try writer.writeAll(line[start..]);
}

fn tick(ctx: *anyopaque, engine: *Engine) anyerror!void {
    var self = Util.ctx_to_self(ServerState, ctx);

    Server.tick();
    self.reap_finished_connections(engine);
    self.promote_ready_logins(engine);

    if (self.server_config.heartbeat.count > 0) {
        self.heartbeat_users.store(count_initialized_users(), .release);
    }
}

fn update(_: *anyopaque, _: *Engine, _: f32, _: *const Util.BudgetContext) anyerror!void {
    PlayersDb.flush_if_due();
}
fn draw(_: *anyopaque, _: *Engine, _: f32, _: *const Util.BudgetContext) anyerror!void {}

const PendingReservation = union(enum) {
    accepted: *ConnectionSlot,
    pending_full,
    ip_limited,
};

fn slot_ip(slot: *const ConnectionSlot) []const u8 {
    assert(slot.state != .free);
    return std.mem.sliceTo(slot.data.ip[0..], 0);
}

fn reserve_pending_slot_locked(
    self: *ServerState,
    conn: std.Io.net.Stream,
    ip: []const u8,
    is_op: bool,
    io: std.Io,
) PendingReservation {
    var ip_count: usize = 0;
    var pending_count: usize = 0;
    for (self.connection_pool) |*slot| {
        if (slot.state == .free) continue;
        if (std.mem.eql(u8, slot_ip(slot), ip)) ip_count += 1;
        if (slot.state != .active) pending_count += 1;
    }
    if (ip_count >= self.server_config.max_connections_per_ip) return .ip_limited;
    if (pending_count >= self.server_config.max_pending_logins) return .pending_full;

    const slot = for (self.connection_pool) |*candidate| {
        if (candidate.state == .free) break candidate;
    } else return .pending_full;

    assert(slot.worker_done);
    assert(slot.player_handle == null);

    slot.* = .{
        .data = .{
            .stream = conn,
            .reader = undefined,
            .writer = undefined,
            .read_buffer = undefined,
            .write_buffer = undefined,
            .out_queue = .{},
            .transport = .init(.open),
            .ip = std.mem.zeroes([PlayersDb.ip_str_len:0]u8),
            .is_op = is_op,
        },
        .state = .pending,
        .worker_done = false,
    };
    const ip_len = @min(ip.len, PlayersDb.ip_str_len);
    @memcpy(slot.data.ip[0..ip_len], ip[0..ip_len]);
    slot.data.reader = std.Io.net.Stream.Reader.init(conn, io, &slot.data.read_buffer);
    slot.data.writer = std.Io.net.Stream.Writer.init(conn, io, &slot.data.write_buffer);

    return .{ .accepted = slot };
}

fn release_slot_locked(slot: *ConnectionSlot, engine: *Engine) void {
    assert(slot.state != .free);
    assert(slot.worker_done);
    if (!slot.data.closed) {
        slot.data.stream.close(engine.io);
        slot.data.closed = true;
    }
    if (slot.data.out_queue.buf.len > 0) {
        engine.allocator(.user).free(slot.data.out_queue.buf);
        slot.data.out_queue = .{};
    }
    slot.data.transport.store(.closed, .release);
    slot.player_handle = null;
    slot.state = .free;
    slot.worker_done = true;
}

fn reject_slot_locked(slot: *ConnectionSlot, engine: *Engine, reason: []const u8) void {
    // A pending worker must finish before the host writes on its socket.
    assert(slot.worker_done);
    assert(slot.player_handle == null);
    if (slot.data.closed) return;
    core.protocol.send_disconnect_to_client(&slot.data.writer.interface, reason) catch {};
    slot.data.stream.close(engine.io);
    slot.data.closed = true;
    slot.data.transport.store(.closed, .release);
}

fn finish_worker(self: *ServerState, slot: *ConnectionSlot, engine: *Engine) void {
    self.connections_mutex.lockUncancelable(engine.io);
    defer self.connections_mutex.unlock(engine.io);

    if (slot.state == .pending) slot.state = .failed;
    assert(slot.state != .free);
    assert(!slot.worker_done);
    slot.worker_done = true;
}

fn reap_finished_connections(self: *ServerState, engine: *Engine) void {
    self.connections_mutex.lockUncancelable(engine.io);
    defer self.connections_mutex.unlock(engine.io);

    for (self.connection_pool, 0..) |*slot, index| {
        if (!slot.worker_done) continue;
        switch (slot.state) {
            .failed => release_slot_locked(slot, engine),
            .active => {
                if (slot.data.transport.load(.acquire) != .closed) continue;
                log.info("Connection in slot {d} disconnected", .{index});
                if (slot.player_handle) |handle| Server.remove_client(handle);
                release_slot_locked(slot, engine);
            },
            else => {},
        }
    }
}

fn promote_ready_logins(self: *ServerState, engine: *Engine) void {
    self.connections_mutex.lockUncancelable(engine.io);
    defer self.connections_mutex.unlock(engine.io);

    var active_count: usize = 0;
    for (self.connection_pool) |*slot| {
        if (slot.state == .active) active_count += 1;
    }
    for (self.connection_pool, 0..) |*slot, index| {
        if (slot.state != .ready or !slot.worker_done) continue;
        assert(active_count <= Server.MaxPlayers);
        assert(slot.player_handle == null);
        assert(slot.data.out_queue.buf.len == 0);
        assert(!slot.data.closed);
        if (active_count == Server.MaxPlayers) {
            log.info("&4Server full, rejecting completed login", .{});
            reject_slot_locked(slot, engine, "Server is full!");
            release_slot_locked(slot, engine);
            continue;
        }

        // Pending sockets do not need an outbound queue until admission.
        slot.data.out_queue.buf = engine.allocator(.user).alloc(u8, outbound_queue.out_queue_bytes) catch {
            log.err("Failed to allocate outbound queue, rejecting completed login", .{});
            reject_slot_locked(slot, engine, "Server error, try again");
            release_slot_locked(slot, engine);
            continue;
        };

        const admission = Server.admit_login(
            &slot.data.reader.interface,
            &slot.data.writer.interface,
            &slot.data.transport,
            &slot.data.out_queue,
            &slot.data.stream,
            slot_ip(slot),
            slot.data.is_op,
            slot.login,
        );
        const client = switch (admission) {
            .rejected => |reason| {
                log.info("Rejecting completed login: {s}", .{reason});
                reject_slot_locked(slot, engine, reason);
                release_slot_locked(slot, engine);
                continue;
            },
            .accepted => |accepted| accepted,
        };

        active_count += 1;
        slot.state = .active;
        slot.worker_done = false;
        slot.player_handle = .{ .id = @intCast(client.id), .generation = client.generation };

        self.tasks.concurrent(engine.io, client_login_loop, .{ self, slot, client, engine }) catch {
            log.err("Failed to spawn login task for slot {d}", .{index});
            client.mark_closed();
            slot.worker_done = true;
        };
    }
}

fn wait_for_login_frame(reader: *std.Io.Reader) std.Io.Reader.Error!void {
    _ = try reader.peek(LoginFrameLen);
}

fn wait_for_login_timeout(io: std.Io, timeout_ms: u32) std.Io.Cancelable!void {
    try io.sleep(.{ .nanoseconds = @as(i96, timeout_ms) * std.time.ns_per_ms }, .real);
}

const LoginRaceResult = union(enum) {
    read: std.Io.Reader.Error!void,
    timeout: std.Io.Cancelable!void,
};

fn pending_login_loop(self: *ServerState, slot: *ConnectionSlot, engine: *Engine) std.Io.Cancelable!void {
    defer finish_worker(self, slot, engine);

    const LoginSelect = std.Io.Select(LoginRaceResult);
    var result_buffer: [2]LoginRaceResult = undefined;
    var select = LoginSelect.init(engine.io, &result_buffer);
    defer select.cancelDiscard();

    select.concurrent(.read, wait_for_login_frame, .{&slot.data.reader.interface}) catch |err| {
        log.err("Failed to schedule pending login read: {}", .{err});
        return;
    };
    select.concurrent(.timeout, wait_for_login_timeout, .{ engine.io, self.server_config.login_timeout_ms }) catch |err| {
        log.err("Failed to schedule pending login timeout: {}", .{err});
        return;
    };

    const result = try select.await();
    switch (result) {
        .read => |read_result| {
            read_result catch |err| {
                log.info("Pending login read failed: {}", .{err});
                return;
            };

            const frame = slot.data.reader.interface.peek(LoginFrameLen) catch |err| {
                log.info("Pending login frame disappeared: {}", .{err});
                return;
            };
            const request = Server.parse_login_frame(frame) catch |err| {
                log.info("Rejecting malformed login: {}", .{err});
                return;
            };
            slot.data.reader.interface.toss(LoginFrameLen);

            self.connections_mutex.lockUncancelable(engine.io);
            if (slot.state == .pending) {
                slot.login = request;
                slot.state = .ready;
            }
            self.connections_mutex.unlock(engine.io);
        },
        .timeout => |timeout_result| {
            timeout_result catch |err| switch (err) {
                error.Canceled => return error.Canceled,
            };
            log.info("Pending login timed out after {d} ms", .{self.server_config.login_timeout_ms});
        },
    }
}

fn client_login_loop(
    self: *ServerState,
    slot: *ConnectionSlot,
    client: *Server.Client,
    engine: *Engine,
) std.Io.Cancelable!void {
    defer finish_worker(self, slot, engine);

    client.finish_login() catch |err| switch (err) {
        error.Canceled => {
            client.mark_closed();
            return error.Canceled;
        },
        else => {
            client.mark_closed();
            log.info("Login failed: {}", .{err});
            return;
        },
    };
    PlayersDb.record_completed_login(slot_ip(slot), client.name[0..client.name_len]);
    client.read_loop();
}

fn generate_salt(io: std.Io, out: *[16]u8) !void {
    var random_bytes: [32]u8 = undefined;
    var written: usize = 0;
    const rejection_limit: u16 = (256 / SaltAlphabet.len) * SaltAlphabet.len;

    while (written < out.len) {
        try io.randomSecure(&random_bytes);
        for (random_bytes) |byte| {
            if (@as(u16, byte) >= rejection_limit) continue;
            out[written] = SaltAlphabet[byte % SaltAlphabet.len];
            written += 1;
            if (written == out.len) break;
        }
    }
}

fn count_initialized_users() u32 {
    var count: u32 = 0;
    Server.lock_roster_shared();
    defer Server.unlock_roster_shared();

    for (&Server.players.items) |*entry| {
        const client = &(entry.* orelse continue);
        if (client.initialized and client.is_connected()) count += 1;
    }
    return count;
}

fn heartbeat_loop(self: *ServerState, engine: *Engine) std.Io.Cancelable!void {
    var client: std.http.Client = .{
        .allocator = engine.allocator(.user),
        .io = engine.io,
    };
    defer client.deinit();

    while (true) {
        const request = Heartbeat.RequestData{
            .server_name = &Server.server_name,
            .port = ServerPort,
            .users = self.heartbeat_users.load(.acquire),
            .max_players = Server.MaxPlayers,
            .salt = &self.heartbeat_salt,
        };

        for (0..self.server_config.heartbeat.count) |index| {
            const endpoint = self.server_config.heartbeat.url(index);
            Heartbeat.send(engine.io, &client, endpoint, request) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                else => log.warn("Heartbeat endpoint {d} failed after retries: {}", .{ index + 1, err }),
            };
        }
        try engine.io.sleep(.{ .nanoseconds = @as(i96, HeartbeatIntervalMs) * std.time.ns_per_ms }, .real);
    }
}

fn deinit(ctx: *anyopaque, engine: *Engine) void {
    var self = Util.ctx_to_self(ServerState, ctx);
    if (!self.inited) return;
    self.inited = false;

    self.tasks.cancel(engine.io);
    log.info("Shutting down server...", .{});

    self.connections_mutex.lockUncancelable(engine.io);
    for (self.connection_pool) |*slot| {
        if (slot.state != .free) release_slot_locked(slot, engine);
    }
    self.connections_mutex.unlock(engine.io);

    global_listener = null;
    self.listener.deinit(engine.io);

    PlayersDb.deinit();
    AccessControl.deinit();
    // The compressor must finish the final world save before it shuts down.
    Server.deinit();

    CompressWorker.signal_exit();
    self.compressor_thread.join();
    CompressWorker.deinit();

    engine.allocator(.user).free(self.connection_pool);

    Server.on_broadcast_chat = null;
    Server.on_command = null;
    global_engine = null;
}

fn reject_connection(conn: std.Io.net.Stream, engine: *Engine, reason: []const u8) void {
    var write_buf: [128]u8 = undefined;
    var writer = std.Io.net.Stream.Writer.init(conn, engine.io, &write_buf);
    core.protocol.send_disconnect_to_client(&writer.interface, reason) catch {};
    conn.close(engine.io);
}

fn accept_loop(self: *ServerState, engine: *Engine) std.Io.Cancelable!void {
    while (engine.running) {
        var conn = self.listener.accept(engine.io) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => {
                if (!engine.running) return;
                log.err("Error accepting connection: {}", .{err});
                continue;
            },
        };
        if (!engine.running) {
            conn.close(engine.io);
            return;
        }
        log.info("Client connected: {}", .{conn.socket.address});

        // Check policy before consuming a pending slot.
        var ip_buf: [PlayersDb.ip_str_len]u8 = undefined;
        const ip = PlayersDb.format_ip(conn.socket.address, &ip_buf) orelse "";
        const policy = AccessControl.lookup(ip);

        if (self.server_config.whitelist_enabled and !policy.whitelisted) {
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
        self.connections_mutex.lockUncancelable(engine.io);
        const reservation = self.reserve_pending_slot_locked(conn, ip, policy.op, engine.io);
        self.connections_mutex.unlock(engine.io);

        switch (reservation) {
            .accepted => |slot| {
                log.info("Staging pending login from {s}", .{ip});
                self.tasks.concurrent(engine.io, pending_login_loop, .{ self, slot, engine }) catch |err| {
                    log.err("Failed to spawn pending-login task: {}", .{err});
                    self.connections_mutex.lockUncancelable(engine.io);
                    slot.worker_done = true; // No worker acquired this reservation.
                    release_slot_locked(slot, engine);
                    self.connections_mutex.unlock(engine.io);
                };
            },
            .pending_full => {
                log.info("Pending-login pool full; rejecting {s}", .{ip});
                reject_connection(conn, engine, "Server is busy, try again");
            },
            .ip_limited => {
                log.info("Connection limit reached for {s}", .{ip});
                reject_connection(conn, engine, "Too many connections from your IP");
            },
        }
    }
}

fn console_loop(self: *ServerState, engine: *Engine) std.Io.Cancelable!void {
    const stdin_file = std.Io.File.stdin();
    var reader_scratch: [512]u8 = undefined;
    var file_reader = stdin_file.reader(engine.io, &reader_scratch);
    const r = &file_reader.interface;

    while (engine.running) {
        const raw = r.takeDelimiterExclusive('\n') catch |err| switch (err) {
            error.EndOfStream, error.ReadFailed => return,
            error.StreamTooLong => {
                r.toss(r.bufferedLen());
                continue;
            },
        };
        r.toss(1);

        const line = std.mem.trimEnd(u8, raw, " \t\r");
        if (line.len == 0) continue;

        if (line[0] == '/') {
            const sink: Commands.Sink = .{ .ctx = self, .write_fn = stdout_console_write };
            Commands.dispatch(sink, line[1..], true);
        } else {
            var msg_buf: core.protocol.Message = @splat(' ');
            const prefix = "&4[Server]: ";
            @memcpy(msg_buf[0..prefix.len], prefix);
            const n_msg = @min(line.len, msg_buf.len - prefix.len);
            @memcpy(msg_buf[prefix.len..][0..n_msg], line[0..n_msg]);
            Server.broadcast_chat_message(-1, &msg_buf);
        }
    }
}

fn install_signal_handlers() void {
    if (comptime caps.process.console_control_handler) {
        const windows = std.os.windows;
        const Dword = @field(windows, "DWORD");
        const Bool = @field(windows, "BOOL");
        const ws2_shutdown = struct {
            extern "ws2_32" fn shutdown(s: *anyopaque, how: c_int) callconv(.winapi) c_int;
        }.shutdown;
        const SetConsoleCtrlHandler = struct {
            extern "kernel32" fn SetConsoleCtrlHandler(
                HandlerRoutine: ?*const fn (Dword) callconv(.winapi) Bool,
                Add: Bool,
            ) callconv(.winapi) Bool;
        }.SetConsoleCtrlHandler;
        const handler = struct {
            fn handler(_: Dword) callconv(.winapi) Bool {
                if (global_engine) |e| e.quit();
                if (global_listener) |l| {
                    _ = ws2_shutdown(l.socket.handle, 2);
                }
                return Bool.fromBool(true);
            }
        }.handler;
        _ = SetConsoleCtrlHandler(handler, Bool.fromBool(true));
    } else {
        const Signal = @field(std.posix, "SIG");
        const handler = struct {
            fn handler(_: Signal) callconv(.c) void {
                if (global_engine) |e| e.quit();
                // Shutdown the listener socket to unblock accept().
                if (global_listener) |l| {
                    _ = std.posix.system.shutdown(l.socket.handle, 2);
                }
            }
        }.handler;

        const act: std.posix.Sigaction = .{
            .handler = .{ .handler = handler },
            .mask = std.mem.zeroes(std.posix.sigset_t),
            .flags = 0,
        };
        std.posix.sigaction(@field(Signal, "INT"), &act, null);
        std.posix.sigaction(@field(Signal, "TERM"), &act, null);
    }
}

test "console color stripping preserves literal ampersands" {
    const cases = [_]struct {
        input: []const u8,
        expected: []const u8,
    }{
        .{ .input = "plain", .expected = "plain" },
        .{ .input = "&ehello&r", .expected = "hello" },
        .{ .input = "A&B", .expected = "A&B" },
        .{ .input = "trailing&", .expected = "trailing&" },
        .{ .input = "&e&rtext", .expected = "text" },
    };

    for (cases) |case| {
        var output: [64]u8 = undefined;
        var writer = std.Io.Writer.fixed(&output);
        try write_without_color_codes(&writer, case.input);
        try std.testing.expectEqualStrings(case.expected, writer.buffered());
    }
}

test "pending connection limits include ready and failed logins and active IPs" {
    var pool = [_]ConnectionSlot{.{}} ** 3;
    var self: ServerState = undefined;
    self.connection_pool = &pool;
    self.server_config = ServerConfig.parse("max-pending-logins:1\nmax-connections-per-ip:1\n", 0);
    const io = std.testing.io;
    const stream: std.Io.net.Stream = undefined;

    const first = self.reserve_pending_slot_locked(stream, "203.0.113.1", false, io).accepted;
    try std.testing.expectEqualStrings("203.0.113.1", slot_ip(first));
    try std.testing.expect(!first.worker_done);
    try std.testing.expectEqual(.ip_limited, self.reserve_pending_slot_locked(stream, "203.0.113.1", false, io));
    for ([_]ConnectionState{ .pending, .ready, .failed }) |state_| {
        first.state = state_;
        try std.testing.expectEqual(.pending_full, self.reserve_pending_slot_locked(stream, "203.0.113.2", false, io));
    }

    first.state = .active;
    try std.testing.expectEqual(.ip_limited, self.reserve_pending_slot_locked(stream, "203.0.113.1", false, io));
    const second = self.reserve_pending_slot_locked(stream, "203.0.113.2", true, io).accepted;
    try std.testing.expect(first != second);
    try std.testing.expect(second.data.is_op);
    try std.testing.expectEqualStrings("203.0.113.1", slot_ip(first));
    try std.testing.expectEqual(.pending_full, self.reserve_pending_slot_locked(stream, "203.0.113.3", false, io));
}
