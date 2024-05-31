const std = @import("std");
const assert = std.debug.assert;

/// The ring buffer is a data structure that uses a single, fixed-size buffer as if it were
/// a connected ring. It is a FIFO data structure that is useful for implementing queues.
/// The ring buffer has a read index and a write index. The read index is the index of the next
/// item to be read from the buffer, and the write index is the index of the next item to be
/// written to the buffer. The buffer is full if the next write index is the same as the read
/// index, and the buffer is empty if the read index is the same as the write index.
pub fn RingBuffer(comptime T: type) type {
    return struct {
        backing_allocator: std.mem.Allocator,
        data: []T,
        capacity: u32,
        read_index: u32,
        write_index: u32,

        const Self = @This();

        /// Initialize the ring buffer.
        pub fn init(allocator: std.mem.Allocator, capacity: u32) Self {
            assert(capacity > 0);
            return Self{
                .backing_allocator = allocator,
                .data = allocator.alloc(T, capacity) catch {
                    @panic("Failed to allocate memory for RingBuffer");
                },
                .capacity = capacity,
                .read_index = 0,
                .write_index = 0,
            };
        }

        /// Push an item onto the ring buffer.
        /// Returns an error if the buffer is full.
        pub fn push(self: *Self, item: T) !void {
            assert(self.capacity != 0);

            // Buffer is full if the next write index is the same as the read index
            if ((self.write_index + 1) % self.capacity == self.read_index) {
                return error.BufferFull;
            }

            self.data[self.write_index] = item;
            self.write_index = (self.write_index + 1) % self.capacity;
            return true;
        }

        /// Pop an item from the ring buffer.
        /// Returns the item if the buffer is not empty, returns an error otherwise.
        pub fn pop(self: *Self) !T {
            assert(self.capacity != 0);

            // Buffer is empty if the read index is the same as the write index
            if (self.read_index == self.write_index) {
                return error.BufferEmpty;
            }

            const item = self.data[self.read_index];
            self.read_index = (self.read_index + 1) % self.capacity;
            return item;
        }

        /// Deinitialize the ring buffer.
        pub fn deinit(self: *Self) void {
            self.backing_allocator.dealloc(self.data);
            self.capacity = 0;
        }
    };
}

// TODO: Testing
