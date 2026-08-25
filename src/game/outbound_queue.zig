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
    /// During a level transfer, block-change packets grow backwards from the
    /// end of `buf`. This keeps them ordered after LevelFinalize without a
    /// second allocation or allowing the compressor and gameplay threads to
    /// interleave packets on the wire.
    catchup_len: usize = 0,
    /// Sticky once an append overflowed: the client is being kicked and no
    /// further bytes are accepted.
    kicked: bool = false,

    pub fn append(q: *OutboundQueue, io: std.Io, bytes: []const u8) Error!void {
        q.mutex.lockUncancelable(io);
        defer q.mutex.unlock(io);

        if (q.kicked) return error.QueueFull;
        if (q.len + q.catchup_len + bytes.len > q.buf.len) {
            q.kicked = true;
            return error.QueueFull;
        }
        @memcpy(q.buf[q.len..][0..bytes.len], bytes);
        q.len += bytes.len;
    }

    /// Append one already-serialized SetBlockToClient packet to the temporary
    /// join journal. Protocol block-change packets are always eight bytes, so
    /// the reverse-growing records can later be reversed without metadata.
    pub fn appendCatchup(q: *OutboundQueue, io: std.Io, packet: *const [8]u8) Error!void {
        q.mutex.lockUncancelable(io);
        defer q.mutex.unlock(io);

        if (q.kicked) return error.QueueFull;
        if (q.len + q.catchup_len + packet.len > q.buf.len) {
            q.kicked = true;
            return error.QueueFull;
        }
        q.catchup_len += packet.len;
        const start = q.buf.len - q.catchup_len;
        @memcpy(q.buf[start..][0..packet.len], packet);
    }

    /// Move the reverse-growing join journal behind normal outbound bytes.
    /// The caller performs the world catch-up state transition while holding
    /// the world lock, so no new catch-up record can race this promotion.
    pub fn promoteCatchup(q: *OutboundQueue, io: std.Io) void {
        q.mutex.lockUncancelable(io);
        defer q.mutex.unlock(io);

        const packet_len = 8;
        const count = q.catchup_len / packet_len;
        const start = q.buf.len - q.catchup_len;

        // Records were pushed from the end toward the front. Reverse them in
        // place first, then the overlap-safe forward copy preserves chronology.
        for (0..count / 2) |i| {
            const left = start + i * packet_len;
            const right = start + (count - 1 - i) * packet_len;
            var tmp: [packet_len]u8 = undefined;
            @memcpy(&tmp, q.buf[left..][0..packet_len]);
            @memcpy(q.buf[left..][0..packet_len], q.buf[right..][0..packet_len]);
            @memcpy(q.buf[right..][0..packet_len], &tmp);
        }
        std.mem.copyForwards(u8, q.buf[q.len..][0..q.catchup_len], q.buf[start..][0..q.catchup_len]);
        q.len += q.catchup_len;
        q.catchup_len = 0;
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

test "outbound_queue promotes join catch-up after normal bytes in order" {
    const io = std.testing.io;
    var storage: [32]u8 = undefined;
    var q: OutboundQueue = .{ .buf = &storage };
    const first: [8]u8 = "first---".*;
    const second: [8]u8 = "second--".*;

    try q.append(io, "level");
    try q.appendCatchup(io, &first);
    try q.appendCatchup(io, &second);
    q.promoteCatchup(io);

    var dest: [32]u8 = undefined;
    const n = q.take(io, &dest);
    try std.testing.expectEqualStrings("levelfirst---second--", dest[0..n]);
}

test "outbound_queue shares capacity between normal and catch-up bytes" {
    const io = std.testing.io;
    var storage: [16]u8 = undefined;
    var q: OutboundQueue = .{ .buf = &storage };
    const change: [8]u8 = @splat(0xaa);

    try q.append(io, "12345678");
    try q.appendCatchup(io, &change);
    try std.testing.expectError(error.QueueFull, q.append(io, "x"));
}
