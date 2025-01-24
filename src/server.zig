const std = @import("std");
const assert = std.debug.assert;

const c = @import("constants.zig");
const srb = @import("spinning_ringbuffer.zig");
const IO = @import("io.zig");
const Client = @import("client.zig");

backing_allocator: std.mem.Allocator,
ringbuffer: srb.SpinningRingbuffer(Client, c.MaxClients),

const Self = @This();

pub fn init(allocator: std.mem.Allocator) Self {
    return .{
        .backing_allocator = allocator,
        .ringbuffer = srb.SpinningRingbuffer(Client, c.MaxClients).init(),
    };
}

pub fn deinit(self: *Self) void {
    self.* = undefined;
}

pub fn new_client(self: *Self, conn: IO.Connection) void {
    var client: Client = undefined;
    client.connection = conn;
    client.initialized = false;

    const id = self.ringbuffer.add(client);

    if (id) |i| {
        self.ringbuffer.ring[i].?.id = @intCast(i);

        self.ringbuffer.ring[i].?.init();
    } else {
        // TODO: Send disconnect
    }
}
pub fn tick(self: *Self) void {
    var i: usize = 0;
    var conns: usize = 0;
    while (i < c.MaxClients) : (i += 1) {
        if (self.ringbuffer.ring[i]) |client| {
            conns += 1;

            const stay_connected = self.ringbuffer.ring[i].?.tick();
            if (!stay_connected) {
                self.ringbuffer.remove(@intCast(client.id));
            }
        }
    }
}
