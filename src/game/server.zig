const std = @import("std");
const consts = @import("common").consts;
const FAB = @import("common").fa_buffer.FirstAvailableBuffer;
pub const Client = @import("client.zig");
const StaticAllocator = @import("common").static_allocator;
const world = @import("world.zig");
const zb = @import("protocol");

const log = std.log.scoped(.server);

var allocator: StaticAllocator = undefined;

pub var players: FAB(Client, consts.MAX_PLAYERS) = .init();

pub fn init(alloc: std.mem.Allocator, seed: u64) !void {
    allocator = .init(alloc);

    try world.init(allocator.allocator(), seed);

    allocator.transition_from_init_to_static();
}

pub fn deinit() void {
    allocator.transition_from_static_to_deinit();

    world.deinit();

    allocator.deinit();
}

pub fn client_join(reader: *std.Io.Reader, writer: *std.Io.Writer, connected: *bool) ?*Client {
    log.info("client_join: new client joining", .{});
    var client: Client = undefined;
    client.connected = connected;
    client.reader = reader;
    client.writer = writer;

    const id = players.add(client);

    if (id) |i| {
        log.info("client_join: assigned slot {d}", .{i});
        players.items[i].?.id = @intCast(i);
        players.items[i].?.init();
        log.info("client_join: client initialized, returning", .{});
        return &(players.items[i].?);
    } else {
        log.info("client_join: server full, rejecting", .{});
        defer connected.* = false;
        client.send_disconnect("Server is full!") catch return null;
        return null;
    }
}

pub fn broadcast_spawn_player(sender_id: i8, packet: *zb.SpawnPlayer) void {
    for (0..consts.MAX_PLAYERS) |i| {
        if (players.items[i] != null and players.items[i].?.initialized and players.items[i].?.id != sender_id) {
            players.items[i].?.send_spawn(packet) catch continue;
            players.items[i].?.writer.flush() catch continue;
        }
    }
}

pub fn broadcast_despawn_player(id: i8) void {
    for (0..consts.MAX_PLAYERS) |i| {
        if (players.items[i] != null and players.items[i].?.initialized) {
            players.items[i].?.send_despawn(id) catch continue;
            players.items[i].?.writer.flush() catch continue;
        }
    }
}

pub fn broadcast_chat_message(id: i8, message: []u8) void {
    for (0..consts.MAX_PLAYERS) |i| {
        if (players.items[i] != null and players.items[i].?.initialized) {
            players.items[i].?.send_message(id, message) catch continue;
            players.items[i].?.writer.flush() catch continue;
        }
    }
}

pub fn broadcast_block_change(x: u16, y: u16, z: u16, block_type: u8) void {
    for (0..consts.MAX_PLAYERS) |i| {
        if (players.items[i] != null and players.items[i].?.initialized) {
            players.items[i].?.send_block_change(x, y, z, block_type) catch continue;
            players.items[i].?.writer.flush() catch continue;
        }
    }
}

pub fn broadcast_player_positions() void {
    for (0..consts.MAX_PLAYERS) |i| {
        if (players.items[i] == null or !players.items[i].?.initialized)
            continue;

        for (0..consts.MAX_PLAYERS) |j| {
            if (i == j)
                continue;

            if (players.items[j] != null and players.items[j].?.initialized) {
                const p = players.items[j].?;
                players.items[i].?.send_player_position(p.id, p.x, p.y, p.z, p.yaw, p.pitch) catch continue;
                players.items[i].?.writer.flush() catch continue;
            }
        }
    }
}

pub fn tick() void {
    for (0..consts.MAX_PLAYERS) |i| {
        if (players.items[i]) |client| {
            if (!client.connected.*) {
                const id = client.id;
                players.remove(@intCast(id));

                broadcast_despawn_player(id);
            }
        }
    }

    world.tick();

    broadcast_player_positions();
}
