const std = @import("std");
const assert = std.debug.assert;
const zb = @import("protocol");

const c = @import("constants.zig");
const world = @import("world.zig");

const FIFOBuffer = @import("../common/fifo_buffer.zig").FIFOBuffer;
const IO = @import("../common/io.zig");

const Client = @import("client.zig");

pub var players: FIFOBuffer(Client, c.MaxClients) = undefined;

const Self = @This();

pub fn init(allocator: std.mem.Allocator) !void {
    try world.init(allocator);
    players = FIFOBuffer(Client, c.MaxClients).init();
}

pub fn deinit() void {
    // TODO: Force disconnect all clients
    world.deinit();
}

pub fn broadcast_spawn_player(packet: *zb.SpawnPlayer) void {
    for (0..c.MaxClients) |i| {
        if (players.items[i] != null and players.items[i].?.initialized) {
            players.items[i].?.send_spawn(packet) catch continue;
        }
    }
}

pub fn broadcast_despawn_player(id: i8) void {
    for (0..c.MaxClients) |i| {
        if (players.items[i] != null and players.items[i].?.initialized) {
            players.items[i].?.send_despawn(id) catch continue;
        }
    }
}

pub fn broadcast_chat_message(id: i8, message: []u8) void {
    for (0..c.MaxClients) |i| {
        if (players.items[i] != null and players.items[i].?.initialized) {
            players.items[i].?.send_message(id, message) catch continue;
        }
    }
}

pub fn broadcast_player_positions() void {
    for (0..c.MaxClients) |i| {
        if (players.items[i] == null or !players.items[i].?.initialized)
            continue;

        for (0..c.MaxClients) |j| {
            if (i == j)
                continue;

            if (players.items[j] != null and players.items[j].?.initialized) {
                const p = players.items[j].?;
                players.items[i].?.send_player_position(p.id, p.x, p.y, p.z, p.yaw, p.pitch) catch continue;
            }
        }
    }
}

pub fn new_client(conn: IO.Connection) void {
    var client: Client = undefined;
    client.connection = conn;
    client.initialized = false;

    const id = players.add(client);

    if (id) |i| {
        players.items[i].?.id = @intCast(i);

        players.items[i].?.init();
    } else {
        client.send_disconnect("Server Full!") catch return;
    }
}

pub fn tick() void {
    for (0..c.MaxClients) |i| {
        if (players.items[i]) |client| {
            const stay_connected = players.items[i].?.tick();

            if (!stay_connected or players.items[i].?.disconnected) {
                const id = client.id;
                players.remove(@intCast(id));
                broadcast_despawn_player(@intCast(id));
            }
        }
    }

    broadcast_player_positions();
}
