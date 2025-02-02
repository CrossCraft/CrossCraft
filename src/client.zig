const std = @import("std");
const assert = std.debug.assert;
const server = @import("server.zig");
const zb = @import("protocol");
const IO = @import("io.zig");
const c = @import("constants.zig");

const Self = @This();

id: i8,
x: u16,
y: u16,
z: u16,
yaw: u8,
pitch: u8,
connection: IO.Connection,
name: [16:0]u8,
initialized: bool,
disconnected: bool,
protocol: zb.Protocol,

buffer: [1024]u8,
world_buffer_idx: usize,

const WorldWriter = std.io.Writer(*Self, anyerror, write_world);

fn write_world(self: *Self, buf: []const u8) anyerror!usize {
    var total_written: usize = 0;

    while (total_written < buf.len) {
        if (self.world_buffer_idx == 1024) {
            self.world_buffer_idx = 0;

            const writer = self.connection.writer().any();
            var level_chunk = zb.LevelDataChunk{
                .id = 0x3,
                .length = 1024,
                .data = &self.buffer,
                .percent = 0,
            };
            try level_chunk.write(writer);

            @memset(&self.buffer, 0);
        }

        self.buffer[self.world_buffer_idx] = buf[total_written];

        total_written += 1;
        self.world_buffer_idx += 1;
    }

    return buf.len;
}

pub fn init(self: *Self) void {
    self.protocol = zb.Protocol.init(.Client, .Connected, self);
    self.protocol.handle = .{
        .handle_PlayerIDToServer = handle_player,
        .handle_PositionAndOrientationToServer = handle_position,
        .handle_Message = handle_message,
    };
}

pub fn send_message(self: *Self, id: i8, message: []u8) !void {
    var msg = zb.Message{
        .id = 0x0D,
        .pid = if (id == self.id) -1 else id,
        .message = message,
    };

    const writer = self.connection.writer().any();
    try msg.write(writer);
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

    const writer = self.connection.writer().any();
    try position.write(writer);
}

pub fn send_spawn(ctx: *Self, packet: *zb.SpawnPlayer) !void {
    const self: *Self = @ptrCast(@alignCast(ctx));

    const writer = self.connection.writer().any();
    try packet.write(writer);
}

pub fn send_despawn(self: *Self, id: i8) !void {
    var despawn_packet = zb.DespawnPlayer{
        .id = 0x0C,
        .pid = id,
    };

    const writer = self.connection.writer().any();
    try despawn_packet.write(writer);
}

pub fn send_disconnect(self: *Self, reason: []const u8) !void {
    assert(reason.len <= 64);

    self.disconnected = true;

    var reason_buf = [_]u8{0x00} ** 64;

    var packet: zb.DisconnectPlayer = .{
        .id = 0x0E,
        .reason = &reason_buf,
    };

    for (0..packet.reason.len) |i| {
        if (i < reason.len) {
            packet.reason[i] = reason[i];
        } else {
            packet.reason[i] = ' ';
        }
    }

    const writer = self.connection.writer();

    // Data
    try packet.write(writer.any());
}

fn handle_position(ctx: *anyopaque, e: zb.PositionAndOrientationToServer) !void {
    const self: *Self = @ptrCast(@alignCast(ctx));

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

    server.broadcast_chat_message(self.id, &dup_buf);
}

fn handle_player(ctx: *anyopaque, event: zb.PlayerIDToServer) !void {
    var self: *Self = @ptrCast(@alignCast(ctx));

    if (event.protocol_version != 0x07) {
        try self.send_disconnect("Protocol version incompatible; Update to Protocol Version 7.");
    }

    var buf_cpy = [_]u8{' '} ** 64;
    @memcpy(&buf_cpy, event.username);

    @memset(&self.name, ' ');
    var name_len: usize = 0;
    for (0..16) |i| {
        if (event.username[i] == ' ') {
            // Spaces are not allowed in names, indicates the end.
            name_len = i;
            break;
        }

        self.name[i] = event.username[i];
    }

    const writer = self.connection.writer().any();

    var server_name_buf = [_]u8{' '} ** 64;
    std.mem.copyForwards(u8, &server_name_buf, "A Classic Server!");

    var motd_buf = [_]u8{' '} ** 64;
    std.mem.copyForwards(u8, &motd_buf, "Another adventure awaits!");

    // TODO: Customize Server data
    var server_data = zb.PlayerIDToClient{
        .id = 0x00,
        .protocol_version = 0x07,
        .server_motd = &server_name_buf,
        .server_name = &motd_buf,
        .user_type = 0x00, // TODO: Verify this
    };
    try server_data.write(writer);

    // TODO: Passwd verification

    // Level Start
    try writer.writeByte(0x02);

    // Level Data
    @memset(&self.buffer, 0x00);
    self.world_buffer_idx = 0;

    var fbs = std.io.fixedBufferStream(server.world.raw_blocks);
    const reader = fbs.reader().any();

    var wwriter = WorldWriter{
        .context = self,
    };
    try std.compress.gzip.compress(reader, wwriter.any(), .{});

    var level_chunk = zb.LevelDataChunk{
        .id = 0x03,
        .length = @intCast(1024 - self.world_buffer_idx),
        .data = self.buffer[0..],
        .percent = 0,
    };
    try level_chunk.write(writer);

    // Level Finalize
    var level_finalize = zb.LevelFinalize{
        .id = 0x04,
        .x = c.WorldLength,
        .y = c.WorldHeight,
        .z = c.WorldDepth,
    };
    try level_finalize.write(writer);

    var initial_spawn = zb.SpawnPlayer{
        .id = 0x07,
        .pid = -1,
        .name = &buf_cpy,
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
    try initial_spawn.write(writer);

    initial_spawn.pid = self.id;
    server.broadcast_spawn_player(&initial_spawn);

    for (0..server.player_ring.ring.len) |i| {
        if (server.player_ring.ring[i]) |p| {
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
            try player_spawn.write(writer);
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
    try teleport_player.write(writer);

    self.initialized = true;

    var msg_buf = [_]u8{' '} ** 64;
    std.mem.copyForwards(u8, &msg_buf, "&eWelcome to the world!");

    try self.send_message(self.id, &msg_buf);

    msg_buf = [_]u8{' '} ** 64;
    _ = std.fmt.bufPrint(&msg_buf, "&e{s} joined the game", .{self.name[0..name_len]}) catch unreachable;
    server.broadcast_chat_message(self.id, &msg_buf);
}

pub fn tick(self: *Self) bool {
    self.tick_unsafe() catch return false;

    return true;
}

fn tick_unsafe(self: *Self) !void {
    var received = try self.connection.read(&self.buffer);

    while (received) {
        try self.protocol.handle_packet(self.buffer[0..], self.buffer[0]);
        received = try self.connection.read(&self.buffer);
    }
}
