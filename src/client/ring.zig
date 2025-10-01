const std = @import("std");
const assert = std.debug.assert;

pub fn RingBuffer(comptime Size: usize) type {
    return struct {
        const Self = @This();

        pub fn init() Self {
            var self: Self = undefined;
            self.read_index = 0;
            self.write_index = 0;

            self.ring_reader = .{
                .vtable = &.{
                    .stream = streamImpl,
                },
                .buffer = undefined,
                .end = 0,
                .seek = 0,
            };

            self.ring_writer = .{
                .vtable = &.{
                    .drain = drainImpl,
                    .flush = noopFlush,
                },
                .buffer = undefined,
            };

            return self;
        }

        pub fn reader(self: *Self, buffer: []u8) *std.io.Reader {
            self.ring_reader.buffer = buffer;
            return &self.ring_reader;
        }
        pub fn writer(self: *Self, buffer: []u8) *std.io.Writer {
            self.ring_writer.buffer = buffer;
            return &self.ring_writer;
        }

        pub fn clear(self: *Self) void {
            self.read_index = 0;
            self.write_index = 0;
        }

        pub fn len(self: *const Self) usize {
            return self.readable();
        }

        pub fn capacity(_: *const Self) usize {
            return Size - 1;
        }

        buffer: [Size]u8 = undefined,
        read_index: usize = 0,
        write_index: usize = 0,

        ring_reader: std.io.Reader,
        ring_writer: std.io.Writer,

        fn readable(self: *const Self) usize {
            if (self.write_index >= self.read_index)
                return self.write_index - self.read_index;
            return Size - (self.read_index - self.write_index);
        }

        fn writable(self: *const Self) usize {
            return (Size - 1) - self.readable();
        }

        fn writeSome(self: *Self, src: []const u8) usize {
            const to_write = @min(src.len, self.writable());
            if (to_write == 0) return 0;

            const first_span = @min(to_write, Size - self.write_index);
            @memcpy(self.buffer[self.write_index .. self.write_index + first_span], src[0..first_span]);
            self.write_index = (self.write_index + first_span) % Size;

            const remain = to_write - first_span;
            if (remain != 0) {
                @memcpy(self.buffer[self.write_index .. self.write_index + remain], src[first_span .. first_span + remain]);
                self.write_index = (self.write_index + remain) % Size;
            }
            return to_write;
        }

        fn readSome(self: *Self, dst: []u8) usize {
            const to_read = @min(dst.len, self.readable());
            if (to_read == 0) return 0;

            const first_span = @min(to_read, Size - self.read_index);
            @memcpy(dst[0..first_span], self.buffer[self.read_index .. self.read_index + first_span]);
            self.read_index = (self.read_index + first_span) % Size;

            const remain = to_read - first_span;
            if (remain != 0) {
                @memcpy(dst[first_span .. first_span + remain], self.buffer[self.read_index .. self.read_index + remain]);
                self.read_index = (self.read_index + remain) % Size;
            }
            return to_read;
        }

        fn streamImpl(r: *std.io.Reader, w: *std.io.Writer, limit: std.io.Limit) std.io.Reader.StreamError!usize {
            const self: *Self = @fieldParentPtr("ring_reader", r);

            var total: usize = 0;
            var remaining: usize = limit.toInt() orelse 0; // Limit → usize
            if (remaining == 0) return 0;

            // Fast-path: write from ring to writer using a stack scratch,
            // repeating until we hit limit or ring empties, allowing short reads.
            var scratch: [1024]u8 = undefined;

            while (remaining != 0) {
                const chunk_cap = @min(scratch.len, remaining);
                const n = self.readSome(scratch[0..chunk_cap]);
                if (n == 0) return error.ReadFailed; // nothing available right now
                const wrote = try w.write(scratch[0..n]); // may short-write
                // If destination short-writes, stop here (let caller pull again).
                if (wrote == 0) return error.WriteFailed;
                // If writer wrote fewer than we pulled, put back the remainder.
                if (wrote < n) {
                    // roll back unread portion into the ring's read_index
                    // To "put back", just move read_index backwards by (n - wrote).
                    const give_back = n - wrote;
                    self.read_index = (self.read_index + Size - give_back) % Size;
                }
                total += wrote;
                remaining -= wrote;
                if (wrote < n) return error.ReadFailed; // don't loop-spin; let caller retry
            }

            return total;
        }

        pub fn discardImpl(r: *std.io.Reader, limit: std.io.Limit) std.io.Reader.Error!usize {
            const self: *Self = @fieldParentPtr("ring_reader", r);
            const want = limit.get();
            const can = @min(want, self.readable());
            const first_span = @min(can, Size - self.read_index);
            self.read_index = (self.read_index + first_span) % Size;
            const remain = can - first_span;
            if (remain != 0)
                self.read_index = (self.read_index + remain) % Size;
            return can;
        }

        fn drainImpl(w: *std.io.Writer, data: []const []const u8, splat: usize) std.io.Writer.Error!usize {
            if (data.len == 0) return 0;

            const self: *Self = @fieldParentPtr("ring_writer", w);
            var consumed: usize = 0;

            if (data.len > 1) {
                for (data[0 .. data.len - 1]) |part| {
                    if (part.len == 0) continue;
                    const wrote = self.writeSome(part);
                    consumed += wrote;
                    if (wrote < part.len) {
                        return error.WriteFailed;
                    }
                }
            }

            const pattern = data[data.len - 1];
            switch (pattern.len) {
                0 => return consumed, // nothing to splat
                1 => {
                    var i: usize = 0;
                    while (i < splat) : (i += 1) {
                        const space = self.writable();
                        if (space == 0) return error.WriteFailed;
                        var tmp: [512]u8 = undefined;
                        const fill = @min(space, tmp.len);
                        @memset(tmp[0..fill], pattern[0]);
                        const wrote = self.writeSome(tmp[0..fill]);
                        consumed += wrote; // "bytes from data" notionally equals what we logically wrote
                        if (wrote < fill) return error.WriteFailed;
                    }
                    return consumed;
                },
                else => {
                    var i: usize = 0;
                    while (i < splat) : (i += 1) {
                        const wrote = self.writeSome(pattern);
                        consumed += wrote;
                        if (wrote < pattern.len) return error.WriteFailed;
                    }
                    return consumed;
                },
            }
        }

        fn noopFlush(_: *std.io.Writer) std.io.Writer.Error!void {}
    };
}
