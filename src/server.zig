const std = @import("std");
const assert = std.debug.assert;

const zb = @import("protocol");
const c = @import("constants.zig");
const srb = @import("spinning_ringbuffer.zig");
const IO = @import("io.zig");
const Client = @import("client.zig");
const World = @import("world.zig");

var ringbuffer: srb.SpinningRingbuffer(Client, c.MaxClients) = undefined;
pub var world: World = undefined;

const Self = @This();

pub fn init(allocator: std.mem.Allocator) !void {
    world = try World.init(allocator);
    ringbuffer = srb.SpinningRingbuffer(Client, c.MaxClients).init();
}

pub fn deinit() void {
    // TODO: Force disconnect all clients
    world.deinit();
}

pub fn broadcast_spawn_player(packet: *zb.SpawnPlayer) void {
    for (0..c.MaxClients) |i| {
        if (ringbuffer.ring[i] != null and ringbuffer.ring[i].?.initialized) {
            ringbuffer.ring[i].?.send_spawn(packet) catch continue;
        }
    }
}

pub fn broadcast_despawn_player(id: i8) void {
    for (0..c.MaxClients) |i| {
        if (ringbuffer.ring[i] != null and ringbuffer.ring[i].?.initialized) {
            ringbuffer.ring[i].?.send_despawn(id) catch continue;
        }
    }
}

pub fn broadcast_chat_message(id: i8, message: []u8) void {
    for (0..c.MaxClients) |i| {
        if (ringbuffer.ring[i] != null and ringbuffer.ring[i].?.initialized) {
            ringbuffer.ring[i].?.send_message(id, message) catch continue;
        }
    }
}

pub fn new_client(conn: IO.Connection) void {
    var client: Client = undefined;
    client.connection = conn;
    client.initialized = false;

    const id = ringbuffer.add(client);

    if (id) |i| {
        ringbuffer.ring[i].?.id = @intCast(i);

        ringbuffer.ring[i].?.init();
    } else {
        client.send_disconnect("Server Full!") catch return;
    }
}
pub fn tick() void {
    for (0..c.MaxClients) |i| {
        if (ringbuffer.ring[i]) |client| {
            const stay_connected = ringbuffer.ring[i].?.tick();
            if (!stay_connected or ringbuffer.ring[i].?.disconnected) {
                const id = client.id;
                ringbuffer.remove(@intCast(id));
                broadcast_despawn_player(@intCast(id));
            }
        }
    }
}
