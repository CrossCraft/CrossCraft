const std = @import("std");
const testing = std.testing;

/// Circular, opportunistic insertion into a fixed-size sparse table.
/// Index 0 is permanently reserved as a null handle.
pub fn CircularBuffer(comptime T: type, comptime SIZE: usize) type {
    comptime {
        if (SIZE < 2)
            @compileError("SIZE must be >= 2 (index 0 is reserved as the null handle).");
    }

    return struct {
        const Self = @This();

        // Storage: slot 0 is always null; slots [1..SIZE-1] may hold values.
        buffer: [SIZE]?T = undefined,
        head: usize = 1, // next probe start; always in [1..SIZE-1]
        count: usize = 0, // number of occupied non-zero slots

        pub fn init() Self {
            return .{
                .buffer = @splat(null), // ensure slot 0 is null
                .head = 1,
                .count = 0,
            };
        }

        pub fn clear(self: *Self) void {
            // Ensure slot 0 is always null.
            self.buffer = @splat(null);
            self.head = 1;
            self.count = 0;
        }

        pub fn len(self: *const Self) usize {
            return self.count;
        }

        pub fn capacity(self: *const Self) usize {
            _ = self;
            return SIZE - 1; // slot 0 is reserved
        }

        pub fn is_full(self: *const Self) bool {
            return self.count == self.capacity();
        }

        inline fn next_index(i: usize) usize {
            var n = (i + 1) % SIZE;
            if (n == 0) n = 1; // skip reserved 0
            return n;
        }

        /// Inserts value into the first empty slot encountered by circular probing.
        /// Returns the assigned handle (index in [1..SIZE-1]) or null if full.
        pub fn add_element(self: *Self, value: T) ?usize {
            if (self.is_full()) return null;

            var idx = self.head;
            // Probe at most capacity() times.
            for (0..self.capacity()) |_| {
                if (self.buffer[idx] == null) {
                    self.buffer[idx] = value;
                    self.count += 1;
                    self.head = next_index(idx);
                    return idx; // handle
                }
                idx = next_index(idx);
            } else {
                // Shouldn’t be reachable because we checked isFull(), but be safe.
                return null;
            }
        }

        pub fn update_element(self: *Self, index: usize, value: T) void {
            if (index == 0 or index >= SIZE) return;

            if (self.buffer[index]) |*v| {
                v.* = value;
            }
        }

        /// Removes the element at `index` (handle). Returns true if something was removed.
        pub fn remove_element(self: *Self, index: usize) bool {
            if (index == 0 or index >= SIZE) return false;
            if (self.buffer[index] != null) {
                self.buffer[index] = null;
                if (self.count > 0) self.count -= 1;
                // Prefer to restart probing near the earliest gap.
                if (index < self.head) self.head = index;
                return true;
            }
            return false;
        }

        pub fn get_element(self: *const Self, index: usize) ?T {
            if (index == 0 or index >= SIZE) return null;
            return self.buffer[index];
        }
    };
}

test "init/clear/capacity basics" {
    const Buf = CircularBuffer(u32, 5);
    var b = Buf.init();

    try testing.expectEqual(@as(usize, 0), b.len());
    try testing.expect(!b.is_full());
    try testing.expectEqual(@as(usize, 4), b.capacity());

    // slot 0 is always null; out-of-bounds yields null
    try testing.expect(b.get_element(0) == null);
    try testing.expect(b.get_element(5) == null);

    // all usable slots start empty
    for (1..5) |i| try testing.expect(b.get_element(i) == null);

    // clear() keeps invariants
    b.clear();
    try testing.expectEqual(@as(usize, 0), b.len());
    try testing.expect(b.get_element(0) == null);
    for (1..5) |i| try testing.expect(b.get_element(i) == null);
}

test "sequential inserts skip 0 and return handles" {
    const Buf = CircularBuffer(u32, 5);
    var b = Buf.init();

    const h1 = b.add_element(10) orelse return error.TestExpectedNonNull;
    const h2 = b.add_element(20) orelse return error.TestExpectedNonNull;
    try testing.expectEqual(@as(usize, 1), h1);
    try testing.expectEqual(@as(usize, 2), h2);

    try testing.expectEqual(@as(?u32, 10), b.get_element(h1));
    try testing.expectEqual(@as(?u32, 20), b.get_element(h2));

    try testing.expectEqual(@as(usize, 2), b.len());
}

test "fills to capacity then rejects, remove reuses hole by circular probe" {
    const Buf = CircularBuffer(u32, 5); // capacity = 4 (slots 1..4)
    var b = Buf.init();

    const h1 = b.add_element(1) orelse return error.TestExpectedNonNull; // 1
    const h2 = b.add_element(2) orelse return error.TestExpectedNonNull; // 2
    const h3 = b.add_element(3) orelse return error.TestExpectedNonNull; // 3
    const h4 = b.add_element(4) orelse return error.TestExpectedNonNull; // 4
    try testing.expectEqualSlices(usize, &.{ 1, 2, 3, 4 }, &.{ h1, h2, h3, h4 });

    try testing.expect(b.is_full());
    try testing.expect(b.add_element(99) == null); // full

    // Remove a middle slot; next add should find that hole (by probing from head).
    try testing.expect(b.remove_element(h2));
    try testing.expectEqual(@as(usize, 3), b.len());
    try testing.expect(b.get_element(h2) == null);

    const h5 = b.add_element(5) orelse return error.TestExpectedNonNull;
    try testing.expectEqual(h2, h5); // reuses the earliest encountered hole
    try testing.expectEqual(@as(?u32, 5), b.get_element(h5));
    try testing.expect(b.is_full());
}

test "remove edge cases and bounds" {
    const Buf = CircularBuffer(u32, 4);
    var b = Buf.init();

    try testing.expect(!b.remove_element(0)); // reserved
    try testing.expect(!b.remove_element(99)); // OOB
    try testing.expect(!b.remove_element(3)); // empty slot

    const h = b.add_element(7) orelse return error.TestExpectedNonNull;
    try testing.expect(b.remove_element(h)); // remove present
    try testing.expect(!b.remove_element(h)); // removing again yields false
    try testing.expectEqual(@as(usize, 0), b.len());
}

test "minimum valid size (SIZE=2) works: one usable slot at index 1" {
    const Buf = CircularBuffer(u32, 2); // capacity 1
    var b = Buf.init();

    const h1 = b.add_element(111) orelse return error.TestExpectedNonNull;
    try testing.expectEqual(@as(usize, 1), h1);
    try testing.expect(b.is_full());
    try testing.expect(b.add_element(222) == null);

    try testing.expect(b.remove_element(1));
    try testing.expect(!b.is_full());
    const h2 = b.add_element(222) orelse return error.TestExpectedNonNull;
    try testing.expectEqual(@as(usize, 1), h2); // only slot re-used
    try testing.expectEqual(@as(?u32, 222), b.get_element(1));
}
