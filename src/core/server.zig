const std = @import("std");
const net = @import("net");
pub const consts = @import("consts.zig");

const Self = @This();

world_tick: usize = 0,

pub fn init(allocator: std.mem.Allocator) !Self {
    _ = allocator;

    return .{};
}

pub fn client_join(self: *Self, connection: net.IO.Connection) void {
    _ = self;

    // Handle new client connection
    std.debug.print("Client joined the server!\n", .{});
    connection.connected.* = false; // For now, immediately disconnect
}

pub fn tick(self: *Self) void {
    self.world_tick += 1;
}

pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
    _ = allocator;

    self.world_tick = 0;
}
