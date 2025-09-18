const std = @import("std");
const consts = @import("consts.zig");
const FAB = @import("fa_buffer.zig").FirstAvailableBuffer;
const Client = @import("client.zig");
const StaticAllocator = @import("static_allocator.zig");
const world = @import("world.zig");

var allocator: StaticAllocator = undefined;
var players: FAB(Client, consts.MAX_PLAYERS) = .init();
var world_tick: usize = 0;

pub var name: consts.Message = @splat(' ');
pub var motd: consts.Message = @splat(' ');

pub fn init(alloc: std.mem.Allocator) !void {
    std.mem.copyForwards(u8, &name, "A Classic Server!");
    std.mem.copyForwards(u8, &motd, "Welcome to CrossCraft! Another adventure awaits!");

    allocator = .init(alloc);

    try world.init(allocator.allocator());

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

pub fn tick() void {
    world_tick += 1;

    for (0..consts.MAX_PLAYERS) |i| {
        if (players.items[i]) |client| {
            const stay_connected = players.items[i].?.tick();

            if (!stay_connected or !players.items[i].?.connected.*) {
                const id = client.id;
                players.remove(@intCast(id));

                // TODO: Broadcast to other players that this player has left
            }
        }
    }

    // TODO: Broadcast world state to all clients
    world.tick();
}
