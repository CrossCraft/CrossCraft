const std = @import("std");
const net = @import("net");

const Self = @This();

world_tick: usize = 0,

pub fn init(allocator: std.mem.Allocator) !Self {
    _ = allocator;

    return .{};
}

pub fn tick(self: *Self) void {
    self.world_tick += 1;
}

pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
    _ = allocator;

    self.world_tick = 0;
}
