const std = @import("std");
const consts = @import("consts.zig");

const Self = @This();

world_tick: usize = 0,

pub fn init(allocator: std.mem.Allocator) !Self {
    _ = allocator;

    return .{};
}

pub fn client_join(self: *Self, reader: *std.io.Reader, writer: *std.io.Writer, connected: *bool) void {
    _ = self;
    _ = reader;
    _ = writer;

    // Handle new client connection
    std.debug.print("Client joined the server!\n", .{});
    connected.* = false;
}

pub fn tick(self: *Self) void {
    self.world_tick += 1;
}

pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
    _ = allocator;

    self.world_tick = 0;
}
