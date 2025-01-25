const std = @import("std");
const assert = std.debug.assert;

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

pub fn new_client(conn: IO.Connection) void {
    var client: Client = undefined;
    client.connection = conn;
    client.initialized = false;

    const id = ringbuffer.add(client);

    if (id) |i| {
        ringbuffer.ring[i].?.id = @intCast(i);

        ringbuffer.ring[i].?.init();
    } else {
        // TODO: Send disconnect
    }
}
pub fn tick() void {
    var i: usize = 0;
    var conns: usize = 0;
    while (i < c.MaxClients) : (i += 1) {
        if (ringbuffer.ring[i]) |client| {
            conns += 1;

            const stay_connected = ringbuffer.ring[i].?.tick();
            if (!stay_connected) {
                ringbuffer.remove(@intCast(client.id));
            }
        }
    }
}
