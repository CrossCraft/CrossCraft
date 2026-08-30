const std = @import("std");
const builtin = @import("builtin");
const ae = @import("aether");
const game = @import("game");

const Util = ae.Util;
const Engine = ae.Engine;
const State = ae.Core.State;

const Server = game.Server;
const CompressWorker = game.CompressWorker;
const CompressorThread = @import("CompressorThread.zig");
const Heartbeat = @import("Heartbeat.zig");
const Backup = @import("Backup.zig");
const PlayersDb = game.PlayersDb;
const AccessControl = game.AccessControl;
const Commands = game.Commands;
const outbound_queue = game.OutboundQueue;
const Consts = game.consts;

const log = std.log.scoped(.server);
const sdk = if (ae.platform == .psp) @import("pspsdk") else void;

const SERVER_PORT: u16 = 25565;
const HEARTBEAT_INTERVAL_MS: i64 = 45_000;
const SALT_ALPHABET = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";
const LOGIN_FRAME_LEN: usize = 131;

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
    /// Bounded per-client outbound backlog. The buffer is allocated when the
    /// login is admitted and freed in `release_slot_locked`; producers only
    /// ever append here, never write to the socket.
    out_queue: outbound_queue.OutboundQueue,
    transport: std.atomic.Value(Server.Client.TransportState),
    ip: [PlayersDb.ip_str_len:0]u8,
    is_op: bool,
    closed: bool = false,
};

/// A connection always lives at one stable address. The pending reader can
/// therefore prefetch bytes beyond the login frame without losing them when
/// the record becomes an active client connection.
const ConnectionSlot = struct {
    data: ConnectionData = undefined,
    state: ConnectionState = .free,
    worker_done: bool = true,
    pending_index: ?usize = null,
    active_index: ?usize = null,
    login: Server.LoginRequest = undefined,
    player_handle: ?Server.PlayerHandle = null,
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
var stdout_mutex: std.Io.Mutex = .init;

const Self = @This();

conn_handles: []?*ConnectionSlot,
pending_handles: []?*ConnectionSlot,
connection_pool: []ConnectionSlot,
connections_mutex: std.Io.Mutex,
tasks: std.Io.Group,
listener: std.Io.net.Server,
compressor_thread: CompressorThread.Thread,
heartbeat_config: Heartbeat.Config,
heartbeat_salt: [16]u8,
heartbeat_users: std.atomic.Value(u32),
backup: Backup,

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

    self.tasks = .init;
    self.connections_mutex = .init;
    self.heartbeat_users = .init(0);
    stdout_mutex = .init;

    const seed: u64 = @bitCast(@as(i64, @truncate(std.Io.Clock.Timestamp.now(engine.io, .boot).raw.nanoseconds)));
    const config: Server.GameConfig = .{
        .standalone = .{
            .world = .{ .seed = seed, .save_location = Server.default_save_location },
        },
    };
    // Validate the save before the world materialises; a missing or corrupt
    // primary is transparently replaced with the newest valid epoch backup.
    Backup.pre_init_validate_and_restore(engine.io, engine.dirs.data, alloc);
    try Server.init(alloc, alloc, engine.io, engine.dirs.data, config);

    self.conn_handles = try alloc.alloc(?*ConnectionSlot, Consts.MAX_PLAYERS);
    errdefer alloc.free(self.conn_handles);
    @memset(self.conn_handles, null);

    const pending_len: usize = @intCast(Server.max_pending_logins);
    self.pending_handles = try alloc.alloc(?*ConnectionSlot, pending_len);
    errdefer alloc.free(self.pending_handles);
    @memset(self.pending_handles, null);

    self.connection_pool = try alloc.alloc(ConnectionSlot, Consts.MAX_PLAYERS + pending_len);
    errdefer alloc.free(self.connection_pool);
    for (self.connection_pool) |*slot| slot.* = .{};

    // Dedicated thread for world compression -- shared across world-send
    // (network) and world-save (disk). Off-loads save dispatch from
    // std.Io task spawning and keeps deep `flate` call frames out of small
    // per-task IO stacks.
    self.compressor_thread = try CompressorThread.spawn(alloc);

    // Backup owns the save cadence on the standalone server: it triggers a
    // world save every `backup-autosave-seconds` and snapshots each
    // completed save into the epoch buckets.
    self.backup = Backup.init(engine.io, engine.dirs.data);
    self.tasks.concurrent(engine.io, Backup.loop, .{ &self.backup, engine }) catch |err| {
        log.err("Failed to start backup task: {}", .{err});
        return err;
    };

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

    // Publish console state before any connection task can broadcast chat.
    const stdout_file = platform_stdout();
    stdout_writer = stdout_file.writer(engine.io, &stdout_buf);
    stdout_iface = &stdout_writer.interface;
    Server.on_broadcast_chat = stdout_chat_hook;

    self.tasks.concurrent(engine.io, accept_loop, .{ self, engine }) catch unreachable;
    if (self.heartbeat_config.count > 0) {
        self.tasks.concurrent(engine.io, heartbeat_loop, .{ self, engine }) catch |err| {
            log.err("Failed to start heartbeat sender: {}", .{err});
            return err;
        };
    }

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
    const engine = global_engine orelse return;
    stdout_mutex.lockUncancelable(engine.io);
    defer stdout_mutex.unlock(engine.io);
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
    self.reap_finished_connections(engine);
    self.promote_ready_logins(engine);

    if (self.heartbeat_config.count > 0) {
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
    return std.mem.sliceTo(slot.data.ip[0..], 0);
}

fn count_connections_for_ip_locked(self: *Self, ip: []const u8) usize {
    var count: usize = 0;

    for (self.pending_handles) |maybe_slot| {
        const slot = maybe_slot orelse continue;
        if (slot.state != .free and std.mem.eql(u8, slot_ip(slot), ip)) count += 1;
    }
    for (self.conn_handles) |maybe_slot| {
        const slot = maybe_slot orelse continue;
        if (slot.state != .free and std.mem.eql(u8, slot_ip(slot), ip)) count += 1;
    }

    return count;
}

fn reserve_pending_slot_locked(
    self: *Self,
    conn: std.Io.net.Stream,
    ip: []const u8,
    is_op: bool,
    engine: *Engine,
) PendingReservation {
    if (count_connections_for_ip_locked(self, ip) >= Server.max_connections_per_ip)
        return .ip_limited;

    const pending_index = for (self.pending_handles, 0..) |entry, index| {
        if (entry == null) break index;
    } else return .pending_full;

    const slot = for (self.connection_pool) |*candidate| {
        if (candidate.state == .free) break candidate;
    } else return .pending_full;

    slot.* = .{
        .data = .{
            .stream = conn,
            .reader = undefined,
            .writer = undefined,
            .read_buffer = @splat(0),
            .write_buffer = @splat(0),
            .out_queue = .{},
            .transport = .init(.open),
            .ip = std.mem.zeroes([PlayersDb.ip_str_len:0]u8),
            .is_op = is_op,
        },
        .state = .pending,
        .worker_done = false,
        .pending_index = pending_index,
    };
    const ip_len = @min(ip.len, PlayersDb.ip_str_len);
    @memcpy(slot.data.ip[0..ip_len], ip[0..ip_len]);
    slot.data.reader = std.Io.net.Stream.Reader.init(conn, engine.io, &slot.data.read_buffer);
    slot.data.writer = std.Io.net.Stream.Writer.init(conn, engine.io, &slot.data.write_buffer);
    self.pending_handles[pending_index] = slot;

    return .{ .accepted = slot };
}

fn release_slot_locked(self: *Self, slot: *ConnectionSlot, engine: *Engine) void {
    if (slot.pending_index) |index| {
        self.pending_handles[index] = null;
        slot.pending_index = null;
    }
    if (slot.active_index) |index| {
        self.conn_handles[index] = null;
        slot.active_index = null;
    }
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
    if (slot.data.closed) return;
    game.protocol.send_disconnect_to_client(&slot.data.writer.interface, reason) catch {};
    slot.data.stream.close(engine.io);
    slot.data.closed = true;
    slot.data.transport.store(.closed, .release);
}

fn finish_pending_worker(self: *Self, slot: *ConnectionSlot, engine: *Engine) void {
    self.connections_mutex.lockUncancelable(engine.io);
    defer self.connections_mutex.unlock(engine.io);

    if (slot.state == .pending) slot.state = .failed;
    slot.worker_done = true;
}

fn finish_active_worker(self: *Self, slot: *ConnectionSlot, engine: *Engine) void {
    self.connections_mutex.lockUncancelable(engine.io);
    defer self.connections_mutex.unlock(engine.io);

    if (slot.state == .active) slot.worker_done = true;
}

fn reap_finished_connections(self: *Self, engine: *Engine) void {
    self.connections_mutex.lockUncancelable(engine.io);
    defer self.connections_mutex.unlock(engine.io);

    for (self.pending_handles) |maybe_slot| {
        const slot = maybe_slot orelse continue;
        if (slot.state == .failed and slot.worker_done) {
            release_slot_locked(self, slot, engine);
        }
    }

    for (self.conn_handles, 0..) |maybe_slot, index| {
        const slot = maybe_slot orelse continue;
        if (slot.state == .active and slot.worker_done and slot.data.transport.load(.acquire) == .closed) {
            log.info("Connection in slot {d} disconnected", .{index});
            if (slot.player_handle) |handle| Server.remove_client(handle);
            slot.player_handle = null;
            release_slot_locked(self, slot, engine);
        }
    }
}

fn promote_ready_logins(self: *Self, engine: *Engine) void {
    self.connections_mutex.lockUncancelable(engine.io);
    defer self.connections_mutex.unlock(engine.io);

    for (self.pending_handles, 0..) |maybe_slot, pending_index| {
        const slot = maybe_slot orelse continue;
        if (slot.state != .ready or !slot.worker_done) continue;

        const active_index = for (self.conn_handles, 0..) |entry, index| {
            if (entry == null) break index;
        } else {
            log.info("&4Server full, rejecting completed login", .{});
            reject_slot_locked(slot, engine, "Server is full!");
            release_slot_locked(self, slot, engine);
            continue;
        };

        // Allocate the outbound queue now that the login consumes a real
        // player slot; pre-allocating for every pending socket would waste
        // memory on connections that never finish logging in.
        slot.data.out_queue.buf = engine.allocator(.user).alloc(u8, outbound_queue.out_queue_bytes) catch {
            log.err("Failed to allocate outbound queue, rejecting completed login", .{});
            reject_slot_locked(slot, engine, "Server error, try again");
            release_slot_locked(self, slot, engine);
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
                release_slot_locked(self, slot, engine);
                continue;
            },
            .accepted => |accepted| accepted,
        };

        self.pending_handles[pending_index] = null;
        slot.pending_index = null;
        self.conn_handles[active_index] = slot;
        slot.active_index = active_index;
        slot.state = .active;
        slot.worker_done = false;
        slot.player_handle = .{ .id = @intCast(client.id), .generation = client.generation };

        self.tasks.concurrent(engine.io, client_login_loop, .{ self, slot, client, engine }) catch {
            log.err("Failed to spawn login task for slot {d}", .{active_index});
            client.mark_closed();
            slot.worker_done = true;
        };
    }
}

fn wait_for_login_frame(reader: *std.Io.Reader) std.Io.Reader.Error!void {
    _ = try reader.peek(LOGIN_FRAME_LEN);
}

fn wait_for_login_timeout(io: std.Io, timeout_ms: u32) std.Io.Cancelable!void {
    try io.sleep(.{ .nanoseconds = @as(i96, timeout_ms) * std.time.ns_per_ms }, .real);
}

const LoginRaceResult = union(enum) {
    read: std.Io.Reader.Error!void,
    timeout: std.Io.Cancelable!void,
};

fn pending_login_loop(self: *Self, slot: *ConnectionSlot, engine: *Engine) std.Io.Cancelable!void {
    defer finish_pending_worker(self, slot, engine);

    const LoginSelect = std.Io.Select(LoginRaceResult);
    var result_buffer: [2]LoginRaceResult = undefined;
    var select = LoginSelect.init(engine.io, &result_buffer);
    defer select.cancelDiscard();

    select.concurrent(.read, wait_for_login_frame, .{&slot.data.reader.interface}) catch |err| {
        log.err("Failed to schedule pending login read: {}", .{err});
        return;
    };
    select.concurrent(.timeout, wait_for_login_timeout, .{ engine.io, Server.login_timeout_ms }) catch |err| {
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

            const frame = slot.data.reader.interface.peek(LOGIN_FRAME_LEN) catch |err| {
                log.info("Pending login frame disappeared: {}", .{err});
                return;
            };
            const request = Server.parse_login_frame(frame) catch |err| {
                log.info("Rejecting malformed login: {}", .{err});
                return;
            };
            slot.data.reader.interface.toss(LOGIN_FRAME_LEN);

            self.connections_mutex.lockUncancelable(engine.io);
            if (slot.state == .pending) {
                slot.login = request;
                slot.state = .ready;
                slot.worker_done = true;
            }
            self.connections_mutex.unlock(engine.io);
        },
        .timeout => |timeout_result| {
            timeout_result catch |err| switch (err) {
                error.Canceled => return error.Canceled,
            };
            log.info("Pending login timed out after {d} ms", .{Server.login_timeout_ms});
        },
    }
}

fn client_login_loop(
    self: *Self,
    slot: *ConnectionSlot,
    client: *Server.Client,
    engine: *Engine,
) std.Io.Cancelable!void {
    defer finish_active_worker(self, slot, engine);

    client.finish_login() catch |err| {
        client.mark_closed();
        if (err == error.Canceled) return error.Canceled;
        // The reaper waits for this task's worker_done publication before it
        // removes the generation-checked player entry. Do not add accesses
        // after the task returns and publishes that completion.
        log.info("Login failed: {}", .{err});
        return;
    };
    client.read_loop();
}

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
    Server.lock_roster_shared();
    defer Server.unlock_roster_shared();
    for (Server.players.items) |maybe_client| {
        if (maybe_client) |client| {
            if (client.initialized and client.is_connected()) count += 1;
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

    // The backup task is dead above; its state holds no owned handles (the
    // save dir is borrowed from the game module, buckets open per op).
    self.backup.deinit();

    self.connections_mutex.lockUncancelable(engine.io);
    for (self.connection_pool) |*slot| {
        if (slot.state != .free) self.release_slot_locked(slot, engine);
    }
    self.connections_mutex.unlock(engine.io);

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

    engine.allocator(.user).free(self.connection_pool);
    engine.allocator(.user).free(self.pending_handles);
    engine.allocator(.user).free(self.conn_handles);

    Server.on_broadcast_chat = null;
    stdout_iface = null;
    global_engine = null;
}

fn reject_connection(conn: std.Io.net.Stream, engine: *Engine, reason: []const u8) void {
    var write_buf: [128]u8 = undefined;
    var writer = std.Io.net.Stream.Writer.init(conn, engine.io, &write_buf);
    game.protocol.send_disconnect_to_client(&writer.interface, reason) catch {};
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
        self.connections_mutex.lockUncancelable(engine.io);
        const reservation = self.reserve_pending_slot_locked(conn, ip, policy.op, engine);
        self.connections_mutex.unlock(engine.io);

        switch (reservation) {
            .accepted => |slot| {
                log.info("Staging pending login from {s}", .{ip});
                self.tasks.concurrent(engine.io, pending_login_loop, .{ self, slot, engine }) catch |err| {
                    log.err("Failed to spawn pending-login task: {}", .{err});
                    self.connections_mutex.lockUncancelable(engine.io);
                    self.release_slot_locked(slot, engine);
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
