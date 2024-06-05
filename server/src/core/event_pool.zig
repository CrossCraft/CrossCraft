const std = @import("std");
const assert = std.debug.assert;

const Event = @import("event.zig").Event;
const ReferenceCounted = @import("reference_count.zig").ReferenceCounted;

/// Event pool
/// This is a pool of events that can be used to create reference counted events
/// The pool is fixed size and will return an error if it runs out of space
/// When an event is dropped, it is returned to the pool
/// This is useful for creating events that are shared between multiple systems
/// and need to be cleaned up when no longer in use without manual memory management
/// This is ideal for one to many relationships where an event is consumed by multiple
/// systems and needs to be cleaned up when no longer in use.
pub const EventPool = struct {
    backing_allocator: std.mem.Allocator,
    backing_list: []Event,
    capacity: u32,
    free_list: std.ArrayList(u32),

    /// Context for the drop callback
    /// This includes the index of the event in the backing list
    /// and a reference to the pool itself
    pub const Context = struct {
        pool: *EventPool,
        index: u32,
    };

    /// Reference counted event type
    pub const RefCountEvent = ReferenceCounted(Event, Context, drop_callback);

    /// Initialize the event pool
    /// This will allocate the backing list and the free list
    /// The free list will be initialized with all indices in the backing list
    pub fn init(allocator: std.mem.Allocator, capacity: u32) EventPool {
        var res = EventPool{
            .backing_allocator = allocator,
            .backing_list = allocator.alloc(Event, capacity) catch unreachable,
            .capacity = capacity,
            .free_list = std.ArrayList(u32).initCapacity(allocator, capacity) catch unreachable,
        };

        defer assert(res.free_list.items.len == capacity);

        for (0..capacity) |i| {
            res.free_list.appendAssumeCapacity(@intCast(i));
        }

        return res;
    }

    /// Create a new event from the pool
    /// This will return an error if the pool is full
    pub fn create_event(self: *EventPool, data: *const Event) !RefCountEvent {
        assert(self.capacity == self.backing_list.len);

        if (self.free_list.items.len == 0) {
            return error.OutOfMemory;
        }

        const index = self.free_list.pop();
        assert(index < self.capacity);

        self.backing_list[index] = *data;
        return RefCountEvent.init(
            &self.backing_list[index],
            .{ .pool = self, .index = index },
        );
    }

    /// Drop callback for the reference counted event
    /// This will return the event to the pool
    fn drop_callback(context: Context, data: *Event) void {
        data.* = undefined;
        assert(context.pool.free_list.items.len < context.pool.capacity);
        assert(context.index < context.pool.capacity);
        context.pool.free_list.appendAssumeCapacity(context.index);
    }

    /// Deinitialize the event pool
    pub fn deinit(self: *EventPool) void {
        self.backing_allocator.free(self.backing_list);
        self.free_list.deinit();
        self.* = undefined;
    }
};

// TODO: Unit Testing
