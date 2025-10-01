const std = @import("std");
const consts = @import("consts.zig");
const FAB = @import("fa_buffer.zig").FirstAvailableBuffer;
const Client = @import("client.zig");
const StaticAllocator = @import("static_allocator.zig");
const world = @import("world.zig");
const zb = @import("protocol");

var allocator: StaticAllocator = undefined;

pub var players: FAB(Client, consts.MAX_PLAYERS) = .init();
pub var name: consts.Message = @splat(' ');
pub var motd: consts.Message = @splat(' ');

pub fn init(alloc: std.mem.Allocator, seed: u64) !void {
    std.mem.copyForwards(u8, &name, "A Classic Server!");
    std.mem.copyForwards(u8, &motd, "Welcome to CrossCraft! Another adventure awaits!");

    allocator = .init(alloc);

    try world.init(allocator.allocator(), seed);

    allocator.transition_from_init_to_static();
}

pub fn deinit() void {
    world.deinit();

    allocator.transition_from_static_to_deinit();
    allocator.deinit();
}

pub fn client_join(reader: *std.io.Reader, writer: *std.io.Writer, connected: *bool) void {
    var client: Client = undefined;
    client.connected = connected;
    client.reader = reader;
    client.writer = writer;

    const id = players.add(client);

    if (id) |i| {
        players.items[i].?.id = @intCast(i);
        players.items[i].?.init();
    } else {
        defer connected.* = false;
        client.send_disconnect("Server is full!") catch return;
    }
}

pub fn broadcast_spawn_player(packet: *zb.SpawnPlayer) void {
    for (0..consts.MAX_PLAYERS) |i| {
        if (players.items[i] != null and players.items[i].?.initialized) {
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
            const stay_connected = players.items[i].?.tick();

            if (!stay_connected or !players.items[i].?.connected.*) {
                const id = client.id;
                players.remove(@intCast(id));

                broadcast_despawn_player(id);
            }
        }
    }

    world.tick();

    broadcast_player_positions();
}
