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
    };
}

fn send_disconnect(self: *Self, reason: []const u8) !void {
    assert(reason.len <= 64);

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

fn handle_player(ctx: *anyopaque, event: zb.PlayerIDToServer) !void {
    var self: *Self = @ptrCast(@alignCast(ctx));

    if (event.protocol_version != 0x07) {
        try self.send_disconnect("Protocol version incompatible; Update to Protocol Version 7.");
    }

    for (0..16) |i| {
        if (event.username[i] == ' ') {
            // Spaces are not allowed in names, indicates the end.
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
    // TODO: Send initial packets

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
