const std = @import("std");
const zb = @import("protocol");
const proto = @import("common").protocol;

const World = @import("game").World;
const WorldRenderer = @import("../world/world.zig");
const PlayerList = @import("../ui/PlayerList.zig");
const Chat = @import("../ui/Chat.zig");
const Session = @import("../state/Session.zig");

const log = std.log.scoped(.client_conn);

const Self = @This();

reader: *std.Io.Reader,
writer: *std.Io.Writer,
protocol: zb.Protocol,

spawn_x: u16,
spawn_y: u16,
spawn_z: u16,
world_x: u16,
world_y: u16,
world_z: u16,
handshake_complete: bool,
/// Set by `on_disconnect` (or other fatal packet paths); GameState polls it
/// each draw and calls `engine.quit()` when true. Avoids threading an
/// engine pointer into every packet handler.
quit_requested: bool,

/// Set by GameState after the world renderer exists. Block-change packets
/// from the server use it to mark affected sections for rebuild.
world_renderer: ?*WorldRenderer,

/// Set by GameState after the player list is initialised. SpawnPlayer /
/// DespawnPlayer packets for remote players (pid != -1) are forwarded here.
player_list: ?*PlayerList,

/// Set by GameState after Chat is initialised. Incoming Message packets
/// are forwarded here so the chat overlay can display them.
chat: ?*Chat,

buffer: [1028]u8,

pub fn init(self: *Self, reader: *std.Io.Reader, writer: *std.Io.Writer) void {
    self.reader = reader;
    self.writer = writer;
    self.spawn_x = 0;
    self.spawn_y = 0;
    self.spawn_z = 0;
    self.world_x = 0;
    self.world_y = 0;
    self.world_z = 0;
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

pub fn join(self: *Self, username: []const u8) !void {
    try proto.send_player_id_to_server(self.writer, username);
    try self.writer.flush();
}

/// Non-blocking: read and process one server packet if available.
pub fn try_process_packet(self: *Self) bool {
    const packet_id = self.reader.peekByte() catch return false;
    const len = proto.packet_length_to_client(packet_id) catch |err| {
        log.err("unknown packet id 0x{x:0>2}: {}", .{ packet_id, err });
        return false;
    };
    const buf = self.reader.peek(len) catch return false;
    @memcpy(self.buffer[0..len], buf);
    self.reader.toss(len);
    self.protocol.handle_packet(self.buffer[1..len], self.buffer[0]) catch |err| {
        log.err("failed to handle packet 0x{x:0>2}: {}", .{ self.buffer[0], err });
        return false;
    };
    return true;
}

pub fn drain_packets(self: *Self) void {
    while (self.try_process_packet()) {}
}

/// Blocking read loop: runs on an Io thread pool task for multiplayer
/// (mirrors `src/server/main.zig:client_read_loop`). Reads one packet at
/// a time and hands it to the protocol dispatcher; the callbacks mutate
/// the shared World singleton and world renderer directly, the same way
/// the server mutates its world from per-client read tasks.
///
/// Exits on `connected.* == false`, which the disconnect handler and any
/// read/dispatch failure set so the game thread can observe the drop.
pub fn read_loop(self: *Self, connected: *std.atomic.Value(bool)) void {
    while (connected.load(.acquire)) {
        const packet_id = self.reader.peekByte() catch |err| {
            log.info("read_loop: {} - closing", .{err});
            // Only set generic reason if on_disconnect didn't already set one.
            if (Session.disconnect_reason_len == 0) {
                Session.set_disconnect_reason("Connection lost");
            }
            connected.store(false, .release);
            return;
        };
        const len = proto.packet_length_to_client(packet_id) catch |err| {
            log.err("read_loop: unknown packet 0x{x:0>2}: {}", .{ packet_id, err });
            if (Session.disconnect_reason_len == 0) {
                Session.set_disconnect_reason("Connection lost");
            }
            connected.store(false, .release);
            return;
        };
        const buf = self.reader.peek(len) catch |err| {
            log.info("read_loop peek: {} - closing", .{err});
            if (Session.disconnect_reason_len == 0) {
                Session.set_disconnect_reason("Connection lost");
            }
            connected.store(false, .release);
            return;
        };
        @memcpy(self.buffer[0..len], buf);
        self.reader.toss(len);
        self.protocol.handle_packet(self.buffer[1..len], self.buffer[0]) catch |err| {
            log.err("read_loop handle 0x{x:0>2}: {}", .{ self.buffer[0], err });
            if (Session.disconnect_reason_len == 0) {
                Session.set_disconnect_reason("Connection lost");
            }
            connected.store(false, .release);
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

fn on_level_finalize(ctx: *anyopaque, event: zb.LevelFinalize) !void {
    const self: *Self = @ptrCast(@alignCast(ctx));
    self.world_x = event.x;
    self.world_y = event.y;
    self.world_z = event.z;
    log.info("LevelFinalize: {d}x{d}x{d}", .{ event.x, event.y, event.z });
}

fn on_spawn(ctx: *anyopaque, event: zb.SpawnPlayer) !void {
    const self: *Self = @ptrCast(@alignCast(ctx));
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
    const self: *Self = @ptrCast(@alignCast(ctx));
    if (self.player_list) |pl| pl.update_position(event.pid, event.x, event.y, event.z, event.yaw, event.pitch);
}

fn on_message(ctx: *anyopaque, event: zb.Message) !void {
    const self: *Self = @ptrCast(@alignCast(ctx));
    log.info("Message: pid={d} {s}", .{ event.pid, &event.message });
    if (self.chat) |ch| ch.receive(&event.message);
}

fn on_block_change(ctx: *anyopaque, event: zb.SetBlockToClient) !void {
    const self: *Self = @ptrCast(@alignCast(ctx));
    const wr = self.world_renderer orelse return;
    // Apply the change locally. Singleplayer's in-process server already
    // wrote it to the shared World singleton, so this is a no-op echo there;
    // for real multiplayer it is the only path that updates the client world.
    World.set_block(event.x, event.y, event.z, @enumFromInt(event.block));
    // Translate world block coords to (cx, sy, cz) section indices.
    const cx: u8 = @intCast(event.x >> 4);
    const cz: u8 = @intCast(event.z >> 4);
    const sy: u8 = @intCast(event.y >> 4);
    wr.mark_section_dirty(cx, sy, cz);
    // Border blocks need their neighbor sections rebuilt as well, since
    // greedy meshing reads a 1-block padding from adjacent sections.
    const lx: u16 = event.x & 0xF;
    const ly: u16 = event.y & 0xF;
    const lz: u16 = event.z & 0xF;
    if (lx == 0 and cx > 0) wr.mark_section_dirty(cx - 1, sy, cz);
    if (lx == 15) wr.mark_section_dirty(cx + 1, sy, cz);
    if (lz == 0 and cz > 0) wr.mark_section_dirty(cx, sy, cz - 1);
    if (lz == 15) wr.mark_section_dirty(cx, sy, cz + 1);
    if (ly == 0 and sy > 0) wr.mark_section_dirty(cx, sy - 1, cz);
    if (ly == 15) wr.mark_section_dirty(cx, sy + 1, cz);
    // Lighting propagation: a sunlight change at (x,y,z) affects every
    // transparent block below it down to the next light-blocking block.
    // Mark the section column (and XZ-boundary neighbours) dirty for each
    // affected level so those meshes pick up the new shading.
    if (event.y > 0) {
        var walk_y: u16 = event.y - 1;
        while (true) {
            const walk_sy: u8 = @intCast(walk_y >> 4);
            wr.mark_section_dirty(cx, walk_sy, cz);
            if (lx == 0 and cx > 0) wr.mark_section_dirty(cx - 1, walk_sy, cz);
            if (lx == 15) wr.mark_section_dirty(cx + 1, walk_sy, cz);
            if (lz == 0 and cz > 0) wr.mark_section_dirty(cx, walk_sy, cz - 1);
            if (lz == 15) wr.mark_section_dirty(cx, walk_sy, cz + 1);
            if (World.blocks_light(World.get_block(event.x, walk_y, event.z))) break;
            if (walk_y == 0) break;
            walk_y -= 1;
        }
    }
}

fn on_despawn(ctx: *anyopaque, event: zb.DespawnPlayer) !void {
    const self: *Self = @ptrCast(@alignCast(ctx));
    log.info("Despawn: pid={d}", .{event.pid});
    if (self.player_list) |pl| pl.despawn(event.pid);
}

fn on_disconnect(ctx: *anyopaque, event: zb.DisconnectPlayer) !void {
    const self: *Self = @ptrCast(@alignCast(ctx));
    log.info("Disconnect: {s}", .{&event.reason});
    // Save trimmed reason so DisconnectState can display it. Written before
    // quit_requested is set; the game thread reads it after observing quit_requested.
    const trimmed = std.mem.trimEnd(u8, &event.reason, " ");
    Session.set_disconnect_reason(trimmed);
    self.quit_requested = true;
}
