const std = @import("std");
const assert = std.debug.assert;
const zb = @import("protocol");
const core = @import("core");
const proto = core.protocol;
const Block = core.blocks.Block;

const World = core.World;
const WorldRenderer = @import("../world/world.zig");
const PlayerList = @import("../ui/PlayerList.zig");
const Chat = @import("../ui/Chat.zig");
const Session = @import("../state/Session.zig");

const log = std.log.scoped(.client_conn);

const ClientConn = @This();

reader: *std.Io.Reader,
writer: *std.Io.Writer,
protocol: zb.Protocol,

spawn_x: u16,
spawn_y: u16,
spawn_z: u16,
handshake_complete: bool,
quit_requested: bool,

world_renderer: ?*WorldRenderer,
player_list: ?*PlayerList,
chat: ?*Chat,

buffer: [1028]u8,

pub fn init(self: *ClientConn, reader: *std.Io.Reader, writer: *std.Io.Writer) void {
    self.reader = reader;
    self.writer = writer;
    self.spawn_x = 0;
    self.spawn_y = 0;
    self.spawn_z = 0;
    self.handshake_complete = false;
    self.quit_requested = false;
    self.world_renderer = null;
    self.player_list = null;
    self.chat = null;
    self.protocol = zb.Protocol.init(.server, .Connected, self);
    self.protocol.handles = .{
        .onPlayerIDToClient = on_player_id,
        .onLevelInitialize = on_level_initialize,
        .onLevelDataChunk = on_level_data_chunk,
        .onLevelFinalize = on_level_finalize,
        .onSpawnPlayer = on_spawn,
        .onSetPositionOrientation = on_position,
        .onMessage = on_message,
        .onSetBlockToClient = on_block_change,
        .onDespawnPlayer = on_despawn,
        .onDisconnectPlayer = on_disconnect,
    };
}

pub fn join(self: *ClientConn, username: []const u8) !void {
    try proto.send_player_id_to_server(self.writer, username);
    try self.writer.flush();
}

fn process_packet(self: *ClientConn) !void {
    const packet_id = try self.reader.peekByte();
    const len = proto.packet_length_to_client(packet_id) catch |err| {
        log.err("unknown packet id 0x{x:0>2}: {}", .{ packet_id, err });
        return err;
    };
    const buf = try self.reader.peek(len);
    assert(len > 0 and len <= self.buffer.len);
    @memcpy(self.buffer[0..len], buf);
    self.reader.toss(len);
    self.protocol.handle_packet(self.buffer[1..len], self.buffer[0]) catch |err| {
        log.err("failed to handle packet 0x{x:0>2}: {}", .{ self.buffer[0], err });
        return err;
    };
}

pub fn drain_packets(self: *ClientConn) void {
    while (!self.quit_requested) self.process_packet() catch return;
}

/// Publishes the disconnect reason before the game thread observes closure.
pub fn read_loop(self: *ClientConn, connected: *std.atomic.Value(bool)) void {
    defer connected.store(false, .release);

    while (connected.load(.acquire) and !self.quit_requested) {
        self.process_packet() catch |err| {
            log.info("read_loop: {} - closing", .{err});
            Session.set_disconnect_reason_if_empty("Connection lost");
            return;
        };
    }
}

fn on_player_id(_: *anyopaque, event: zb.PlayerIDToClient) !void {
    log.info("PlayerID: version={d}", .{event.protocol_version});
    log.info("  name={s}", .{&event.server_name});
    log.info("  motd={s}", .{&event.server_motd});
}

fn on_level_initialize(_: *anyopaque, _: zb.LevelInitialize) !void {
    log.info("LevelInitialize", .{});
}

fn on_level_data_chunk(_: *anyopaque, event: zb.LevelDataChunk) !void {
    log.info("LevelDataChunk: {d} bytes, {d}%", .{ event.length, event.percent });
}

fn on_level_finalize(_: *anyopaque, event: zb.LevelFinalize) !void {
    log.info("LevelFinalize: {d}x{d}x{d}", .{ event.x, event.y, event.z });
}

fn on_spawn(ctx: *anyopaque, event: zb.SpawnPlayer) !void {
    const self: *ClientConn = @ptrCast(@alignCast(ctx));
    log.info("SpawnPlayer: pid={d} pos=({d},{d},{d})", .{ event.pid, event.x, event.y, event.z });
    if (event.pid == -1) {
        self.spawn_x = event.x;
        self.spawn_y = event.y;
        self.spawn_z = event.z;
        self.handshake_complete = true;
        return;
    }
    if (self.player_list) |pl| pl.spawn(event.pid, &event.name, event.x, event.y, event.z, event.yaw, event.pitch);
}

fn on_position(ctx: *anyopaque, event: zb.SetPositionOrientation) !void {
    const self: *ClientConn = @ptrCast(@alignCast(ctx));
    if (self.player_list) |pl| pl.update_position(event.pid, event.x, event.y, event.z, event.yaw, event.pitch);
}

fn on_message(ctx: *anyopaque, event: zb.Message) !void {
    const self: *ClientConn = @ptrCast(@alignCast(ctx));
    log.info("Message: pid={d} {s}", .{ event.pid, &event.message });
    if (self.chat) |ch| ch.receive(&event.message);
}

fn on_block_change(ctx: *anyopaque, event: zb.SetBlockToClient) !void {
    const self: *ClientConn = @ptrCast(@alignCast(ctx));
    const wr = self.world_renderer orelse return;
    // Singleplayer already applied this change to the shared world.
    const block: Block = @enumFromInt(event.block);
    World.lock_world();
    World.data.apply_block(event.x, event.y, event.z, block);
    World.unlock_world();
    const cx: u8 = @intCast(event.x >> 4);
    const cz: u8 = @intCast(event.z >> 4);
    const sy: u8 = @intCast(event.y >> 4);
    const lx: u16 = event.x & 0xF;
    const ly: u16 = event.y & 0xF;
    const lz: u16 = event.z & 0xF;
    wr.mark_block_change_dirty(cx, sy, cz, lx, ly, lz, block.is_air());
    // Sunlight changes invalidate the column down to the next opaque block.
    if (event.y > 0) {
        var walk_y: u16 = event.y - 1;
        while (true) {
            const walk_sy: u8 = @intCast(walk_y >> 4);
            wr.mark_section_dirty(cx, walk_sy, cz);
            if (lx == 0 and cx > 0) wr.mark_section_dirty(cx - 1, walk_sy, cz);
            if (lx == 15) wr.mark_section_dirty(cx + 1, walk_sy, cz);
            if (lz == 0 and cz > 0) wr.mark_section_dirty(cx, walk_sy, cz - 1);
            if (lz == 15) wr.mark_section_dirty(cx, walk_sy, cz + 1);
            if (!World.data.get_block(event.x, walk_y, event.z).light_passes()) break;
            if (walk_y == 0) break;
            walk_y -= 1;
        }
    }
}

fn on_despawn(ctx: *anyopaque, event: zb.DespawnPlayer) !void {
    const self: *ClientConn = @ptrCast(@alignCast(ctx));
    log.info("Despawn: pid={d}", .{event.pid});
    if (self.player_list) |pl| pl.despawn(event.pid);
}

fn on_disconnect(ctx: *anyopaque, event: zb.DisconnectPlayer) !void {
    const self: *ClientConn = @ptrCast(@alignCast(ctx));
    log.info("Disconnect: {s}", .{&event.reason});
    const trimmed = std.mem.trimEnd(u8, &event.reason, " ");
    Session.set_disconnect_reason(trimmed);
    self.quit_requested = true;
}

test "multiplayer disconnect stops dispatch and publishes the server reason" {
    defer Session.clear_disconnect_reason();

    Session.clear_disconnect_reason();
    var bytes: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&bytes);
    try proto.send_disconnect_to_client(&writer, "Server shutting down");
    try proto.send_message(&writer, 0, "Must not be dispatched");
    var reader = std.Io.Reader.fixed(writer.buffered());
    var conn: ClientConn = undefined;
    conn.init(&reader, &writer);
    var connected: std.atomic.Value(bool) = .init(true);

    conn.read_loop(&connected);

    try std.testing.expect(!connected.load(.acquire));
    try std.testing.expectEqualStrings("Server shutting down", Session.disconnect_reason());
    try std.testing.expectEqual(@as(usize, 65), reader.seek);
}

test "multiplayer truncated packet publishes connection loss" {
    defer Session.clear_disconnect_reason();

    Session.clear_disconnect_reason();
    var reader = std.Io.Reader.fixed(&.{ 0x0e, 'x' });
    var writer = std.Io.Writer.fixed(&.{});
    var conn: ClientConn = undefined;
    conn.init(&reader, &writer);
    var connected: std.atomic.Value(bool) = .init(true);

    conn.read_loop(&connected);

    try std.testing.expect(!connected.load(.acquire));
    try std.testing.expectEqualStrings("Connection lost", Session.disconnect_reason());
}
