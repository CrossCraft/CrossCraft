const std = @import("std");
const assert = std.debug.assert;

const RingSize: u32 = 4096;
const RingMask: u32 = RingSize - 1;

comptime {
    assert(std.math.isPowerOfTwo(RingSize));
}

pub const FakeConn = struct {
    s2c: [RingSize]u8 = undefined,
    s2c_head: std.atomic.Value(u32) = .init(0),
    s2c_tail: std.atomic.Value(u32) = .init(0),

    c2s: [RingSize]u8 = undefined,
    c2s_head: std.atomic.Value(u32) = .init(0),
    c2s_tail: std.atomic.Value(u32) = .init(0),

    connected: bool = true,

    server_write_buf: [1024]u8 = undefined,
    client_write_buf: [256]u8 = undefined,

    server_read_buf: [256]u8 = undefined,
    client_read_buf: [256]u8 = undefined,

    server_writer: std.Io.Writer = undefined,
    server_reader: std.Io.Reader = undefined,

    client_writer: std.Io.Writer = undefined,
    client_reader: std.Io.Reader = undefined,

    /// Must be called in-place (after the FakeConn reaches its final address)
    /// because writer/reader buffers point into this struct.
    pub fn init(self: *FakeConn) void {
        self.s2c_head = .init(0);
        self.s2c_tail = .init(0);
        self.c2s_head = .init(0);
        self.c2s_tail = .init(0);
        self.connected = true;

        self.server_writer = .{
            .vtable = &s2c_writer_vtable,
            .buffer = &self.server_write_buf,
            .end = 0,
        };
        self.server_reader = .{
            .vtable = &c2s_reader_vtable,
            .buffer = &self.server_read_buf,
            .seek = 0,
            .end = 0,
        };
        self.client_writer = .{
            .vtable = &c2s_writer_vtable,
            .buffer = &self.client_write_buf,
            .end = 0,
        };
        self.client_reader = .{
            .vtable = &s2c_reader_vtable,
            .buffer = &self.client_read_buf,
            .seek = 0,
            .end = 0,
        };
    }

    fn ring_write(buf: []u8, head: *const std.atomic.Value(u32), tail: *std.atomic.Value(u32), data: []const u8) u32 {
        const h = head.load(.acquire);
        const t = tail.load(.monotonic);
        const space = RingSize - (t -% h);
        const n: u32 = @intCast(@min(data.len, @as(usize, space)));
        for (0..n) |i| buf[(t +% @as(u32, @intCast(i))) & RingMask] = data[i];
        if (n > 0) tail.store(t +% n, .release);
        return n;
    }

    fn ring_read(buf: []const u8, head: *std.atomic.Value(u32), tail: *const std.atomic.Value(u32), dest: []u8) u32 {
        const t = tail.load(.acquire);
        const h = head.load(.monotonic);
        const available = t -% h;
        const n: u32 = @intCast(@min(dest.len, @as(usize, available)));
        for (0..n) |i| dest[i] = buf[(h +% @as(u32, @intCast(i))) & RingMask];
        if (n > 0) head.store(h +% n, .release);
        return n;
    }

    fn ring_drain(
        w: *std.Io.Writer,
        data: []const []const u8,
        buf: []u8,
        head: *const std.atomic.Value(u32),
        tail: *std.atomic.Value(u32),
    ) std.Io.Writer.Error!usize {
        const buffered = w.end;
        if (buffered > 0) assert(ring_write(buf, head, tail, w.buffer[0..buffered]) == buffered);

        var written: usize = 0;
        for (data) |slice| {
            if (slice.len == 0) continue;
            assert(ring_write(buf, head, tail, slice) == slice.len);
            written += slice.len;
        }
        return w.consume(buffered + written);
    }

    fn ring_stream(
        r: *std.Io.Reader,
        limit: std.Io.Limit,
        buf: []const u8,
        head: *std.atomic.Value(u32),
        tail: *const std.atomic.Value(u32),
    ) std.Io.Reader.StreamError!usize {
        const n = ring_read(buf, head, tail, limit.slice(r.buffer[r.end..]));
        if (n == 0) return error.ReadFailed;
        r.end += n;
        return 0;
    }

    const s2c_writer_vtable: std.Io.Writer.VTable = .{ .drain = s2c_drain };

    // Ring must never fill: in singleplayer, producer and consumer are
    // synchronized (same thread or tick-drained), so 4 KiB is always enough.
    // If this assert fires, RingSize needs to grow.
    fn s2c_drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        _ = splat;
        const self: *FakeConn = @alignCast(@fieldParentPtr("server_writer", w));
        return ring_drain(w, data, &self.s2c, &self.s2c_head, &self.s2c_tail);
    }

    const s2c_reader_vtable: std.Io.Reader.VTable = .{ .stream = s2c_stream };

    fn s2c_stream(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        _ = w;
        const self: *FakeConn = @alignCast(@fieldParentPtr("client_reader", r));
        return ring_stream(r, limit, &self.s2c, &self.s2c_head, &self.s2c_tail);
    }

    const c2s_writer_vtable: std.Io.Writer.VTable = .{ .drain = c2s_drain };

    fn c2s_drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        _ = splat;
        const self: *FakeConn = @alignCast(@fieldParentPtr("client_writer", w));
        return ring_drain(w, data, &self.c2s, &self.c2s_head, &self.c2s_tail);
    }

    const c2s_reader_vtable: std.Io.Reader.VTable = .{ .stream = c2s_stream };

    fn c2s_stream(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        _ = w;
        const self: *FakeConn = @alignCast(@fieldParentPtr("server_reader", r));
        return ring_stream(r, limit, &self.c2s, &self.c2s_head, &self.c2s_tail);
    }
};
