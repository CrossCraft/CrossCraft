const std = @import("std");
const zb = @import("protocol");
const IO = @import("io.zig");

const Self = @This();

id: i8,
x: u16,
y: u16,
z: u16,
yaw: u8,
pitch: u8,
connection: IO.Connection,
name: [16:0]u8,
initialized: bool,
protocol: zb.Protocol,

buffer: [131]u8,

pub fn init(self: *Self) void {
    self.protocol = zb.Protocol.init(.Client, .Connected, self);
    self.protocol.handle = .{
        .handle_PlayerIDToServer = handle_player,
    };
}

fn handle_player(self: *anyopaque, event: zb.PlayerIDToServer) !void {
    _ = self;

    std.debug.print("PlayerIDToServer\n", .{});

    std.debug.print("Username: {s}\n", .{event.username});
    std.debug.print("Key: {s}\n", .{event.key});
    std.debug.print("Protocol Version: {}\n", .{event.protocol_version});
}

pub fn tick(self: *Self) bool {
    var received = self.connection.read(&self.buffer) catch return false;

    while (received) {
        self.protocol.handle_packet(self.buffer[1..], self.buffer[0]) catch return false;
        received = self.connection.read(&self.buffer) catch return false;
    }

    return true;
}
