const std = @import("std");
const zb = @import("protocol");
const Protocol = zb.Protocol;
const common = @import("common");
const c = common.consts;
const world = @import("world.zig");
const proto = common.protocol;

const Server = @import("server.zig");
const compress_worker = @import("compress_worker.zig");
const players_db = @import("players_db.zig");
const commands = @import("commands.zig");
const outbound_queue = @import("outbound_queue.zig");
const OutboundQueue = outbound_queue.OutboundQueue;

/// Largest to-client packet is the 1028-byte LevelDataChunk; round up so
/// any serialized packet fits the staging buffer.
const packet_buf_bytes = 1100;
/// Stack buffer used when draining the outbound queue to the socket.
const drain_buf_bytes = 64 * 1024;
/// Caps how long queued outbound data waits while the client is silent;
/// aligned with the 20 Hz (50 ms) tick.
const recv_poll_timeout: std.Io.Timeout = .{ .duration = .{ .raw = .fromMilliseconds(25), .clock = .real } };
/// Inbound accumulation buffer for the connection loop. The largest
/// to-server packet is the 131-byte login frame and any invalid byte
/// disconnects immediately, so a full buffer can never deadlock.
const in_buf_bytes = 4096;

/// World-send job submitted by an IO read loop and processed by the shared
/// compressor worker. One slot per player; the slots outlive any individual
/// `Client` so a late-arriving worker store after the IO thread bails on
/// cancel never lands on a freed stack frame.
const WorldSendJob = struct {
    base: compress_worker.Job,
    client: *Self,
};
var jobs: [c.MAX_PLAYERS]WorldSendJob = undefined;

const Self = @This();

const ConnectionPhase = enum(u8) {
    awaiting_login,
    handshaking,
    active,
    closing,
};

pub const TransportState = enum(u8) {
    open,
    closing,
    closed,
};

const CatchupMode = enum(u8) {
    none,
    capturing,
    direct,
};

pub const PlayerPose = packed struct(u64) {
    x: u16,
    y: u16,
    z: u16,
    yaw: u8,
    pitch: u8,
};

/// Cross-platform whole-pose publication. PSP/MIPS cannot issue 64-bit atomic
/// operations, so a sequence counter brackets two 32-bit atomic words. There
/// is one pose writer per client; readers retry if they overlap that writer.
pub const AtomicPlayerPose = struct {
    sequence: std.atomic.Value(u32),
    low: std.atomic.Value(u32),
    high: std.atomic.Value(u32),

    pub fn init(pose: PlayerPose) AtomicPlayerPose {
        const bits: u64 = @bitCast(pose);
        return .{
            .sequence = .init(0),
            .low = .init(@truncate(bits)),
            .high = .init(@truncate(bits >> 32)),
        };
    }

    pub fn store(self: *AtomicPlayerPose, pose: PlayerPose) void {
        const bits: u64 = @bitCast(pose);
        _ = self.sequence.fetchAdd(1, .acq_rel);
        self.low.store(@truncate(bits), .monotonic);
        self.high.store(@truncate(bits >> 32), .monotonic);
        _ = self.sequence.fetchAdd(1, .release);
    }

    pub fn load(self: *const AtomicPlayerPose) PlayerPose {
        while (true) {
            const before = self.sequence.load(.acquire);
            if (before & 1 != 0) {
                std.atomic.spinLoopHint();
                continue;
            }
            const low = self.low.load(.monotonic);
            const high = self.high.load(.monotonic);
            const after = self.sequence.load(.acquire);
            if (before == after) {
                const bits = @as(u64, high) << 32 | low;
                return @bitCast(bits);
            }
        }
    }
};

/// The parts of a PlayerIDToServer frame needed before a Client exists in the
/// server player table. Keeping this small lets the network host validate and
/// stage a login without giving an unauthenticated socket a player slot.
pub const LoginRequest = struct {
    protocol_version: u8,
    username: [64]u8,
};

pub const LoginName = struct {
    value: [16:0]u8,
    len: u8,
};

id: i8,
generation: u32,
pose: AtomicPlayerPose,

reader: *std.Io.Reader,
writer: *std.Io.Writer,
connected: *bool,
/// Remote connections publish transport closure across the socket, tick, and
/// console threads. Local singleplayer continues to use `connected` directly.
transport: ?*std.atomic.Value(TransportState),

/// Remote clients only: producers serialize packets into this queue and the
/// client's own connection thread writes them to `stream`. Null for local
/// (singleplayer) clients, which keep direct memory-writer sends.
out: ?*OutboundQueue,
stream: ?*std.Io.net.Stream,

name: [16:0]u8,
name_len: u8,
initialized: bool,
phase: std.atomic.Value(ConnectionPhase),
local: bool,
is_op: std.atomic.Value(bool),
catchup_mode: std.atomic.Value(CatchupMode),
ip: [players_db.ip_str_len:0]u8,
protocol: Protocol,

buffer: [1024]u8,

/// Streams gzip-compressed data as 1024-byte LevelDataChunk protocol packets.
/// Packets are appended to the client's outbound queue -- the compress worker
/// never touches a socket, so a slow joiner fails its own login instead of
/// stalling world compression for everyone.
const ChunkSender = struct {
    interface: std.Io.Writer,
    out: *OutboundQueue,
    raw_written: u32,
    total_raw: u32,

    fn init(out: *OutboundQueue, chunk_buffer: *[1024]u8, total_raw: u32) ChunkSender {
        return .{
            .interface = .{
                .vtable = &.{
                    .drain = drain,
                },
                .buffer = chunk_buffer,
            },
            .out = out,
            .raw_written = 0,
            .total_raw = total_raw,
        };
    }

    fn percent(cs: *const ChunkSender) u8 {
        if (cs.total_raw == 0) return 100;
        const pct = @min((@as(u64, cs.raw_written) * 100) / cs.total_raw, 100);
        return @intCast(pct);
    }

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        _ = splat;
        const cs: *ChunkSender = @alignCast(@fieldParentPtr("interface", w));
        const CHUNK: usize = 1024;

        var chunk: [CHUNK]u8 = @splat(0);
        var filled: usize = 0;

        if (w.end > 0) {
            @memcpy(chunk[0..w.end], w.buffer[0..w.end]);
            filled = w.end;
        }

        for (data) |bytes| {
            const space = CHUNK - filled;
            if (space == 0) break;
            const n = @min(bytes.len, space);
            @memcpy(chunk[filled..][0..n], bytes[0..n]);
            filled += n;
        }

        var packet_buf: [1028]u8 = undefined;
        var packet_writer = std.Io.Writer.fixed(&packet_buf);
        proto.send_level_chunk_to_client(&packet_writer, @intCast(filled), &chunk, cs.percent()) catch
            return error.WriteFailed;
        cs.out.append(Server.io, packet_writer.buffered()) catch
            return error.WriteFailed;

        return w.consume(filled);
    }
};

const log = std.log.scoped(.client);

fn ctx_to_client(ctx: *anyopaque) *Self {
    return @ptrCast(@alignCast(ctx));
}

pub fn load_pose(self: *const Self) PlayerPose {
    return self.pose.load();
}

fn store_pose(self: *Self, pose: PlayerPose) void {
    self.pose.store(pose);
}

pub fn is_connected(self: *const Self) bool {
    if (self.transport) |transport| return transport.load(.acquire) != .closed;
    return self.connected.*;
}

fn accepts_packets(self: *const Self) bool {
    if (self.transport) |transport| return transport.load(.acquire) == .open;
    return self.connected.*;
}

pub fn mark_closed(self: *Self) void {
    if (self.transport) |transport| {
        transport.store(.closed, .release);
    } else {
        self.connected.* = false;
    }
}

pub fn login_name(request: LoginRequest) LoginName {
    var result: LoginName = .{
        .value = @splat(' '),
        .len = 16,
    };

    for (0..result.value.len) |i| {
        if (request.username[i] == ' ') {
            result.len = @intCast(i);
            break;
        }
        result.value[i] = request.username[i];
    }

    return result;
}

/// Initialise a client that has already completed the transport-level login
/// frame. The caller must add it to `Server.players` and call `init` on the
/// stored entry before starting its read loop; `Protocol.init` keeps a pointer
/// to its client context.
pub fn init_remote_admitted(
    self: *Self,
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,
    transport: *std.atomic.Value(TransportState),
    out: *OutboundQueue,
    stream: *std.Io.net.Stream,
    ip: []const u8,
    is_op: bool,
    request: LoginRequest,
) void {
    const name = login_name(request);

    self.connected = undefined;
    self.transport = transport;
    self.reader = reader;
    self.writer = writer;
    self.out = out;
    self.stream = stream;
    self.initialized = false;
    self.phase = .init(.handshaking);
    self.local = false;
    self.is_op = .init(is_op);
    self.catchup_mode = .init(.none);
    self.ip = std.mem.zeroes([players_db.ip_str_len:0]u8);
    const ip_n = @min(ip.len, players_db.ip_str_len);
    @memcpy(self.ip[0..ip_n], ip[0..ip_n]);
    self.name = name.value;
    self.name_len = name.len;
    self.id = -1;
    self.generation = 0;
    self.pose = .init(@bitCast(@as(u64, 0)));
}

fn read_packet(self: *Self, reader: *std.Io.Reader) !bool {
    const packet_id = try reader.peekByte();
    const len = try proto.packet_length_to_server(packet_id);

    const buffer = try reader.peek(len);
    @memcpy(self.buffer[0..len], buffer);

    reader.toss(len);
    return true;
}

fn packet_allowed(phase: ConnectionPhase, packet_id: u8) bool {
    return switch (phase) {
        .awaiting_login => packet_id == 0x00,
        .active => switch (packet_id) {
            0x05, 0x08, 0x0D => true,
            else => false,
        },
        .handshaking, .closing => false,
    };
}

fn reject_protocol(self: *Self, reason: []const u8) void {
    if (self.phase.swap(.closing, .acq_rel) == .closing) return;
    self.send_disconnect(reason) catch self.mark_closed();
}

fn require_active(self: *Self) bool {
    if (self.phase.load(.acquire) == .active) return true;
    self.reject_protocol("Unexpected packet before login");
    return false;
}

fn process_packet(self: *Self, reader: *std.Io.Reader) !bool {
    if (!self.accepts_packets()) return false;

    // Check the phase before asking the generated protocol layer for a packet
    // length. That guarantees any unexpected byte, including an unknown ID,
    // gets an explicit disconnect without reaching the decoder or dispatcher.
    const packet_id = try reader.peekByte();
    if (!packet_allowed(self.phase.load(.acquire), packet_id)) {
        self.reject_protocol("Protocol state violation");
        return false;
    }

    const received = try self.read_packet(reader);
    if (!received) return false;

    try self.protocol.handle_packet(self.buffer[1..], self.buffer[0]);
    return true;
}

/// Serialize one packet and hand it to the right sink. Remote clients get it
/// queued for their own connection thread to write (a full queue kicks the
/// slow client); local clients keep the direct memory-writer write + flush.
fn send_packet(self: *Self, comptime send_fn: anytype, args: anytype) !void {
    if (self.out) |q| {
        var buf: [packet_buf_bytes]u8 = undefined;
        var fixed = std.Io.Writer.fixed(&buf);
        try @call(.auto, send_fn, .{&fixed} ++ args);
        q.append(Server.io, fixed.buffered()) catch {
            self.kick_slow();
            return error.QueueFull;
        };
    } else {
        try @call(.auto, send_fn, .{self.writer} ++ args);
        try self.writer.flush();
    }
}

/// Kick a client whose outbound queue overflowed: it is reading too slowly
/// and must never be waited on. Shutting the stream down unblocks the
/// connection thread's pending receive.
pub fn kick_slow(self: *Self) void {
    const was_connected = self.is_connected();
    self.mark_closed();
    if (self.stream) |s| s.shutdown(Server.io, .both) catch {};
    if (was_connected) {
        log.info("Kicking {s} ({s}): outbound queue full (slow client)", .{ self.name[0..self.name_len], self.ip_slice() });
    }
}

/// Write all queued outbound bytes to the socket. Runs only on the client's
/// own connection thread, so a stuck peer blocks nobody else. The queue
/// mutex is released before each socket write.
fn drainOutbound(self: *Self) void {
    const q = self.out orelse return;
    var buf: [drain_buf_bytes]u8 = undefined;
    var wrote_any = false;
    while (true) {
        const n = q.take(Server.io, &buf);
        if (n == 0) break;
        wrote_any = true;
        self.writer.writeAll(buf[0..n]) catch {
            self.mark_closed();
            return;
        };
    }
    if (wrote_any) {
        self.writer.flush() catch {
            self.mark_closed();
        };
    }
}

pub fn send_message(self: *Self, id: i8, message: []u8) !void {
    const pid: i8 = if (id == self.id) -1 else id;
    try self.send_packet(proto.send_message, .{ pid, message });
}

pub fn send_disconnect(self: *Self, reason: []const u8) !void {
    self.phase.store(.closing, .release);
    if (self.out) |q| {
        // Callers include foreign threads (console /kick, /ban), so never
        // touch the socket here: queue the packet best-effort and let the
        // client's own thread drain it before teardown.
        var buf: [packet_buf_bytes]u8 = undefined;
        var fixed = std.Io.Writer.fixed(&buf);
        try proto.send_disconnect_to_client(&fixed, reason);
        q.append(Server.io, fixed.buffered()) catch {};
        if (self.transport) |transport| {
            _ = transport.cmpxchgStrong(.open, .closing, .release, .acquire);
        }
        return;
    }
    try proto.send_disconnect_to_client(self.writer, reason);
    self.connected.* = false;
}

pub fn send_ping(self: *Self) !void {
    try self.send_packet(write_ping_byte, .{});
}

fn write_ping_byte(writer: *std.Io.Writer) !void {
    try writer.writeByte(0x01);
}

pub fn send_player_position(self: *Self, id: i8, x: u16, y: u16, z: u16, yaw: u8, pitch: u8) !void {
    try self.send_packet(proto.send_position_to_client, .{ id, x, y, z, yaw, pitch });
}

pub fn send_spawn(ctx: *Self, packet: *zb.SpawnPlayer) !void {
    const self: *Self = @ptrCast(@alignCast(ctx));
    try self.send_packet(proto.send_spawn_to_client, .{packet});
}

pub fn send_despawn(self: *Self, id: i8) !void {
    try self.send_packet(proto.send_despawn_to_client, .{id});
}

pub fn send_block_change(self: *Self, x: u16, y: u16, z: u16, block: c.Block) !void {
    try self.send_packet(proto.send_block_change_to_client, .{ x, y, z, block });
}

pub fn send_update_player_type(self: *Self, is_op: bool) !void {
    try self.send_packet(proto.send_update_player_type_to_client, .{is_op});
}

fn send_world(self: *Self) !void {
    try self.send_packet(proto.send_level_initialize_to_client, .{});
    self.drainOutbound();

    if (self.local) {
        // Local client reads World.blocks directly - no chunks needed.
        try proto.send_level_finalize_to_client(self.writer, c.WorldLength, c.WorldHeight, c.WorldDepth);
        try self.writer.flush();
        return;
    }

    const job = &jobs[@intCast(self.id)];
    job.* = .{
        .base = .{ .run = world_send_run },
        .client = self,
    };
    compress_worker.submit(&job.base);
    // The worker streams chunks into the outbound queue; keep draining so a
    // slow peer stalls only this thread, never the compressor.
    var canceled = false;
    while (!job.base.done.load(.acquire)) {
        self.drainOutbound();
        if (canceled) {
            std.atomic.spinLoopHint();
        } else {
            Server.io.sleep(.fromMilliseconds(50), .real) catch |err| switch (err) {
                error.Canceled => {
                    // Keep the Client, connection slot, and outbound storage
                    // alive until the raw compressor thread has dropped every
                    // reference. Deinit may cancel the IO task first.
                    canceled = true;
                    self.mark_closed();
                },
            };
        }
    }
    self.drainOutbound();
    if (canceled) return error.Canceled;
    if (job.base.err) |e| return e;
}

fn world_send_run(base: *compress_worker.Job) anyerror!void {
    const job: *WorldSendJob = @fieldParentPtr("base", base);
    try send_world_impl(job.client);
}

fn send_world_impl(self: *Self) !void {
    var chunk_buf: [1024]u8 = @splat(0);

    const out = self.out orelse return error.WriteFailed;
    const volume: usize = c.WorldLength * c.WorldHeight * c.WorldDepth;
    var sender = ChunkSender.init(out, &chunk_buf, @intCast(volume + 4));
    try compress_worker.reset(&sender.interface);

    // Begin journaling under the exclusive world lock so no mutation can fall
    // between capture activation and the first snapshot copy.
    var size_header: [4]u8 = undefined;
    std.mem.writeInt(u32, &size_header, @intCast(volume), .big);
    Server.lock_world();
    Server.lock_roster_shared();
    self.catchup_mode.store(.capturing, .release);
    Server.unlock_roster_shared();
    Server.unlock_world();

    try compress_worker.compressor.writer.writeAll(&size_header);
    sender.raw_written = 4;

    // Copy a 4 KiB wire-contiguous band under a shared lock, then release the
    // world before doing any compression. A full level uses 1,024 short read
    // sections instead of freezing simulation for the whole gzip operation.
    var band: [c.WorldLength * c.ChunkSize]u8 = undefined;
    for (0..c.WorldHeight) |y| {
        var z: usize = 0;
        while (z < c.WorldDepth) : (z += c.ChunkSize) {
            Server.lock_world_shared();
            world.data.copy_blocks_yzx_band(@intCast(y), @intCast(z), &band);
            Server.unlock_world_shared();
            try compress_worker.compressor.writer.writeAll(&band);
        }
    }
    sender.raw_written = @intCast(volume + 4);
    try compress_worker.compressor.finish();

    // Send any remaining partial chunk as the final packet.
    if (sender.interface.end > 0) {
        var final_chunk: [1024]u8 = @splat(0);
        @memcpy(final_chunk[0..sender.interface.end], sender.interface.buffer[0..sender.interface.end]);
        var packet_buf: [1028]u8 = undefined;
        var packet_writer = std.Io.Writer.fixed(&packet_buf);
        try proto.send_level_chunk_to_client(&packet_writer, @intCast(sender.interface.end), &final_chunk, sender.percent());
        out.append(Server.io, packet_writer.buffered()) catch return error.WriteFailed;
    }

    try self.send_packet(proto.send_level_finalize_to_client, .{ c.WorldLength, c.WorldHeight, c.WorldDepth });

    // LevelFinalize is now in the normal queue. Close the capture gap while
    // mutations are excluded, promote journaled packets behind it, then let
    // future edits append directly even if the peer is still downloading.
    Server.lock_world();
    Server.lock_roster_shared();
    out.promoteCatchup(Server.io);
    self.catchup_mode.store(.direct, .release);
    Server.unlock_roster_shared();
    Server.unlock_world();
}

pub fn ip_slice(self: *const Self) []const u8 {
    return std.mem.sliceTo(self.ip[0..], 0);
}

pub fn handshake(self: *Self) !void {
    try self.send_packet(proto.send_player_id_to_client, .{ &Server.server_name, &Server.server_motd, self.is_op.load(.acquire) });

    try self.send_world();

    var name_buf: c.Message = @splat(' ');
    std.mem.copyForwards(u8, &name_buf, self.name[0..self.name_len]);

    Server.lock_world_shared();
    const spawn = world.find_spawn();
    Server.unlock_world_shared();
    var initial_spawn = zb.SpawnPlayer{
        .pid = -1,
        .name = name_buf,
        .x = spawn[0],
        .y = spawn[1],
        .z = spawn[2],
        .yaw = 0,
        .pitch = 0,
    };
    self.store_pose(.{ .x = initial_spawn.x, .y = initial_spawn.y, .z = initial_spawn.z, .yaw = 0, .pitch = 0 });
    try self.send_packet(proto.send_spawn_to_client, .{&initial_spawn});
    self.drainOutbound();

    // Send existing players to the new joiner before broadcasting the new joiner to others.
    Server.lock_roster_shared();
    for (0..Server.players.items.len) |i| {
        if (Server.players.items[i]) |p| {
            if (p.id == self.id or !p.initialized)
                continue;

            var name_cpy = [_]u8{' '} ** 64;
            std.mem.copyForwards(u8, &name_cpy, &p.name);

            const pose = p.load_pose();
            var player_spawn = zb.SpawnPlayer{
                .pid = p.id,
                .name = name_cpy,
                .x = pose.x,
                .y = pose.y,
                .z = pose.z,
                .yaw = pose.yaw,
                .pitch = pose.pitch,
            };
            try self.send_packet(proto.send_spawn_to_client, .{&player_spawn});
            self.drainOutbound();
        }
    }
    Server.unlock_roster_shared();

    initial_spawn.pid = self.id;

    Server.broadcast_spawn_player(self.id, &initial_spawn);

    const own_pose = self.load_pose();
    try self.send_packet(proto.send_position_to_client, .{ -1, own_pose.x, own_pose.y, own_pose.z, 0, 0 });
    self.drainOutbound();

    // Skip welcome + join-broadcast chat in singleplayer: the lone local
    // player would just be seeing themselves "join" their own world.
    if (!Server.internal_use) {
        var msg_buf: c.Message = @splat(' ');
        std.mem.copyForwards(u8, &msg_buf, "&eWelcome to the world!");

        try self.send_message(self.id, &msg_buf);
        self.drainOutbound();

        msg_buf = @splat(' ');
        _ = std.fmt.bufPrint(&msg_buf, "&e{s} joined the game", .{self.name[0..self.name_len]}) catch unreachable;

        Server.broadcast_chat_message(self.id, &msg_buf);
        self.drainOutbound();
    }
}

pub fn prepare_login(self: *Self, request: LoginRequest) bool {
    // The generated protocol dispatcher has one broad Connected state, so
    // preserve the server's actual login state here as a defense in depth.
    Server.lock_roster();
    defer Server.unlock_roster();
    if (self.phase.load(.acquire) != .awaiting_login or self.initialized) {
        self.reject_protocol("Player ID already received");
        return false;
    }

    if (request.protocol_version != 0x07) {
        self.reject_protocol("Unsupported protocol version!");
        return false;
    }

    const name = login_name(request);
    for (Server.players.items) |maybe_client| {
        if (maybe_client) |p| {
            // Awaiting clients have not chosen a name yet. Handshaking
            // clients do count: their name is reserved until their world
            // transfer succeeds or fails.
            const phase = p.phase.load(.acquire);
            if (p.id == self.id or phase == .awaiting_login or phase == .closing)
                continue;
            if (p.name_len == name.len and std.mem.eql(u8, p.name[0..p.name_len], name.value[0..name.len])) {
                self.reject_protocol("A player with that name is already connected!");
                return false;
            }
        }
    }

    self.name = name.value;
    self.name_len = name.len;
    self.phase.store(.handshaking, .release);
    return true;
}

/// Complete the expensive, output-producing half of a login after the name
/// and player slot have already been reserved.
pub fn finish_login(self: *Self) !void {
    if (self.phase.load(.acquire) != .handshaking or self.initialized) return error.InvalidLoginState;

    self.handshake() catch |err| {
        self.phase.store(.closing, .release);
        self.mark_closed();
        return err;
    };
    Server.lock_roster();
    self.initialized = true;
    self.phase.store(.active, .release);
    Server.unlock_roster();

    const ip = self.ip_slice();
    if (ip.len > 0) players_db.record_completed_login(ip, self.name[0..self.name_len]);
}

fn handle_player(ctx: *anyopaque, event: zb.PlayerIDToServer) !void {
    const self = ctx_to_client(ctx);
    const request: LoginRequest = .{
        .protocol_version = event.protocol_version,
        .username = event.username,
    };

    if (!self.prepare_login(request)) return;
    try self.finish_login();
}

fn handle_position(ctx: *anyopaque, e: zb.PositionAndOrientationToServer) !void {
    const self: *Self = ctx_to_client(ctx);
    if (!require_active(self)) return;

    self.store_pose(.{ .x = e.x, .y = e.y, .z = e.z, .yaw = e.yaw, .pitch = e.pitch });
}

fn handle_message(ctx: *anyopaque, event: zb.Message) !void {
    const self: *Self = @ptrCast(@alignCast(ctx));
    if (!require_active(self)) return;

    // Strip the trailing space-padding the wire format mandates so
    // command parsing sees clean tokens. Done before the dup_buf rewrite
    // below, which mangles the message into "&fname: <text>".
    const trimmed = std.mem.trimEnd(u8, &event.message, " \x00");
    if (trimmed.len > 0 and trimmed[0] == '/') {
        handle_slash_command(self, trimmed[1..]);
        return;
    }

    var dup_buf = [_]u8{' '} ** 64;
    dup_buf[0] = '&';
    dup_buf[1] = 'f';

    var curr_idx: u8 = 2;
    for (0..self.name.len) |i| {
        if (self.name[i] != ' ') {
            dup_buf[i + 2] = self.name[i];
            curr_idx += 1;
        } else {
            break;
        }
    }

    dup_buf[curr_idx] = ':';
    curr_idx += 1;
    dup_buf[curr_idx] = ' ';
    curr_idx += 1;

    for (curr_idx..dup_buf.len, 0..(dup_buf.len - curr_idx)) |i, j| {
        dup_buf[i] = event.message[j];
    }

    // Translate Minecraft's alternate '%' color code prefix to '&'
    // when followed by a valid color code character [0-9a-f].
    for (0..dup_buf.len - 1) |i| {
        if (dup_buf[i] != '%') continue;
        const next = dup_buf[i + 1];
        const is_color = (next >= '0' and next <= '9') or (next >= 'a' and next <= 'f');
        if (is_color) dup_buf[i] = '&';
    }

    Server.broadcast_chat_message(self.id, &dup_buf);
}

fn slash_sink_write(ctx: *anyopaque, line: []const u8) void {
    const self: *Self = @ptrCast(@alignCast(ctx));
    var msg_buf: c.Message = @splat(' ');
    const n = @min(line.len, msg_buf.len);
    @memcpy(msg_buf[0..n], line[0..n]);
    self.send_message(self.id, &msg_buf) catch return;
    self.writer.flush() catch return;
}

fn handle_slash_command(self: *Self, body: []const u8) void {
    const allowed = self.is_op.load(.acquire) or Server.internal_use;
    const sink: commands.Sink = .{ .ctx = self, .write_fn = slash_sink_write };
    commands.dispatch(sink, body, allowed);
}

fn handle_set_block(ctx: *anyopaque, event: zb.SetBlockToServer) !void {
    const self = ctx_to_client(ctx);
    if (!require_active(self)) return;

    Server.lock_world();
    defer Server.unlock_world();
    if (!require_active(self)) return;

    if (event.x >= c.WorldLength or event.y >= c.WorldHeight or event.z >= c.WorldDepth)
        return;

    // Wire byte to typed mode at the protocol boundary. Bare `@enumFromInt`
    // would panic in ReleaseSafe on any value outside {0, 1}, so a single
    // malformed packet from any peer would crash the server.
    const mode = std.enums.fromInt(zb.ClickMode, event.mode) orelse return;

    if (mode == .destroy and event.y == 0)
        return;

    // Convert wire-format u8 to the typed Block at the protocol boundary.
    const block: c.Block = .{ .id = @enumFromInt(event.block) };

    if (mode == .create and block.is_fluid()) {
        return;
    }

    const old_block = world.data.get_block(event.x, event.y, event.z);

    if (mode == .destroy) {
        world.set_block(event.x, event.y, event.z, .{ .id = .air });
        Server.broadcast_block_change(event.x, event.y, event.z, .{ .id = .air });
    } else {
        // Partial blocks can be targeted through their empty subvolume. Only
        // air and fluids are replaceable, except slab + slab promotes in-place.
        if (old_block.id == .slab and block.id == .slab) {
            world.set_block(event.x, event.y, event.z, .{ .id = .double_slab });
            Server.broadcast_block_change(event.x, event.y, event.z, .{ .id = .double_slab });
            world.enqueue_neighbors_of(event.x, event.y, event.z);
            return;
        }
        if (!old_block.is_place_replaceable()) {
            Server.broadcast_block_change(event.x, event.y, event.z, old_block);
            return;
        }

        // Slab-on-slab -> double slab. The originating client (and any other
        // client doing optimistic placement, e.g. ClassiCube) already drew a
        // slab into (x, y, z); re-assert whatever block actually lives at
        // that cell so those predictions are reverted, then upgrade the
        // slab below.
        if (block.id == .slab and event.y > 0) {
            const below = world.data.get_block(event.x, event.y - 1, event.z);
            if (below.id == .slab) {
                Server.broadcast_block_change(event.x, event.y, event.z, old_block);
                world.set_block(event.x, event.y - 1, event.z, .{ .id = .double_slab });
                Server.broadcast_block_change(event.x, event.y - 1, event.z, .{ .id = .double_slab });
                world.enqueue_neighbors_of(event.x, event.y - 1, event.z);
                return;
            }
        }
        world.set_block(event.x, event.y, event.z, block);
        Server.broadcast_block_change(event.x, event.y, event.z, block);
    }
    world.enqueue_neighbors_of(event.x, event.y, event.z);

    if (mode == .create and block.id == .sponge) {
        world.sponge_absorb(Server.immediate_block_change_sink, event.x, event.y, event.z);
    }
    if (mode == .destroy and old_block.id == .sponge) {
        world.sponge_release(event.x, event.y, event.z);
    }
}

pub fn init(self: *Self) void {
    self.protocol = Protocol.init(.client, .Connected, self);
    self.protocol.handles = .{
        .onPlayerIDToServer = handle_player,
        .onPositionAndOrientationToServer = handle_position,
        .onMessage = handle_message,
        .onSetBlockToServer = handle_set_block,
    };
}

/// Non-blocking: read and process one packet if available. Returns true
/// if a packet was processed. Used for singleplayer (same-process) mode
/// where there is no dedicated read thread.
pub fn try_process_packet(self: *Self) bool {
    return self.process_packet(self.reader) catch |err| switch (err) {
        // Non-blocking local reader (FakeConn ring): ReadFailed just means
        // no complete packet is buffered right now -- the normal idle case,
        // not an error.
        error.ReadFailed => false,
        else => {
            log.err("process packet failed for client id={d}: {}", .{ self.id, err });
            return false;
        },
    };
}

pub fn drain_packets(self: *Self) void {
    while (self.try_process_packet()) {}
}

/// Connection loop -- runs on the client's own Io thread pool thread.
/// Interleaves draining the outbound queue with inbound reads so a slow
/// peer only ever stalls this one thread; returns when the connection ends.
pub fn read_loop(self: *Self) void {
    const stream = self.stream orelse {
        // Only remote clients have a connection loop; without a socket
        // there is nothing to interleave reads with.
        self.mark_closed();
        return;
    };

    var inbuf: [in_buf_bytes]u8 = undefined;

    // Salvage bytes the pending-login phase prefetched past the login frame
    // into the Stream.Reader buffer; that reader is not used afterwards.
    const prefetched = self.reader.buffered();
    const prefetched_len = @min(prefetched.len, inbuf.len);
    @memcpy(inbuf[0..prefetched_len], prefetched[0..prefetched_len]);
    var in_len: usize = prefetched_len;

    while (self.is_connected()) {
        self.drainOutbound();
        if (self.transport.?.load(.acquire) == .closing) {
            self.mark_closed();
            stream.shutdown(Server.io, .both) catch {};
            return;
        }

        std.debug.assert(in_len < inbuf.len);
        const msg = stream.socket.receiveTimeout(Server.io, inbuf[in_len..], recv_poll_timeout) catch |err| switch (err) {
            error.Timeout => continue,
            error.Canceled => return,
            else => {
                self.mark_closed();
                return;
            },
        };
        if (msg.data.len == 0) {
            // Orderly EOF.
            self.mark_closed();
            return;
        }
        in_len += msg.data.len;

        var fixed = std.Io.Reader.fixed(inbuf[0..in_len]);
        while (self.accepts_packets()) {
            const processed = self.process_packet(&fixed) catch |err| switch (err) {
                // No complete packet buffered yet; wait for more bytes.
                error.EndOfStream => break,
                else => {
                    self.mark_closed();
                    return;
                },
            };
            if (!processed) {
                self.drainOutbound();
                self.mark_closed();
                stream.shutdown(Server.io, .both) catch {};
                return;
            }
        }
        if (!self.is_connected()) return;
        if (!self.accepts_packets()) continue;

        // Compact the incomplete-packet remainder to the front.
        const remaining = fixed.bufferedLen();
        std.mem.copyForwards(u8, inbuf[0..remaining], inbuf[in_len - remaining .. in_len]);
        in_len = remaining;
    }
}

test "connection phase accepts only phase-valid client packets" {
    try std.testing.expect(packet_allowed(.awaiting_login, 0x00));
    try std.testing.expect(!packet_allowed(.awaiting_login, 0x05));
    try std.testing.expect(!packet_allowed(.handshaking, 0x00));
    try std.testing.expect(!packet_allowed(.active, 0x00));
    try std.testing.expect(packet_allowed(.active, 0x05));
    try std.testing.expect(packet_allowed(.active, 0x08));
    try std.testing.expect(packet_allowed(.active, 0x0D));
    try std.testing.expect(!packet_allowed(.closing, 0x0D));
}

test "duplicate player id disconnects before handshake dispatch" {
    var packet: [131]u8 = @splat(0);
    packet[0] = 0x00;
    var reader = std.Io.Reader.fixed(&packet);
    var output: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output);
    var connected = true;
    var client: Self = undefined;
    client.reader = &reader;
    client.writer = &writer;
    client.connected = &connected;
    client.transport = null;
    client.out = null;
    client.stream = null;
    client.initialized = true;
    client.phase = .init(.active);

    try std.testing.expect(!(try client.process_packet(&reader)));
    try std.testing.expect(!connected);
    try std.testing.expectEqual(@as(u8, 0x0E), writer.buffered()[0]);
}

test "pre-login mutation and chat packets disconnect before dispatch" {
    for ([_]u8{ 0x05, 0x0D }) |packet_id| {
        const packet = [_]u8{packet_id};
        var reader = std.Io.Reader.fixed(&packet);
        var output: [256]u8 = undefined;
        var writer = std.Io.Writer.fixed(&output);
        var connected = true;
        var client: Self = undefined;
        client.reader = &reader;
        client.writer = &writer;
        client.connected = &connected;
        client.transport = null;
        client.out = null;
        client.stream = null;
        client.initialized = false;
        client.phase = .init(.awaiting_login);

        try std.testing.expect(!(try client.process_packet(&reader)));
        try std.testing.expect(!connected);
        try std.testing.expectEqual(@as(u8, 0x0E), writer.buffered()[0]);
    }
}

test "player pose publishes all coordinates as one atomic snapshot" {
    const expected: PlayerPose = .{ .x = 123, .y = 456, .z = 789, .yaw = 42, .pitch = 99 };
    var atomic_pose = AtomicPlayerPose.init(@bitCast(@as(u64, 0)));
    atomic_pose.store(expected);
    const actual = atomic_pose.load();
    try std.testing.expectEqual(expected, actual);
}
