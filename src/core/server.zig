const std = @import("std");
const consts = @import("consts.zig");
const FAB = @import("fa_buffer.zig").FirstAvailableBuffer;
const Client = @import("client.zig");
const StaticAllocator = @import("static_allocator.zig");

const Self = @This();

allocator: StaticAllocator,
players: FAB(Client, consts.MAX_PLAYERS) = .init(),
world_tick: usize = 0,

pub fn init(allocator: std.mem.Allocator) !Self {
    var result: Self = .{
        .allocator = .init(allocator),
    };

    // Allocs

    result.allocator.transition_from_init_to_static();
    return result;
}

pub fn deinit(self: *Self) void {
    self.allocator.transition_from_static_to_deinit();

    // Frees

    self.allocator.deinit();
}

pub fn client_join(self: *Self, reader: *std.io.Reader, writer: *std.io.Writer, connected: *bool) void {
    var client: Client = undefined;
    client.connected = connected;
    client.reader = reader;
    client.writer = writer;

    const id = self.players.add(client);

    if (id) |i| {
        self.players.items[i].?.id = @intCast(i);
        self.players.items[i].?.init();

        // Handle new client connection
        std.debug.print("Client joined the server!\n", .{});
    } else {
        // TODO: Actually kick the client
        std.debug.print("Server is full! Disconnecting client...\n", .{});
        connected.* = false;
        return;
    }
}

pub fn tick(self: *Self) void {
    self.world_tick += 1;

    for (0..consts.MAX_PLAYERS) |i| {
        if (self.players.items[i]) |client| {
            const stay_connected = self.players.items[i].?.tick();

            if (!stay_connected or !self.players.items[i].?.connected.*) {
                const id = client.id;
                self.players.remove(@intCast(id));

                // TODO: Broadcast to other players that this player has left
            }
        }
    }

    // TODO: Broadcast world state to all clients
}
