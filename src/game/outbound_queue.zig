// --- Per-client bounded outbound queue ---
//
// Producers (tick-thread broadcasts, other clients' read threads, the
// compress worker) serialize packets here instead of touching the socket.
// The client's own connection thread is the only socket writer; it drains
// the queue between inbound reads. A peer that stops reading fills its
// queue and is kicked, never waited on.

const std = @import("std");

/// Backlog tolerated before a slow client is kicked. Minutes of headroom
/// for a healthy client at hundreds of B/s of position traffic; world-send
/// streams through concurrently.
pub const out_queue_bytes = 256 * 1024;

pub const Error = error{QueueFull};

pub const OutboundQueue = struct {
    mutex: std.Io.Mutex = .init,
    /// Allocated per active connection; empty until admitted.
    buf: []u8 = &.{},
    len: usize = 0,
    /// Sticky once an append overflowed: the client is being kicked and no
    /// further bytes are accepted.
    kicked: bool = false,

    pub fn append(q: *OutboundQueue, io: std.Io, bytes: []const u8) Error!void {
        q.mutex.lockUncancelable(io);
        defer q.mutex.unlock(io);

        if (q.kicked) return error.QueueFull;
        if (q.len + bytes.len > q.buf.len) {
            q.kicked = true;
            return error.QueueFull;
        }
        @memcpy(q.buf[q.len..][0..bytes.len], bytes);
        q.len += bytes.len;
    }

    /// Move up to `dest.len` queued bytes out, compacting the remainder.
    /// The mutex is never held across the caller's socket write.
    pub fn take(q: *OutboundQueue, io: std.Io, dest: []u8) usize {
        q.mutex.lockUncancelable(io);
        defer q.mutex.unlock(io);

        const n = @min(q.len, dest.len);
        @memcpy(dest[0..n], q.buf[0..n]);
        const remaining = q.len - n;
        std.mem.copyForwards(u8, q.buf[0..remaining], q.buf[n..q.len]);
        q.len = remaining;
        return n;
    }
};

test "outbound_queue append then take returns bytes in order" {
    const io = std.testing.io;
    var storage: [16]u8 = undefined;
    var q: OutboundQueue = .{ .buf = &storage };

    try q.append(io, "hello");
    try q.append(io, " world");

    var dest: [16]u8 = undefined;
    const n = q.take(io, &dest);
    try std.testing.expectEqual(@as(usize, 11), n);
    try std.testing.expectEqualStrings("hello world", dest[0..n]);
    try std.testing.expectEqual(@as(usize, 0), q.take(io, &dest));
}

test "outbound_queue take with small dest compacts the remainder" {
    const io = std.testing.io;
    var storage: [16]u8 = undefined;
    var q: OutboundQueue = .{ .buf = &storage };

    try q.append(io, "abcdef");

    var dest: [4]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 4), q.take(io, &dest));
    try std.testing.expectEqualStrings("abcd", &dest);
    try std.testing.expectEqual(@as(usize, 2), q.len);

    // Remainder stays appendable and ordered after compaction.
    try q.append(io, "XY");
    var dest2: [8]u8 = undefined;
    const n = q.take(io, &dest2);
    try std.testing.expectEqualStrings("efXY", dest2[0..n]);
}

test "outbound_queue overflow sets the kick flag and rejects further appends" {
    const io = std.testing.io;
    var storage: [8]u8 = undefined;
    var q: OutboundQueue = .{ .buf = &storage };

    try q.append(io, "12345678");
    try std.testing.expectError(error.QueueFull, q.append(io, "x"));
    try std.testing.expect(q.kicked);

    // Sticky: even after draining there is room, appends keep failing.
    var dest: [8]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 8), q.take(io, &dest));
    try std.testing.expectError(error.QueueFull, q.append(io, "y"));
}

test "outbound_queue exact-fit append succeeds" {
    const io = std.testing.io;
    var storage: [4]u8 = undefined;
    var q: OutboundQueue = .{ .buf = &storage };

    try q.append(io, "ab");
    try q.append(io, "cd");
    try std.testing.expect(!q.kicked);
    try std.testing.expectEqual(@as(usize, 4), q.len);
}
