const std = @import("std");
const zb = @import("protocol");
const Protocol = zb.Protocol;
const common = @import("common");
const c = common.consts;
const world = @import("world.zig");
const proto = common.protocol;

const Server = @import("server.zig");
const compress_worker = @import("compress_worker.zig");

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
local: bool,
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

fn read_packet(self: *Self) !bool {
    const packet_id = try self.reader.peekByte();
    const len = try proto.packet_length_to_server(packet_id);

    const buffer = try self.reader.peek(len);
    @memcpy(self.buffer[0..len], buffer);

    self.reader.toss(len);
    return true;
}

pub fn send_message(self: *Self, id: i8, message: []u8) !void {
    const pid: i8 = if (id == self.id) -1 else id;
    try proto.send_message(self.writer, pid, message);
}

pub fn send_disconnect(self: *Self, reason: []const u8) !void {
    self.connected.* = false;
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
        try Server.io.sleep(.fromMilliseconds(20), .real);
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

pub fn handshake(self: *Self) !void {
    try proto.send_player_id_to_client(self.writer, &Server.server_name, &Server.server_motd);

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

fn handle_player(ctx: *anyopaque, event: zb.PlayerIDToServer) !void {
    const self = ctx_to_client(ctx);

    if (event.protocol_version != 0x07) {
        self.send_disconnect("Unsupported protocol version!") catch {};
        self.connected.* = false;
        return;
    }

    self.name = @splat(' ');
    for (0..self.name.len) |i| {
        if (event.username[i] == ' ') {
            self.name_len = @intCast(i);
            break;
        }

        self.name[i] = event.username[i];
    }
    // TODO: Verify key for login... maybe

    for (0..Server.players.items.len) |i| {
        if (Server.players.items[i]) |p| {
            if (p.id == self.id or !p.initialized)
                continue;
            if (std.mem.eql(u8, p.name[0..p.name_len], self.name[0..self.name_len])) {
                self.send_disconnect("A player with that name is already connected!") catch {};
                return;
            }
        }
    }

    try self.handshake();
}

fn handle_position(ctx: *anyopaque, e: zb.PositionAndOrientationToServer) !void {
    const self: *Self = ctx_to_client(ctx);

    self.x = e.x;
    self.y = e.y;
    self.z = e.z;
    self.yaw = e.yaw;
    self.pitch = e.pitch;
}

fn handle_message(ctx: *anyopaque, event: zb.Message) !void {
    const self: *Self = @ptrCast(@alignCast(ctx));

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

fn handle_set_block(_: *anyopaque, event: zb.SetBlockToServer) !void {
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

    // Cross-blocks (flowers, saplings, mushrooms) have a narrow subvoxel
    // selection bound, so a raycast can pass through them and target the
    // cell they occupy via the surface below. Re-broadcast the existing
    // block so any optimistic client that drew the new block reverts.
    if (mode == .create and old_block.mesh_props().cross) {
        Server.broadcast_block_change(event.x, event.y, event.z, old_block);
        return;
    }

    if (mode == .destroy) {
        world.set_block(event.x, event.y, event.z, .{ .id = .air });
        Server.broadcast_block_change(event.x, event.y, event.z, .{ .id = .air });
    } else {
        // Slab-on-slab -> double slab. The originating client (and any other
        // client doing optimistic placement, e.g. ClassiCube) already drew a
        // slab into (x, y, z); re-assert whatever block actually lives at
        // that cell so those predictions are reverted, then upgrade the
        // slab below.
        if (block.id == .slab and event.y > 0) {
            const below = world.data.get_block(event.x, event.y - 1, event.z);
            if (below.id == .slab) {
                const existing_above = world.data.get_block(event.x, event.y, event.z);
                Server.broadcast_block_change(event.x, event.y, event.z, existing_above);
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
        world.sponge_absorb(event.x, event.y, event.z);
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
    const received = self.read_packet() catch return false;
    if (!received) return false;
    self.protocol.handle_packet(self.buffer[1..], self.buffer[0]) catch return false;
    return true;
}

pub fn drain_packets(self: *Self) void {
    while (self.try_process_packet()) {}
}

/// Blocking read loop -- runs on an Io thread pool thread. Reads and
/// processes packets until the connection drops, then marks disconnected.
pub fn read_loop(self: *Self) void {
    while (self.connected.*) {
        const received = self.read_packet() catch |e| switch (e) {
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
        self.protocol.handle_packet(self.buffer[1..], self.buffer[0]) catch {
            self.connected.* = false;
            return;
        };
    }
}
