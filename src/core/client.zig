const std = @import("std");
const zb = @import("protocol");
const Protocol = zb.Protocol;

const Self = @This();

id: i8,
x: u16,
y: u16,
z: u16,
yaw: u8,
pitch: u8,

reader: *std.io.Reader,
writer: *std.io.Writer,
connected: *bool,

name: [16:0]u8,
initialized: bool,
protocol: Protocol,

buffer: [1024]u8,
world_buffer_idx: usize,

fn ctx_to_client(ctx: *anyopaque) *Self {
    return @ptrCast(@alignCast(ctx));
}

fn read_packet(self: *Self) !bool {
    const packet_id = try self.reader.peekByte();

    const len: u8 = switch (packet_id) {
        0x00 => 131,
        0x05 => 9,
        0x08 => 10,
        0x0D => 66,
        else => return false, // TODO: Log unknown packet
    };

    const buffer = try self.reader.peek(len);
    @memcpy(self.buffer[0..len], buffer);

    self.reader.toss(len);
    return true;
}

fn handle_player(ctx: *anyopaque, event: zb.PlayerIDToServer) !void {
    const self = ctx_to_client(ctx);

    if (event.protocol_version != 0x07) {
        std.debug.print("Unsupported protocol version: {d}\n", .{event.protocol_version});
        self.connected.* = false;
        return;
    }

    std.debug.print("Username: {s}\n", .{event.username});
    std.debug.print("Key: {s}\n", .{event.key});
}

pub fn init(self: *Self) void {
    self.protocol = Protocol.init(.Client, .Connected, self);
    self.protocol.handle = .{
        .handle_PlayerIDToServer = handle_player,
    };
}

pub fn tick(self: *Self) bool {
    while (true) {
        const received = self.read_packet() catch |e| switch (e) {
            error.ReadFailed => false,
            else => {
                self.connected.* = false;
                return false;
            },
        };

        if (!received) break;
        self.protocol.handle_packet(self.buffer[0..], self.buffer[0]) catch return false;
    }

    return true;
}
