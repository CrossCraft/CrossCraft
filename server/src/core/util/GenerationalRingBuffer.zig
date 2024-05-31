const std = @import("std");
const assert = std.debug.assert;

// TODO: This ringbuffer implementation is not required for the current implementation of the
// `EventQueue` but it is a useful data structure to have in the future. It is currently not used
// and is not tested.
pub fn GenerationalRingBuffer(comptime T: type) type {
    return struct {
        /// An item in the ring buffer.
        pub const Item = struct {
            data: T,
            generation: u32,
            occupied: bool,
        };

        pub const Index = struct {
            index: u32,
            generation: u32,
        };

        backing_allocator: std.mem.Allocator,
        data: std.MultiArrayList(Item),
        capacity: u32,
        current_generation: u32,
        current_index: u32,

        const Self = @This();

        /// Create a new ring buffer with the given capacity.
        pub fn init(allocator: std.mem.Allocator, capacity: u32) Self {
            assert(capacity > 0);

            var data = std.MultiArrayList(Item){};
            data.setCapacity(allocator, capacity) catch @panic("Failed to allocate memory for GenerationalRingBuffer");

            for (data.slice()) |item| {
                item.occupied = false;
                item.generation = 0;
            }

            return Self{
                .backing_allocator = allocator,
                .capacity = capacity,
                .data = data,
            };
        }

        /// Deinitialize the ring buffer.
        pub fn deinit(self: *Self) void {
            self.data.deinit(self.backing_allocator);
        }

        /// Check if the ring buffer is full.
        fn is_full(self: *const Self) bool {
            return for (self.data.items(.occupied)) |occupied| {
                if (!occupied)
                    break false;
            } else true;
        }

        /// Get the next available index in the ring buffer.
        fn next_available_index(self: *Self) ?u32 {
            var total_visited: u64 = 0;
            var current_index = self.current_index;
            const occupied = self.data.items(.occupied);

            while (occupied[@intCast(current_index)]) {
                current_index = (current_index + 1) % self.capacity;
                total_visited += 1;
                if (total_visited >= self.capacity) {
                    return null;
                }
            }

            return current_index;
        }

        /// Add an item to the ring buffer.
        /// Returns whether the item was added successfully and the index it was added to.
        pub fn add_item(self: *Self, item: *const T) ?Index {
            if (self.next_available_index()) |index| {
                // If the current index is 0, increment the generation.
                self.current_generation += 1;

                // Set the item in the ring buffer.
                self.data.set(index, .{
                    .data = item.*,
                    .generation = self.current_generation,
                    .occupied = true,
                });

                // Return the current index.
                return .{
                    .index = index,
                    .generation = self.current_generation,
                };
            }

            return null;
        }

        /// Get an item from the ring buffer.
        /// `index` is the index of the item to get.
        /// Returns the item if it exists, otherwise null.
        pub fn get_item(self: *Self, index: Index) ?T {
            const item = self.data.get(index.index);
            if (item.occupied and item.generation == index.generation) {
                return item.data;
            }

            return null;
        }

        /// Remove an item from the ring buffer.
        /// `index` is the index of the item to remove.
        pub fn remove_item(self: *Self, index: Index) void {
            const item = self.data.get(index.index);
            if (item.occupied and item.generation == index.generation) {
                self.data.set(index.index, .{
                    .data = undefined,
                    .generation = 0,
                    .occupied = false,
                });
            }
        }
    };
}
