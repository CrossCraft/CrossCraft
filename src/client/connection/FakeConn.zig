const std = @import("std");
const assert = std.debug.assert;

// SPSC ring buffer size - large enough for all non-world handshake packets
// plus ongoing gameplay traffic (block changes, positions, pings) per tick.
const RING_SIZE: u32 = 4096;
const RING_MASK: u32 = RING_SIZE - 1;

comptime {
    assert(std.math.isPowerOfTwo(RING_SIZE));
}

pub const FakeConn = struct {
    // S→C: server writes (producer), client reads (consumer)
    s2c: [RING_SIZE]u8 = undefined,
    s2c_head: std.atomic.Value(u32) = .init(0),
    s2c_tail: std.atomic.Value(u32) = .init(0),

    // C→S: client writes (producer), server reads (consumer)
    c2s: [RING_SIZE]u8 = undefined,
    c2s_head: std.atomic.Value(u32) = .init(0),
    c2s_tail: std.atomic.Value(u32) = .init(0),

    connected: bool = true,

    // Internal buffers - writers accumulate here before draining to ring.
    // Largest S→C packet is PlayerID at 131 bytes; 1024 is comfortable.
    server_write_buf: [1024]u8 = undefined,
    // Largest C→S packet is PlayerIDToServer at 131 bytes.
    client_write_buf: [256]u8 = undefined,

    // Reader scratch buffers for peek/fill.
    server_read_buf: [256]u8 = undefined,
    client_read_buf: [256]u8 = undefined,

    // Server-facing interfaces - passed to local_join.
    server_writer: std.Io.Writer = undefined, // server writes S→C here
    server_reader: std.Io.Reader = undefined, // server reads C→S here (unused for local)

    // Client-facing interfaces - GameState uses these.
    client_writer: std.Io.Writer = undefined, // client writes C→S here
    client_reader: std.Io.Reader = undefined, // client reads S→C here

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

    // -- Ring helpers --------------------------------------------------------

    fn ring_write(buf: []u8, head: *const std.atomic.Value(u32), tail: *std.atomic.Value(u32), data: []const u8) u32 {
        const h = head.load(.acquire);
        const t = tail.load(.monotonic);
        const space = RING_SIZE - (t -% h);
        const n: u32 = @intCast(@min(data.len, @as(usize, space)));
        for (0..n) |i| buf[(t +% @as(u32, @intCast(i))) & RING_MASK] = data[i];
        if (n > 0) tail.store(t +% n, .release);
        return n;
    }

    fn ring_read(buf: []const u8, head: *std.atomic.Value(u32), tail: *const std.atomic.Value(u32), dest: []u8) u32 {
        const t = tail.load(.acquire);
        const h = head.load(.monotonic);
        const available = t -% h;
        const n: u32 = @intCast(@min(dest.len, @as(usize, available)));
        for (0..n) |i| dest[i] = buf[(h +% @as(u32, @intCast(i))) & RING_MASK];
        if (n > 0) head.store(h +% n, .release);
        return n;
    }

    // -- S→C writer (server_writer → s2c ring) ------------------------------

    const s2c_writer_vtable: std.Io.Writer.VTable = .{ .drain = s2c_drain };

    fn s2c_drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        _ = splat;
        const self: *FakeConn = @alignCast(@fieldParentPtr("server_writer", w));
        const buf_end = w.end;
        if (buf_end > 0) {
            const n = ring_write(&self.s2c, &self.s2c_head, &self.s2c_tail, w.buffer[0..buf_end]);
            assert(n == buf_end);
        }
        var data_written: usize = 0;
        for (data) |slice| {
            if (slice.len == 0) continue;
            const n = ring_write(&self.s2c, &self.s2c_head, &self.s2c_tail, slice);
            assert(n == slice.len);
            data_written += slice.len;
        }
        return w.consume(buf_end + data_written);
    }

    // -- S→C reader (s2c ring → client_reader) ------------------------------

    const s2c_reader_vtable: std.Io.Reader.VTable = .{ .stream = s2c_stream };

    fn s2c_stream(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        _ = w;
        const self: *FakeConn = @alignCast(@fieldParentPtr("client_reader", r));
        const n = ring_read(&self.s2c, &self.s2c_head, &self.s2c_tail, limit.slice(r.buffer[r.end..]));
        if (n == 0) return error.ReadFailed; // ring empty - caller treats as no data
        r.end += n;
        return 0; // data stored in r.buffer; caller serves it from there
    }

    // -- C→S writer (client_writer → c2s ring) ------------------------------

    const c2s_writer_vtable: std.Io.Writer.VTable = .{ .drain = c2s_drain };

    fn c2s_drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        _ = splat;
        const self: *FakeConn = @alignCast(@fieldParentPtr("client_writer", w));
        const buf_end = w.end;
        if (buf_end > 0) {
            const n = ring_write(&self.c2s, &self.c2s_head, &self.c2s_tail, w.buffer[0..buf_end]);
            assert(n == buf_end);
        }
        var data_written: usize = 0;
        for (data) |slice| {
            if (slice.len == 0) continue;
            const n = ring_write(&self.c2s, &self.c2s_head, &self.c2s_tail, slice);
            assert(n == slice.len);
            data_written += slice.len;
        }
        return w.consume(buf_end + data_written);
    }

    // -- C→S reader (c2s ring → server_reader) ------------------------------

    const c2s_reader_vtable: std.Io.Reader.VTable = .{ .stream = c2s_stream };

    fn c2s_stream(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        _ = w;
        const self: *FakeConn = @alignCast(@fieldParentPtr("server_reader", r));
        const n = ring_read(&self.c2s, &self.c2s_head, &self.c2s_tail, limit.slice(r.buffer[r.end..]));
        if (n == 0) return error.ReadFailed;
        r.end += n;
        return 0;
    }
};
