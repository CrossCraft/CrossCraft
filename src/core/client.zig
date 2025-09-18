const std = @import("std");
const zb = @import("protocol");
const Protocol = zb.Protocol;
const assert = std.debug.assert;
const c = @import("consts.zig");
const world = @import("world.zig");
const gzip = @import("compress/gzip.zig");

const Server = @import("server.zig");

const Self = @This();

id: i8,
x: u16,
y: u16,
z: u16,
yaw: u8,
pitch: u8,

reader: *std.io.Reader,
writer: *std.io.Writer,
connected: *bool,

name: [16:0]u8,
name_len: usize,
initialized: bool,
protocol: Protocol,

buffer: [1024]u8,
world_buffer_idx: usize,

const WorldWriter = std.io.GenericWriter(*Self, anyerror, write_world);
fn write_world(self: *Self, buf: []const u8) anyerror!usize {
    const CHUNK: usize = 1024;
    comptime {
        // Ensure our internal buffer matches the protocol chunk size.
        std.debug.assert(@sizeOf(@TypeOf(self.buffer)) == CHUNK);
    }

    var total_written: usize = 0;

    while (total_written < buf.len) {
        // If the internal buffer is full, emit a chunk.
        if (self.world_buffer_idx == CHUNK) {
            var level_chunk = zb.LevelDataChunk{
                .id = 0x3,
                .length = CHUNK,
                .data = &self.buffer,
                .percent = 0,
            };
            try level_chunk.write(self.writer);

            // Reset write index and clear the buffer (preserves original semantics).
            self.world_buffer_idx = 0;
            @memset(&self.buffer, 0);
        }

        // Copy as many bytes as we can into the remaining space of the buffer.
        const space = CHUNK - self.world_buffer_idx;
        const remaining = buf.len - total_written;
        const n = @min(space, remaining);

        @memcpy(self.buffer[self.world_buffer_idx .. self.world_buffer_idx + n], buf[total_written .. total_written + n]);

        self.world_buffer_idx += n;
        total_written += n;
    }

    return buf.len;
}

fn ctx_to_client(ctx: *anyopaque) *Self {
    return @ptrCast(@alignCast(ctx));
}

fn read_packet(self: *Self) !bool {
    const packet_id = try self.reader.peekByte();

    const len: u8 = switch (packet_id) {
        0x00 => 131,
        0x05 => 9,
        0x08 => 10,
        0x0D => 66,
        else => return error.InvalidPacketID,
    };

    const buffer = try self.reader.peek(len);
    @memcpy(self.buffer[0..len], buffer);

    self.reader.toss(len);
    return true;
}

pub fn send_message(self: *Self, id: i8, message: []u8) !void {
    var msg = zb.Message{
        .id = 0x0D,
        .pid = if (id == self.id) -1 else id,
        .message = message,
    };

    std.debug.print("{s}\n", .{message});
    try msg.write(self.writer);
}

pub fn send_disconnect(self: *Self, reason: []const u8) !void {
    assert(reason.len <= 64);

    self.connected.* = false;
    var reason_buf: c.Message = @splat(' ');

    var packet: zb.DisconnectPlayer = .{
        .id = 0x0E,
        .reason = &reason_buf,
    };

    for (0..packet.reason.len) |i| {
        if (i < reason.len) {
            packet.reason[i] = reason[i];
        }
    }

    // Data
    try packet.write(self.writer);
    try self.writer.flush();
}

pub fn send_player_position(self: *Self, id: i8, x: u16, y: u16, z: u16, yaw: u8, pitch: u8) !void {
    var position = zb.SetPositionOrientation{
        .id = 0x08,
        .pid = id,
        .x = x,
        .y = y,
        .z = z,
        .yaw = yaw,
        .pitch = pitch,
    };

    try position.write(self.writer);
}

pub fn send_spawn(ctx: *Self, packet: *zb.SpawnPlayer) !void {
    const self: *Self = @ptrCast(@alignCast(ctx));
    try packet.write(self.writer);
}

pub fn send_despawn(self: *Self, id: i8) !void {
    var despawn_packet = zb.DespawnPlayer{
        .id = 0x0C,
        .pid = id,
    };

    try despawn_packet.write(self.writer);
}

pub fn send_block_change(self: *Self, x: u16, y: u16, z: u16, block: u8) !void {
    var block_change = zb.SetBlockToClient{
        .id = 0x06,
        .x = x,
        .y = y,
        .z = z,
        .block = block,
    };

    try block_change.write(self.writer);
}

fn send_world(self: *Self) !void {
    // This is the LevelStart packet, but we don't have a level to send yet
    try self.writer.writeByte(0x02);

    // Write the level data
    @memset(&self.buffer, 0x00);
    self.world_buffer_idx = 0;

    // Compress the world data using gzip
    var fbs = std.io.fixedBufferStream(world.raw_blocks);
    const reader = fbs.reader().any();

    const before = std.time.microTimestamp();

    var wwriter = WorldWriter{
        .context = self,
    };
    try gzip.compress(reader, wwriter.any(), .{});

    var level_chunk = zb.LevelDataChunk{
        .id = 0x03,
        .length = @intCast(1024 - self.world_buffer_idx),
        .data = self.buffer[0..],
        .percent = 255,
    };
    try level_chunk.write(self.writer);

    const after = std.time.microTimestamp();
    std.debug.print("World compress and send took {} us\n", .{after - before});

    // Finalize the level
    var level_finalize = zb.LevelFinalize{
        .id = 0x04,
        .x = c.WorldLength,
        .y = c.WorldHeight,
        .z = c.WorldDepth,
    };
    try level_finalize.write(self.writer);
    try self.writer.flush();
}

fn handshake(self: *Self) !void {
    var server_data = zb.PlayerIDToClient{
        .id = 0x00,
        .protocol_version = 0x07,
        .server_motd = &Server.motd,
        .server_name = &Server.name,
        .user_type = 0x00, // TODO: Lookup user type
    };
    try server_data.write(self.writer);

    try self.send_world();

    var name_buf: c.Message = @splat(' ');
    std.mem.copyForwards(u8, &name_buf, self.name[0..self.name_len]);

    // TODO: Spawn randomization

    var initial_spawn = zb.SpawnPlayer{
        .id = 0x07,
        .pid = -1,
        .name = &name_buf,
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
    try initial_spawn.write(self.writer);

    initial_spawn.pid = self.id;

    Server.broadcast_spawn_player(&initial_spawn);

    for (0..Server.players.items.len) |i| {
        if (Server.players.items[i]) |p| {
            if (p.id == self.id)
                continue;

            var name_cpy = [_]u8{' '} ** 64;
            std.mem.copyForwards(u8, &name_cpy, &p.name);

            var player_spawn = zb.SpawnPlayer{
                .id = 0x07,
                .pid = p.id,
                .name = &name_cpy,
                .x = p.x,
                .y = p.y,
                .z = p.z,
                .yaw = p.yaw,
                .pitch = p.pitch,
            };
            try player_spawn.write(self.writer);
        }
    }

    var teleport_player = zb.SetPositionOrientation{
        .id = 0x08,
        .pid = -1,
        .x = self.x,
        .y = self.y,
        .z = self.z,
        .yaw = 0,
        .pitch = 0,
    };
    try teleport_player.write(self.writer);

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
        self.send_disconnect("Unsupported protocol version!\n") catch {};
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
    // TODO: Lookup user

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
    if (event.mode == @intFromEnum(zb.ClickMode.Destroy)) {
        world.set_block(event.x, event.y, event.z, 0);
        Server.broadcast_block_change(event.x, event.y, event.z, 0);
    } else {
        world.set_block(event.x, event.y, event.z, event.block);
        Server.broadcast_block_change(event.x, event.y, event.z, event.block);
    }
}

pub fn init(self: *Self) void {
    self.protocol = Protocol.init(.Client, .Connected, self);
    self.protocol.handle = .{
        .handle_PlayerIDToServer = handle_player,
        .handle_PositionAndOrientationToServer = handle_position,
        .handle_Message = handle_message,
        .handle_SetBlockToServer = handle_set_block,
    };
}

pub fn tick(self: *Self) bool {
    while (true) {
        const received = self.read_packet() catch |e| switch (e) {
            error.ReadFailed => false,
            else => {
                self.connected.* = false;
                return false;
            },
        };

        if (!received) break;
        self.protocol.handle_packet(self.buffer[0..], self.buffer[0]) catch return false;
    }

    return true;
}
