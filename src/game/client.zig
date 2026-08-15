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

const ConnectionPhase = enum {
    awaiting_login,
    handshaking,
    active,
    closing,
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
x: u16,
y: u16,
z: u16,
yaw: u8,
pitch: u8,

reader: *std.Io.Reader,
writer: *std.Io.Writer,
connected: *bool,

name: [16:0]u8,
name_len: u8,
initialized: bool,
phase: ConnectionPhase,
local: bool,
is_op: bool,
ip: [players_db.ip_str_len:0]u8,
protocol: Protocol,

buffer: [1024]u8,

/// Streams gzip-compressed data as 1024-byte LevelDataChunk protocol packets.
const ChunkSender = struct {
    interface: std.Io.Writer,
    output: *std.Io.Writer,
    raw_written: u32,
    total_raw: u32,

    fn init(output: *std.Io.Writer, chunk_buffer: *[1024]u8, total_raw: u32) ChunkSender {
        return .{
            .interface = .{
                .vtable = &.{
                    .drain = drain,
                },
                .buffer = chunk_buffer,
            },
            .output = output,
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

        const end_before = cs.output.end;
        proto.send_level_chunk_to_client(cs.output, @intCast(filled), &chunk, cs.percent()) catch
            return error.WriteFailed;
        const end_after = cs.output.end;
        // If the protocol write triggered an auto-drain, end_after < end_before + 1028
        if (end_before != 0 or end_after != 1028) {
            log.warn("drain: end before={d} after={d} (expected 0->1028)", .{ end_before, end_after });
        }
        cs.output.flush() catch return error.WriteFailed;
        @memset(cs.output.buffer, 0x00);

        return w.consume(filled);
    }
};

const log = std.log.scoped(.client);

fn ctx_to_client(ctx: *anyopaque) *Self {
    return @ptrCast(@alignCast(ctx));
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
    connected: *bool,
    ip: []const u8,
    is_op: bool,
    request: LoginRequest,
) void {
    const name = login_name(request);

    self.connected = connected;
    self.reader = reader;
    self.writer = writer;
    self.initialized = false;
    self.phase = .handshaking;
    self.local = false;
    self.is_op = is_op;
    self.ip = std.mem.zeroes([players_db.ip_str_len:0]u8);
    const ip_n = @min(ip.len, players_db.ip_str_len);
    @memcpy(self.ip[0..ip_n], ip[0..ip_n]);
    self.name = name.value;
    self.name_len = name.len;
    self.id = -1;
    self.x = 0;
    self.y = 0;
    self.z = 0;
    self.yaw = 0;
    self.pitch = 0;
}

fn read_packet(self: *Self) !bool {
    const packet_id = try self.reader.peekByte();
    const len = try proto.packet_length_to_server(packet_id);

    const buffer = try self.reader.peek(len);
    @memcpy(self.buffer[0..len], buffer);

    self.reader.toss(len);
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
    if (self.phase == .closing) return;
    self.phase = .closing;
    proto.send_disconnect_to_client(self.writer, reason) catch {
        self.connected.* = false;
        return;
    };
    self.writer.flush() catch {};
    self.connected.* = false;
}

fn require_active(self: *Self) bool {
    if (self.phase == .active and self.initialized) return true;
    self.reject_protocol("Unexpected packet before login");
    return false;
}

fn process_packet(self: *Self) !bool {
    if (!self.connected.*) return false;

    // Check the phase before asking the generated protocol layer for a packet
    // length. That guarantees any unexpected byte, including an unknown ID,
    // gets an explicit disconnect without reaching the decoder or dispatcher.
    const packet_id = try self.reader.peekByte();
    if (!packet_allowed(self.phase, packet_id)) {
        self.reject_protocol("Protocol state violation");
        return false;
    }

    const received = try self.read_packet();
    if (!received) return false;

    try self.protocol.handle_packet(self.buffer[1..], self.buffer[0]);
    return true;
}

pub fn send_message(self: *Self, id: i8, message: []u8) !void {
    const pid: i8 = if (id == self.id) -1 else id;
    try proto.send_message(self.writer, pid, message);
}

pub fn send_disconnect(self: *Self, reason: []const u8) !void {
    self.phase = .closing;
    defer self.connected.* = false;
    try proto.send_disconnect_to_client(self.writer, reason);
}

pub fn send_player_position(self: *Self, id: i8, x: u16, y: u16, z: u16, yaw: u8, pitch: u8) !void {
    try proto.send_position_to_client(self.writer, id, x, y, z, yaw, pitch);
}

pub fn send_spawn(ctx: *Self, packet: *zb.SpawnPlayer) !void {
    const self: *Self = @ptrCast(@alignCast(ctx));
    try proto.send_spawn_to_client(self.writer, packet);
}

pub fn send_despawn(self: *Self, id: i8) !void {
    try proto.send_despawn_to_client(self.writer, id);
}

pub fn send_block_change(self: *Self, x: u16, y: u16, z: u16, block: c.Block) !void {
    try proto.send_block_change_to_client(self.writer, x, y, z, block);
}

fn send_world(self: *Self) !void {
    try proto.send_level_initialize_to_client(self.writer);
    try self.writer.flush();

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
    while (!job.base.done.load(.acquire)) {
        try Server.io.sleep(common.time.ms(20), .real);
    }
    if (job.base.err) |e| return e;
}

fn world_send_run(base: *compress_worker.Job) anyerror!void {
    const job: *WorldSendJob = @fieldParentPtr("base", base);
    try send_world_impl(job.client);
}

fn send_world_impl(self: *Self) !void {
    var chunk_buf: [1024]u8 = @splat(0);

    var sender = ChunkSender.init(self.writer, &chunk_buf, @intCast(world.data.raw_blocks.len));
    try compress_worker.reset(&sender.interface);

    // Feed 4-byte size header, then block data in contiguous YZX wire
    // order (Java Classic compatible) from chunk-aware memory layout.
    try compress_worker.compressor.writer.writeAll(world.data.raw_blocks[0..4]);
    sender.raw_written = 4;
    try world.data.write_blocks_yzx(&compress_worker.compressor.writer);
    sender.raw_written = @intCast(world.data.raw_blocks.len);
    try compress_worker.compressor.finish();

    // Send any remaining partial chunk as the final packet.
    if (sender.interface.end > 0) {
        var final_chunk: [1024]u8 = @splat(0);
        @memcpy(final_chunk[0..sender.interface.end], sender.interface.buffer[0..sender.interface.end]);
        try proto.send_level_chunk_to_client(self.writer, @intCast(sender.interface.end), &final_chunk, sender.percent());
        try self.writer.flush();
    }

    try proto.send_level_finalize_to_client(self.writer, c.WorldLength, c.WorldHeight, c.WorldDepth);
    try self.writer.flush();
}

pub fn ip_slice(self: *const Self) []const u8 {
    return std.mem.sliceTo(self.ip[0..], 0);
}

pub fn handshake(self: *Self) !void {
    try proto.send_player_id_to_client(self.writer, &Server.server_name, &Server.server_motd, self.is_op);

    try self.send_world();

    var name_buf: c.Message = @splat(' ');
    std.mem.copyForwards(u8, &name_buf, self.name[0..self.name_len]);

    const spawn = world.find_spawn();
    var initial_spawn = zb.SpawnPlayer{
        .pid = -1,
        .name = name_buf,
        .x = spawn[0],
        .y = spawn[1],
        .z = spawn[2],
        .yaw = 0,
        .pitch = 0,
    };
    self.x = initial_spawn.x;
    self.y = initial_spawn.y;
    self.z = initial_spawn.z;
    self.yaw = 0;
    self.pitch = 0;
    try proto.send_spawn_to_client(self.writer, &initial_spawn);
    try self.writer.flush();

    // Send existing players to the new joiner before broadcasting the new joiner to others.
    for (0..Server.players.items.len) |i| {
        if (Server.players.items[i]) |p| {
            if (p.id == self.id)
                continue;

            var name_cpy = [_]u8{' '} ** 64;
            std.mem.copyForwards(u8, &name_cpy, &p.name);

            var player_spawn = zb.SpawnPlayer{
                .pid = p.id,
                .name = name_cpy,
                .x = p.x,
                .y = p.y,
                .z = p.z,
                .yaw = p.yaw,
                .pitch = p.pitch,
            };
            try proto.send_spawn_to_client(self.writer, &player_spawn);
            try self.writer.flush();
        }
    }

    initial_spawn.pid = self.id;

    Server.broadcast_spawn_player(self.id, &initial_spawn);

    try proto.send_position_to_client(self.writer, -1, self.x, self.y, self.z, 0, 0);
    try self.writer.flush();

    self.initialized = true;

    // Skip welcome + join-broadcast chat in singleplayer: the lone local
    // player would just be seeing themselves "join" their own world.
    if (!Server.internal_use) {
        var msg_buf: c.Message = @splat(' ');
        std.mem.copyForwards(u8, &msg_buf, "&eWelcome to the world!");

        try self.send_message(self.id, &msg_buf);
        try self.writer.flush();

        msg_buf = @splat(' ');
        _ = std.fmt.bufPrint(&msg_buf, "&e{s} joined the game", .{self.name[0..self.name_len]}) catch unreachable;

        Server.broadcast_chat_message(self.id, &msg_buf);
        try self.writer.flush();
    }
}

pub fn prepare_login(self: *Self, request: LoginRequest) bool {
    // The generated protocol dispatcher has one broad Connected state, so
    // preserve the server's actual login state here as a defense in depth.
    if (self.phase != .awaiting_login or self.initialized) {
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
            if (p.id == self.id or p.phase == .awaiting_login or p.phase == .closing)
                continue;
            if (p.name_len == name.len and std.mem.eql(u8, p.name[0..p.name_len], name.value[0..name.len])) {
                self.reject_protocol("A player with that name is already connected!");
                return false;
            }
        }
    }

    self.name = name.value;
    self.name_len = name.len;
    self.phase = .handshaking;
    return true;
}

/// Complete the expensive, output-producing half of a login after the name
/// and player slot have already been reserved.
pub fn finish_login(self: *Self) !void {
    if (self.phase != .handshaking or self.initialized) return error.InvalidLoginState;

    self.handshake() catch |err| {
        self.phase = .closing;
        self.connected.* = false;
        return err;
    };
    self.phase = .active;

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

    self.x = e.x;
    self.y = e.y;
    self.z = e.z;
    self.yaw = e.yaw;
    self.pitch = e.pitch;
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
    const allowed = self.is_op or Server.internal_use;
    const sink: commands.Sink = .{ .ctx = self, .write_fn = slash_sink_write };
    commands.dispatch(sink, body, allowed);
}

fn handle_set_block(ctx: *anyopaque, event: zb.SetBlockToServer) !void {
    const self = ctx_to_client(ctx);
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
    return self.process_packet() catch |err| {
        log.err("process packet failed for client id={d}: {}", .{ self.id, err });
        return false;
    };
}

pub fn drain_packets(self: *Self) void {
    while (self.try_process_packet()) {}
}

/// Blocking read loop -- runs on an Io thread pool thread. Reads and
/// processes packets until the connection drops, then marks disconnected.
pub fn read_loop(self: *Self) void {
    while (self.connected.*) {
        const received = self.process_packet() catch |e| switch (e) {
            error.ReadFailed => false,
            else => {
                self.connected.* = false;
                return;
            },
        };

        if (!received) {
            self.connected.* = false;
            return;
        }
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
    client.initialized = true;
    client.phase = .active;

    try std.testing.expect(!(try client.process_packet()));
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
        client.initialized = false;
        client.phase = .awaiting_login;

        try std.testing.expect(!(try client.process_packet()));
        try std.testing.expect(!connected);
        try std.testing.expectEqual(@as(u8, 0x0E), writer.buffered()[0]);
    }
}
