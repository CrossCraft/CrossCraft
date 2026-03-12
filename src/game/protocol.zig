const std = @import("std");
const zb = @import("protocol");
const assert = std.debug.assert;
const c = @import("common").consts;

const Writer = std.Io.Writer;

pub fn packet_length(packet_id: u8) !u8 {
    return switch (packet_id) {
        0x00 => 131, // Player to Server
        0x05 => 9, // Set Block to Server
        0x08 => 10, // Position and Orientation to Server
        0x0D => 66, // Message to Server
        else => return error.InvalidPacketID,
    };
}

pub fn send_message(writer: *Writer, self_id: i8, id: i8, message: []u8) !void {
    var msg_buf: [64]u8 = @splat(' ');
    @memcpy(msg_buf[0..message.len], message);
    var msg = zb.Message{
        .pid = if (id == self_id) -1 else id,
        .message = msg_buf,
    };
    try msg.write(writer);
}

pub fn send_disconnect(writer: *Writer, reason: []const u8) !void {
    assert(reason.len <= 64);

    var reason_buf: c.Message = @splat(' ');
    for (0..reason_buf.len) |i| {
        if (i < reason.len) {
            reason_buf[i] = reason[i];
        }
    }

    var packet: zb.DisconnectPlayer = .{
        .reason = reason_buf,
    };

    try packet.write(writer);
    try writer.flush();
}

pub fn send_player_position(writer: *Writer, id: i8, x: u16, y: u16, z: u16, yaw: u8, pitch: u8) !void {
    var position = zb.SetPositionOrientation{
        .pid = id,
        .x = x,
        .y = y,
        .z = z,
        .yaw = yaw,
        .pitch = pitch,
    };

    try position.write(writer);
}

pub fn send_spawn(writer: *Writer, packet: *zb.SpawnPlayer) !void {
    try packet.write(writer);
}

pub fn send_despawn(writer: *Writer, id: i8) !void {
    var despawn_packet = zb.DespawnPlayer{
        .pid = id,
    };

    try despawn_packet.write(writer);
}

pub fn send_block_change(writer: *Writer, x: u16, y: u16, z: u16, block: u8) !void {
    var block_change = zb.SetBlockToClient{
        .x = x,
        .y = y,
        .z = z,
        .block = block,
    };

    try block_change.write(writer);
}

pub fn send_level_initialize(writer: *Writer) !void {
    try writer.writeByte(0x02);
}

pub fn send_level_chunk(writer: *Writer, length: u16, data: *const [1024]u8, percent: u8) !void {
    var level_chunk = zb.LevelDataChunk{
        .length = length,
        .data = data.*,
        .percent = percent,
    };
    try level_chunk.write(writer);
}

pub fn send_level_finalize(writer: *Writer) !void {
    var level_finalize = zb.LevelFinalize{
        .x = c.WorldLength,
        .y = c.WorldHeight,
        .z = c.WorldDepth,
    };
    try level_finalize.write(writer);
}

pub fn send_player_id(writer: *Writer, server_name: *const [64]u8, server_motd: *const [64]u8) !void {
    var server_data = zb.PlayerIDToClient{
        .protocol_version = 0x07,
        .server_name = server_name.*,
        .server_motd = server_motd.*,
        .user_type = .Normal,
    };
    try server_data.write(writer);
}
