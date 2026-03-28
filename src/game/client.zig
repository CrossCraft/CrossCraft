const std = @import("std");
const zb = @import("protocol");
const Protocol = zb.Protocol;
const assert = std.debug.assert;
const c = @import("common").consts;
const world = @import("world.zig");
const proto = @import("protocol.zig");

const Server = @import("server.zig");

const flate = std.compress.flate;

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
name_len: usize,
initialized: bool,
protocol: Protocol,

buffer: [1024]u8,

/// Streams gzip-compressed data as 1024-byte LevelDataChunk protocol packets.
const ChunkSender = struct {
    interface: std.Io.Writer,
    output: *std.Io.Writer,

    fn init(output: *std.Io.Writer, chunk_buffer: *[1024]u8) ChunkSender {
        return .{
            .interface = .{
                .vtable = &.{
                    .drain = drain,
                },
                .buffer = chunk_buffer,
            },
            .output = output,
        };
    }

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        _ = splat;
        const cs: *ChunkSender = @alignCast(@fieldParentPtr("interface", w));
        const CHUNK: usize = 1024;

        // Build a full chunk from buffered data + new data.
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

        proto.send_level_chunk(cs.output, @intCast(filled), chunk, 0) catch
            return error.WriteFailed;

        return w.consume(filled);
    }
};

fn ctx_to_client(ctx: *anyopaque) *Self {
    return @ptrCast(@alignCast(ctx));
}

fn read_packet(self: *Self) !bool {
    const packet_id = try self.reader.peekByte();
    const len = try proto.packet_length(packet_id);

    const buffer = try self.reader.peek(len);
    @memcpy(self.buffer[0..len], buffer);

    self.reader.toss(len);
    return true;
}

pub fn send_message(self: *Self, id: i8, message: []u8) !void {
    try proto.send_message(self.writer, self.id, id, message);
}

pub fn send_disconnect(self: *Self, reason: []const u8) !void {
    self.connected.* = false;
    try proto.send_disconnect(self.writer, reason);
}

pub fn send_player_position(self: *Self, id: i8, x: u16, y: u16, z: u16, yaw: u8, pitch: u8) !void {
    try proto.send_player_position(self.writer, id, x, y, z, yaw, pitch);
}

pub fn send_spawn(ctx: *Self, packet: *zb.SpawnPlayer) !void {
    const self: *Self = @ptrCast(@alignCast(ctx));
    try proto.send_spawn(self.writer, packet);
}

pub fn send_despawn(self: *Self, id: i8) !void {
    try proto.send_despawn(self.writer, id);
}

pub fn send_block_change(self: *Self, x: u16, y: u16, z: u16, block: u8) !void {
    try proto.send_block_change(self.writer, x, y, z, block);
}

fn send_world(self: *Self) !void {
    try proto.send_level_initialize(self.writer);

    @memset(&self.buffer, 0x00);

    var sender = ChunkSender.init(self.writer, &self.buffer);
    var compress_buf: [flate.max_window_len]u8 = undefined;
    var compressor = try flate.Compress.init(&sender.interface, &compress_buf, .gzip, .fastest);

    try compressor.writer.writeAll(world.raw_blocks);
    try compressor.finish();

    // Send any remaining partial chunk as the final packet.
    if (sender.interface.end > 0) {
        var final_chunk: [1024]u8 = @splat(0);
        @memcpy(final_chunk[0..sender.interface.end], sender.interface.buffer[0..sender.interface.end]);
        try proto.send_level_chunk(self.writer, @intCast(sender.interface.end), final_chunk, 255);
    }

    try proto.send_level_finalize(self.writer);
    try self.writer.flush();
}

fn handshake(self: *Self) !void {
    try proto.send_player_id(self.writer, @splat(' '), @splat(' '));

    try self.send_world();

    var name_buf: c.Message = @splat(' ');
    std.mem.copyForwards(u8, &name_buf, self.name[0..self.name_len]);

    // TODO: Spawn randomization

    var initial_spawn = zb.SpawnPlayer{
        .pid = -1,
        .name = name_buf,
        .x = @intCast(c.WorldLength << 4),
        .y = @intCast(c.WorldHeight << 4),
        .z = @intCast(c.WorldDepth << 4),
        .yaw = 0,
        .pitch = 0,
    };
    self.x = initial_spawn.x;
    self.y = initial_spawn.y;
    self.z = initial_spawn.z;
    self.yaw = 0;
    self.pitch = 0;
    try proto.send_spawn(self.writer, &initial_spawn);

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
            try proto.send_spawn(self.writer, &player_spawn);
        }
    }

    initial_spawn.pid = self.id;

    Server.broadcast_spawn_player(self.id, &initial_spawn);

    try proto.send_player_position(self.writer, -1, self.x, self.y, self.z, 0, 0);

    var msg_buf: c.Message = @splat(' ');
    std.mem.copyForwards(u8, &msg_buf, "&eWelcome to the world!");

    try self.send_message(self.id, &msg_buf);

    msg_buf = @splat(' ');
    _ = std.fmt.bufPrint(&msg_buf, "&e{s} joined the game", .{self.name[0..self.name_len]}) catch unreachable;

    self.initialized = true;
    Server.broadcast_chat_message(self.id, &msg_buf);
    try self.writer.flush();
}

fn handle_player(ctx: *anyopaque, event: zb.PlayerIDToServer) !void {
    const self = ctx_to_client(ctx);

    if (event.protocol_version != 0x07) {
        self.send_disconnect("Unsupported protocol version!") catch {};
        self.connected.* = false;
        return;
    }

    // Username copy
    self.name = @splat(' ');
    for (0..self.name.len) |i| {
        if (event.username[i] == ' ') {
            self.name_len = i;
            break;
        }

        self.name[i] = event.username[i];
    }
    // TODO: Verify key for login... maybe

    // Reject duplicate usernames.
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

    var curr_idx: usize = 2;
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

    Server.broadcast_chat_message(self.id, &dup_buf);
}

fn handle_set_block(_: *anyopaque, event: zb.SetBlockToServer) !void {
    if (event.mode == .Destroy) {
        world.set_block(event.x, event.y, event.z, 0);
        Server.broadcast_block_change(event.x, event.y, event.z, 0);
    } else {
        world.set_block(event.x, event.y, event.z, event.block);
        Server.broadcast_block_change(event.x, event.y, event.z, event.block);
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

/// Blocking read loop — runs on an Io thread pool thread. Reads and
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
