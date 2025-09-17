const std = @import("std");
const Ring = @import("ring.zig").RingBuffer;

const Connection = struct {
    reader: *std.io.Reader,
    writer: *std.io.Writer,
};

to_client: Ring(4096) = .init(),
to_server: Ring(4096) = .init(),

const Self = @This();

pub fn server_conn(self: *Self, reader_buf: []u8, writer_buf: []u8) Connection {
    return .{
        .reader = self.to_client.reader(reader_buf),
        .writer = self.to_server.writer(writer_buf),
    };
}

pub fn client_conn(self: *Self, reader_buf: []u8, writer_buf: []u8) Connection {
    return .{
        .reader = self.to_server.reader(reader_buf),
        .writer = self.to_client.writer(writer_buf),
    };
}
