const std = @import("std");
const assert = std.debug.assert;

const zb = @import("protocol");
const c = @import("constants.zig");
const srb = @import("spinning_ringbuffer.zig");
const IO = @import("io.zig");
const Client = @import("client.zig");
const World = @import("world.zig");

pub var player_ring: srb.SpinningRingbuffer(Client, c.MaxClients) = undefined;
pub var world: World = undefined;

const Self = @This();

pub fn init(allocator: std.mem.Allocator) !void {
    world = try World.init(allocator);
    player_ring = srb.SpinningRingbuffer(Client, c.MaxClients).init();
}

pub fn deinit() void {
    // TODO: Force disconnect all clients
    world.deinit();
}

pub fn broadcast_spawn_player(packet: *zb.SpawnPlayer) void {
    for (0..c.MaxClients) |i| {
        if (player_ring.ring[i] != null and player_ring.ring[i].?.initialized) {
            player_ring.ring[i].?.send_spawn(packet) catch continue;
        }
    }
}

pub fn broadcast_despawn_player(id: i8) void {
    for (0..c.MaxClients) |i| {
        if (player_ring.ring[i] != null and player_ring.ring[i].?.initialized) {
            player_ring.ring[i].?.send_despawn(id) catch continue;
        }
    }
}

pub fn broadcast_chat_message(id: i8, message: []u8) void {
    for (0..c.MaxClients) |i| {
        if (player_ring.ring[i] != null and player_ring.ring[i].?.initialized) {
            player_ring.ring[i].?.send_message(id, message) catch continue;
        }
    }
}

pub fn broadcast_player_positions() void {
    for (0..c.MaxClients) |i| {
        if (player_ring.ring[i] == null or !player_ring.ring[i].?.initialized)
            continue;

        for (0..c.MaxClients) |j| {
            if (i == j)
                continue;

            if (player_ring.ring[j] != null and player_ring.ring[j].?.initialized) {
                const p = player_ring.ring[j].?;
                player_ring.ring[i].?.send_player_position(p.id, p.x, p.y, p.z, p.yaw, p.pitch) catch continue;
            }
        }
    }
}

pub fn new_client(conn: IO.Connection) void {
    var client: Client = undefined;
    client.connection = conn;
    client.initialized = false;

    const id = player_ring.add(client);

    if (id) |i| {
        player_ring.ring[i].?.id = @intCast(i);

        player_ring.ring[i].?.init();
    } else {
        client.send_disconnect("Server Full!") catch return;
    }
}

pub fn tick() void {
    for (0..c.MaxClients) |i| {
        if (player_ring.ring[i]) |client| {
            const stay_connected = player_ring.ring[i].?.tick();

            if (!stay_connected or player_ring.ring[i].?.disconnected) {
                const id = client.id;
                player_ring.remove(@intCast(id));
                broadcast_despawn_player(@intCast(id));
            }
        }
    }

    broadcast_player_positions();
}
