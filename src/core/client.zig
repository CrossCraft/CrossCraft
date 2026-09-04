const std = @import("std");
const zb = @import("protocol");
const Protocol = zb.Protocol;
const blocks = @import("blocks.zig");
const world = @import("world.zig");
const proto = @import("protocol.zig");

const Server = @import("server.zig");
const compress_worker = @import("compress_worker.zig");
const outbound_queue = @import("outbound_queue.zig");
const OutboundQueue = outbound_queue.OutboundQueue;
const Message = proto.Message;
const assert = std.debug.assert;
const Client = @This();

/// Rounded above the 1028-byte LevelDataChunk packet.
const packet_buf_bytes = 1100;
pub const ip_str_len = 15;
const drain_buf_bytes = 64 * 1024;
const recv_poll_timeout: std.Io.Timeout = .{ .duration = .{ .raw = .fromMilliseconds(25), .clock = .real } };
// Larger than any accepted client packet; invalid IDs disconnect immediately.
const in_buf_bytes = 4096;

// Job slots outlive clients so a late completion cannot write to a freed stack.
const WorldSendJob = struct {
    base: compress_worker.Job,
    client: *Client,
};
var jobs: [Server.MaxPlayers]WorldSendJob = undefined;

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

/// Validated before an unauthenticated socket can acquire a player slot.
pub const LoginRequest = struct {
    protocol_version: u8,
    username: [64]u8,
};

pub const LoginName = struct {
    value: [16:0]u8,
    len: u8,
};

id: i8 = -1,
generation: u32 = 0,
pose: AtomicPlayerPose = .init(@bitCast(@as(u64, 0))),

reader: *std.Io.Reader,
writer: *std.Io.Writer,
connected: *bool = undefined,
/// Remote connections publish transport closure across the socket, tick, and
/// console threads. Local singleplayer continues to use `connected` directly.
transport: ?*std.atomic.Value(TransportState) = null,

// Only the connection thread writes to remote sockets; local clients write directly.
out: ?*OutboundQueue = null,
stream: ?*std.Io.net.Stream = null,

name: [16:0]u8 = @splat(' '),
name_len: u8 = 0,
initialized: bool = false,
phase: std.atomic.Value(ConnectionPhase) = .init(.awaiting_login),
local: bool = false,
is_op: std.atomic.Value(bool) = .init(false),
catchup_mode: std.atomic.Value(CatchupMode) = .init(.none),
ip: [ip_str_len:0]u8 = @splat(0),
protocol: Protocol = undefined,

buffer: [1024]u8 = undefined,

// Queue gzip chunks without blocking the shared compressor on a slow socket.
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

fn ctx_to_client(ctx: *anyopaque) *Client {
    return @ptrCast(@alignCast(ctx));
}

pub fn is_connected(self: *const Client) bool {
    if (self.transport) |transport| return transport.load(.acquire) != .closed;
    return self.connected.*;
}

fn accepts_packets(self: *const Client) bool {
    if (self.transport) |transport| return transport.load(.acquire) == .open;
    return self.connected.*;
}

pub fn mark_closed(self: *Client) void {
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

fn reject_protocol(self: *Client, reason: []const u8) void {
    if (self.phase.swap(.closing, .acq_rel) == .closing) return;
    self.send_disconnect(reason) catch self.mark_closed();
}

fn require_active(self: *Client) bool {
    if (self.phase.load(.acquire) == .active) return true;
    self.reject_protocol("Unexpected packet before login");
    return false;
}

fn process_packet(self: *Client, reader: *std.Io.Reader) !bool {
    if (!self.accepts_packets()) return false;

    const packet_id = try reader.peekByte();
    if (!packet_allowed(self.phase.load(.acquire), packet_id)) {
        self.reject_protocol("Protocol state violation");
        return false;
    }

    const len = try proto.packet_length_to_server(packet_id);
    @memcpy(self.buffer[0..len], try reader.peek(len));
    reader.toss(len);
    try self.protocol.handle_packet(self.buffer[1..len], packet_id);
    return true;
}

fn send_packet(self: *Client, comptime send_fn: anytype, args: anytype) !void {
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

// Closing the stream unblocks the connection thread's pending receive.
pub fn kick_slow(self: *Client) void {
    const was_connected = self.is_connected();
    self.mark_closed();
    if (self.stream) |s| s.shutdown(Server.io, .both) catch {};
    if (was_connected) {
        log.info("Kicking {s} ({s}): outbound queue full (slow client)", .{ self.name[0..self.name_len], self.ip_slice() });
    }
}

// Connection thread only; never hold the queue mutex across a socket write.
fn drain_outbound(self: *Client) void {
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

pub fn send_message(self: *Client, id: i8, message: []const u8) !void {
    const pid: i8 = if (id == self.id) -1 else id;
    try self.send_packet(proto.send_message, .{ pid, message });
}

pub fn send_disconnect(self: *Client, reason: []const u8) !void {
    self.phase.store(.closing, .release);
    if (self.out) |q| {
        // Console commands may call this from outside the connection thread.
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

pub fn send_ping(self: *Client) !void {
    try self.send_packet(std.Io.Writer.writeByte, .{@as(u8, 0x01)});
}

pub fn send_player_position(self: *Client, id: i8, x: u16, y: u16, z: u16, yaw: u8, pitch: u8) !void {
    try self.send_packet(proto.send_position_to_client, .{ id, x, y, z, yaw, pitch });
}

pub fn send_spawn(self: *Client, packet: *zb.SpawnPlayer) !void {
    try self.send_packet(proto.send_spawn_to_client, .{packet});
}

pub fn send_despawn(self: *Client, id: i8) !void {
    try self.send_packet(proto.send_despawn_to_client, .{id});
}

pub fn send_block_change(self: *Client, x: u16, y: u16, z: u16, block: blocks.Block) !void {
    try self.send_packet(proto.send_block_change_to_client, .{ x, y, z, block });
}

pub fn send_update_player_type(self: *Client, is_op: bool) !void {
    try self.send_packet(proto.send_update_player_type_to_client, .{is_op});
}

fn send_world(self: *Client) !void {
    try self.send_packet(std.Io.Writer.writeByte, .{@as(u8, 0x02)});
    self.drain_outbound();

    if (self.local) {
        const size = world.data.dims.to_array();
        try proto.send_level_finalize_to_client(self.writer, size[0], size[1], size[2]);
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
    while (!job.base.is_done()) {
        self.drain_outbound();
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
    self.drain_outbound();
    if (canceled) return error.Canceled;
    if (job.base.err) |e| return e;
}

fn world_send_run(base: *compress_worker.Job) anyerror!void {
    const job: *WorldSendJob = @fieldParentPtr("base", base);
    try send_world_impl(job.client);
}

fn send_world_impl(self: *Client) !void {
    var chunk_buf: [1024]u8 = @splat(0);

    const out = self.out orelse return error.WriteFailed;
    const dims = world.data.dims;
    const volume = dims.volume();
    var sender = ChunkSender.init(out, &chunk_buf, @intCast(volume + 4));
    try compress_worker.reset(&sender.interface);

    // Begin journaling under the exclusive world lock so no mutation can fall
    // between capture activation and the first snapshot copy.
    var size_header: [4]u8 = undefined;
    std.mem.writeInt(u32, &size_header, @intCast(volume), .big);
    world.lock_world();
    Server.lock_roster_shared();
    self.catchup_mode.store(.capturing, .release);
    Server.unlock_roster_shared();
    world.unlock_world();

    try compress_worker.compressor.writer.writeAll(&size_header);
    sender.raw_written = 4;

    try world.data.write_blocks_yzx(Server.io, &compress_worker.compressor.writer);
    sender.raw_written = @intCast(volume + 4);
    try compress_worker.compressor.finish();

    if (sender.interface.end > 0) {
        var final_chunk: [1024]u8 = @splat(0);
        @memcpy(final_chunk[0..sender.interface.end], sender.interface.buffer[0..sender.interface.end]);
        var packet_buf: [1028]u8 = undefined;
        var packet_writer = std.Io.Writer.fixed(&packet_buf);
        try proto.send_level_chunk_to_client(&packet_writer, @intCast(sender.interface.end), &final_chunk, sender.percent());
        out.append(Server.io, packet_writer.buffered()) catch return error.WriteFailed;
    }

    const size = dims.to_array();
    try self.send_packet(proto.send_level_finalize_to_client, .{ size[0], size[1], size[2] });

    // LevelFinalize is now in the normal queue. Close the capture gap while
    // mutations are excluded, promote journaled packets behind it, then let
    // future edits append directly even if the peer is still downloading.
    world.lock_world();
    Server.lock_roster_shared();
    out.promote_catchup(Server.io);
    self.catchup_mode.store(.direct, .release);
    Server.unlock_roster_shared();
    world.unlock_world();
}

pub fn ip_slice(self: *const Client) []const u8 {
    return std.mem.sliceTo(self.ip[0..], 0);
}

pub fn handshake(self: *Client) !void {
    try self.send_packet(proto.send_player_id_to_client, .{ &Server.server_name, &Server.server_motd, self.is_op.load(.acquire) });

    try self.send_world();

    world.lock_world_shared();
    const spawn = world.find_spawn();
    world.unlock_world_shared();
    var initial_spawn = zb.SpawnPlayer{
        .pid = -1,
        .name = proto.padded_string(self.name[0..self.name_len]),
        .x = spawn[0],
        .y = spawn[1],
        .z = spawn[2],
        .yaw = 0,
        .pitch = 0,
    };
    self.pose.store(.{ .x = initial_spawn.x, .y = initial_spawn.y, .z = initial_spawn.z, .yaw = 0, .pitch = 0 });
    try self.send_packet(proto.send_spawn_to_client, .{&initial_spawn});
    self.drain_outbound();

    // Send existing players to the new joiner before broadcasting the new joiner to others.
    {
        Server.lock_roster_shared();
        defer Server.unlock_roster_shared();

        for (0..Server.players.items.len) |i| {
            const player = &(Server.players.items[i] orelse continue);
            if (player.id == self.id or !player.initialized) continue;

            const pose = player.pose.load();
            var player_spawn = zb.SpawnPlayer{
                .pid = player.id,
                .name = proto.padded_string(player.name[0..player.name_len]),
                .x = pose.x,
                .y = pose.y,
                .z = pose.z,
                .yaw = pose.yaw,
                .pitch = pose.pitch,
            };
            try self.send_packet(proto.send_spawn_to_client, .{&player_spawn});
            self.drain_outbound();
        }
    }

    initial_spawn.pid = self.id;

    Server.broadcast_spawn_player(self.id, &initial_spawn);

    const own_pose = self.pose.load();
    try self.send_packet(proto.send_position_to_client, .{ -1, own_pose.x, own_pose.y, own_pose.z, 0, 0 });
    self.drain_outbound();

    if (!Server.internal_use) {
        try self.send_message(self.id, "&eWelcome to the world!");
        self.drain_outbound();

        var msg_buf: Message = @splat(' ');
        _ = std.fmt.bufPrint(&msg_buf, "&e{s} joined the game", .{self.name[0..self.name_len]}) catch unreachable;

        Server.broadcast_chat_message(self.id, &msg_buf);
        self.drain_outbound();
    }
}

pub fn prepare_login(self: *Client, request: LoginRequest) bool {
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
    for (0..Server.players.items.len) |i| {
        const player = &(Server.players.items[i] orelse continue);
        // Handshaking clients reserve their name; awaiting/closing clients do not.
        const phase = player.phase.load(.acquire);
        if (player.id == self.id or phase == .awaiting_login or phase == .closing) continue;
        if (player.name_len == name.len and std.mem.eql(u8, player.name[0..player.name_len], name.value[0..name.len])) {
            self.reject_protocol("A player with that name is already connected!");
            return false;
        }
    }

    self.name = name.value;
    self.name_len = name.len;
    self.phase.store(.handshaking, .release);
    return true;
}

/// Complete the expensive, output-producing half of a login after the name
/// and player slot have already been reserved.
pub fn finish_login(self: *Client) !void {
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
    const self = ctx_to_client(ctx);
    if (!require_active(self)) return;

    self.pose.store(.{ .x = e.x, .y = e.y, .z = e.z, .yaw = e.yaw, .pitch = e.pitch });
}

fn handle_message(ctx: *anyopaque, event: zb.Message) !void {
    const self = ctx_to_client(ctx);
    if (!require_active(self)) return;

    const trimmed = std.mem.trimEnd(u8, &event.message, " \x00");
    if (trimmed.len > 0 and trimmed[0] == '/') {
        if (Server.on_command) |dispatch| {
            dispatch(self, trimmed[1..]);
        } else {
            try self.send_message(self.id, "&eCommands are only available on multiplayer servers");
        }
        return;
    }

    var dup_buf: Message = @splat(' ');
    const prefix = std.fmt.bufPrint(&dup_buf, "&f{s}: ", .{self.name[0..self.name_len]}) catch unreachable;
    const len = @min(trimmed.len, dup_buf.len - prefix.len);
    @memcpy(dup_buf[prefix.len..][0..len], trimmed[0..len]);

    // Translate Minecraft's alternate '%' color prefix.
    for (0..dup_buf.len - 1) |i| {
        if (dup_buf[i] != '%') continue;
        const next = dup_buf[i + 1];
        const is_color = (next >= '0' and next <= '9') or (next >= 'a' and next <= 'f');
        if (is_color) dup_buf[i] = '&';
    }

    Server.broadcast_chat_message(self.id, &dup_buf);
}

fn handle_set_block(ctx: *anyopaque, event: zb.SetBlockToServer) !void {
    const self = ctx_to_client(ctx);
    if (!require_active(self)) return;

    world.lock_world();
    defer world.unlock_world();

    if (!require_active(self)) return;

    const dims = world.data.dims;
    if (event.x >= dims.length or event.y >= dims.height or event.z >= dims.depth)
        return;

    // Validate untrusted mode bytes before converting to an enum.
    const mode = std.enums.fromInt(zb.ClickMode, event.mode) orelse return;

    if (mode == .destroy and event.y == 0)
        return;

    const block: blocks.Block = @enumFromInt(event.block);

    if (mode == .create and block.is_fluid()) {
        return;
    }

    const old_block = world.data.get_block(event.x, event.y, event.z);

    if (mode == .destroy) {
        world.set_block(event.x, event.y, event.z, .air);
        Server.broadcast_block_change(event.x, event.y, event.z, .air);
    } else {
        // Partial blocks can be targeted through their empty subvolume. Only
        // air and fluids are replaceable, except slab + slab promotes in-place.
        if (old_block == .slab and block == .slab) {
            world.set_block(event.x, event.y, event.z, .double_slab);
            Server.broadcast_block_change(event.x, event.y, event.z, .double_slab);
            world.enqueue_neighbors_of(event.x, event.y, event.z);
            return;
        }
        if (!old_block.is_place_replaceable()) {
            Server.broadcast_block_change(event.x, event.y, event.z, old_block);
            return;
        }

        // Reassert this cell to undo optimistic client placement before
        // upgrading the slab below.
        if (block == .slab and event.y > 0) {
            const below = world.data.get_block(event.x, event.y - 1, event.z);
            if (below == .slab) {
                Server.broadcast_block_change(event.x, event.y, event.z, old_block);
                world.set_block(event.x, event.y - 1, event.z, .double_slab);
                Server.broadcast_block_change(event.x, event.y - 1, event.z, .double_slab);
                world.enqueue_neighbors_of(event.x, event.y - 1, event.z);
                return;
            }
        }
        world.set_block(event.x, event.y, event.z, block);
        Server.broadcast_block_change(event.x, event.y, event.z, block);
    }
    world.enqueue_neighbors_of(event.x, event.y, event.z);

    if (mode == .create and block == .sponge) {
        world.sponge_absorb(Server.block_change_sink, event.x, event.y, event.z);
    }
    if (mode == .destroy and old_block == .sponge) {
        world.sponge_release(event.x, event.y, event.z);
    }
}

pub fn init(self: *Client) void {
    self.protocol = Protocol.init(.client, .Connected, self);
    self.protocol.handles = .{
        .onPlayerIDToServer = handle_player,
        .onPositionAndOrientationToServer = handle_position,
        .onMessage = handle_message,
        .onSetBlockToServer = handle_set_block,
    };
}

/// Process one buffered singleplayer packet without blocking.
pub fn try_process_packet(self: *Client) bool {
    return self.process_packet(self.reader) catch |err| switch (err) {
        // An empty FakeConn ring is the normal idle case.
        error.ReadFailed => false,
        else => {
            log.err("process packet failed for client id={d}: {}", .{ self.id, err });
            return false;
        },
    };
}

pub fn drain_packets(self: *Client) void {
    while (self.try_process_packet()) {}
}

/// Drain outbound packets between reads on this client's connection thread.
pub fn read_loop(self: *Client) void {
    const stream = self.stream orelse {
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
        self.drain_outbound();
        if (self.transport.?.load(.acquire) == .closing) {
            self.mark_closed();
            stream.shutdown(Server.io, .both) catch {};
            return;
        }

        assert(in_len < inbuf.len);
        const msg = stream.socket.receiveTimeout(Server.io, inbuf[in_len..], recv_poll_timeout) catch |err| switch (err) {
            error.Timeout => continue,
            error.Canceled => return,
            else => {
                self.mark_closed();
                return;
            },
        };
        if (msg.data.len == 0) {
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
                self.drain_outbound();
                self.mark_closed();
                stream.shutdown(Server.io, .both) catch {};
                return;
            }
        }
        if (!self.is_connected()) return;
        if (!self.accepts_packets()) continue;

        const remaining = fixed.bufferedLen();
        std.mem.copyForwards(u8, inbuf[0..remaining], inbuf[in_len - remaining .. in_len]);
        in_len = remaining;
    }
}

test "phase-invalid packets disconnect before dispatch" {
    const cases = [_]struct { phase: ConnectionPhase, packet_id: u8 }{
        .{ .phase = .active, .packet_id = 0x00 },
        .{ .phase = .awaiting_login, .packet_id = 0x05 },
        .{ .phase = .awaiting_login, .packet_id = 0x0D },
        .{ .phase = .handshaking, .packet_id = 0x00 },
    };
    for (cases) |case| {
        const packet = [_]u8{case.packet_id};
        var reader = std.Io.Reader.fixed(&packet);
        var output: [256]u8 = undefined;
        var writer = std.Io.Writer.fixed(&output);
        var connected = true;
        var client: Client = .{
            .reader = &reader,
            .writer = &writer,
            .connected = &connected,
            .phase = .init(case.phase),
        };

        try std.testing.expect(!(try client.process_packet(&reader)));
        try std.testing.expect(!connected);
        try std.testing.expectEqual(@as(usize, 0), reader.seek);
        try std.testing.expectEqual(@as(u8, 0x0E), writer.buffered()[0]);
    }
}

test "atomic player pose round trips packed fields" {
    const initial: PlayerPose = .{ .x = 123, .y = 456, .z = 789, .yaw = 42, .pitch = 99 };
    const updated: PlayerPose = .{ .x = 0xffff, .y = 1, .z = 0xabcd, .yaw = 0xff, .pitch = 0 };
    var pose = AtomicPlayerPose.init(initial);
    try std.testing.expectEqual(initial, pose.load());
    pose.store(updated);
    try std.testing.expectEqual(updated, pose.load());
}
