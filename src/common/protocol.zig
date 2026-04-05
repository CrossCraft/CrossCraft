const std = @import("std");
const zb = @import("protocol");

const Writer = std.Io.Writer;

// -- Packet lengths ----------------------------------------------------------

pub fn packet_length_to_server(packet_id: u8) !u8 {
    return switch (packet_id) {
        0x00 => 131, // PlayerIDToServer
        0x05 => 9, // SetBlockToServer
        0x08 => 10, // PositionAndOrientationToServer
        0x0D => 66, // Message
        else => return error.InvalidPacketID,
    };
}

pub fn packet_length_to_client(packet_id: u8) !u16 {
    return switch (packet_id) {
        0x00 => 131, // PlayerIDToClient
        0x01 => 1, // Ping
        0x02 => 1, // LevelInitialize
        0x03 => 1028, // LevelDataChunk
        0x04 => 7, // LevelFinalize
        0x06 => 8, // SetBlockToClient
        0x07 => 74, // SpawnPlayer
        0x08 => 10, // SetPositionOrientation
        0x0C => 2, // DespawnPlayer
        0x0D => 66, // Message
        0x0E => 65, // DisconnectPlayer
        0x0F => 2, // UpdatePlayerType
        else => return error.InvalidPacketID,
    };
}

// -- Client → Server (C→S) --------------------------------------------------

pub fn send_player_id_to_server(writer: *Writer, username: []const u8) !void {
    var username_buf: [64]u8 = @splat(' ');
    const len = @min(username.len, 64);
    @memcpy(username_buf[0..len], username[0..len]);
    var packet = zb.PlayerIDToServer{
        .protocol_version = 0x07,
        .username = username_buf,
        .key = @splat(' '),
        .extension = 0,
    };
    try packet.write(writer);
}

pub fn send_position_to_server(writer: *Writer, pid: i8, x: u16, y: u16, z: u16, yaw: u8, pitch: u8) !void {
    var packet = zb.PositionAndOrientationToServer{
        .pid = pid,
        .x = x,
        .y = y,
        .z = z,
        .yaw = yaw,
        .pitch = pitch,
    };
    try packet.write(writer);
}

pub fn send_set_block_to_server(writer: *Writer, x: u16, y: u16, z: u16, mode: u8, block: u8) !void {
    var packet = zb.SetBlockToServer{
        .x = x,
        .y = y,
        .z = z,
        .mode = @enumFromInt(mode),
        .block = block,
    };
    try packet.write(writer);
}

// -- Server → Client (S→C) --------------------------------------------------

pub fn send_player_id_to_client(writer: *Writer, server_name: *const [64]u8, server_motd: *const [64]u8) !void {
    var packet = zb.PlayerIDToClient{
        .protocol_version = 0x07,
        .server_name = server_name.*,
        .server_motd = server_motd.*,
        .user_type = .Normal,
    };
    try packet.write(writer);
}

pub fn send_disconnect_to_client(writer: *Writer, reason: []const u8) !void {
    var reason_buf: [64]u8 = @splat(' ');
    const len = @min(reason.len, 64);
    @memcpy(reason_buf[0..len], reason[0..len]);
    var packet: zb.DisconnectPlayer = .{
        .reason = reason_buf,
    };
    try packet.write(writer);
    try writer.flush();
}

pub fn send_spawn_to_client(writer: *Writer, packet: *zb.SpawnPlayer) !void {
    try packet.write(writer);
}

pub fn send_despawn_to_client(writer: *Writer, id: i8) !void {
    var packet = zb.DespawnPlayer{ .pid = id };
    try packet.write(writer);
}

pub fn send_position_to_client(writer: *Writer, id: i8, x: u16, y: u16, z: u16, yaw: u8, pitch: u8) !void {
    var packet = zb.SetPositionOrientation{
        .pid = id,
        .x = x,
        .y = y,
        .z = z,
        .yaw = yaw,
        .pitch = pitch,
    };
    try packet.write(writer);
}

pub fn send_block_change_to_client(writer: *Writer, x: u16, y: u16, z: u16, block: u8) !void {
    var packet = zb.SetBlockToClient{
        .x = x,
        .y = y,
        .z = z,
        .block = block,
    };
    try packet.write(writer);
}

pub fn send_level_initialize_to_client(writer: *Writer) !void {
    try writer.writeByte(0x02);
}

pub fn send_level_chunk_to_client(writer: *Writer, length: u16, data: *const [1024]u8, percent: u8) !void {
    var packet = zb.LevelDataChunk{
        .length = length,
        .data = data.*,
        .percent = percent,
    };
    try packet.write(writer);
}

pub fn send_level_finalize_to_client(writer: *Writer, x: u16, y: u16, z: u16) !void {
    var packet = zb.LevelFinalize{
        .x = x,
        .y = y,
        .z = z,
    };
    try packet.write(writer);
}

// -- Bidirectional -----------------------------------------------------------

pub fn send_message(writer: *Writer, pid: i8, message: []const u8) !void {
    var msg_buf: [64]u8 = @splat(' ');
    const len = @min(message.len, 64);
    @memcpy(msg_buf[0..len], message[0..len]);
    var packet = zb.Message{
        .pid = pid,
        .message = msg_buf,
    };
    try packet.write(writer);
}
