const std = @import("std");
const assert = std.debug.assert;

const Event = @import("event.zig").Event;
const EventPool = @import("event_pool.zig").EventPool;
const RefCountEvent = EventPool.RefCountEvent;
const RingBuffer = @import("ringbuffer.zig").RingBuffer;

const MAX_INPUT_EVENTS = 4096;
const MAX_OUTPUT_EVENTS = 8192;

pub const World = struct {
    /// The size of the world in blocks
    /// The size must be a multiple of 16
    /// The size must not be greater than 512
    /// The size must be greater than 0
    pub const WorldSize = struct {
        length: u32,
        height: u32,
        depth: u32,

        /// Check the validity of the WorldSize
        pub fn check_valid(self: WorldSize) void {
            assert(self.length > 0 and self.depth > 0 and self.height > 0);
            assert(self.length <= 512 and self.depth <= 512 and self.height <= 512);
            assert(self.length % 16 == 0 and self.depth % 16 == 0 and self.height % 16 == 0);
        }

        /// Check if the given position is within the bounds of the world
        pub fn in_bounds(self: WorldSize, x: u16, y: u16, z: u16) bool {
            return x < self.length and y < self.height and z < self.depth;
        }
    };

    // World fields
    world_allocator: std.mem.Allocator,
    world_init: bool,
    world_raw_blocks: []u8,
    world_blocks: []u8,
    world_size: WorldSize,
    world_seed: u64,

    // Event fields

    // Input: Events from sources
    world_in_event_queue: RingBuffer(Event),

    // Storage: Pool of events to be output
    world_event_pool: EventPool,

    // Output: Events to be sent to sources
    world_out_event_queue: RingBuffer(RefCountEvent),

    // Output: Pending events to be sent to sources
    // Occurs when the output event queue is full
    world_out_pending_event: ?RefCountEvent,

    /// Get the block at the given position
    /// The position must be within the bounds of the world
    pub fn get_block(self: *World, x: u16, y: u16, z: u16) u8 {
        assert(self.world_init);
        assert(self.world_size.in_bounds(x, y, z));

        const xz_size = self.world_size.length * self.world_size.depth;
        const xz_index = z * self.world_size.length + x;

        const index = y * xz_size + xz_index;
        return self.world_blocks[index];
    }

    /// Set the block at the given position
    /// The position must be within the bounds of the world
    pub fn set_block(self: *World, x: u16, y: u16, z: u16, block: u8) void {
        assert(self.world_init);
        assert(self.world_size.in_bounds(x, y, z));

        const xz_size = self.world_size.length * self.world_size.depth;
        const xz_index = z * self.world_size.length + x;

        const index = y * xz_size + xz_index;
        self.world_blocks[index] = block;
    }

    /// Tick the world
    /// This function is called in 50ms intervals
    /// It updates the world state, and processes events
    pub fn tick(self: *World) void {
        assert(self.world_init);
    }

    /// Initialize the world with the given size and seed
    /// The size must follow the constraints of WorldSize
    /// The seed is used to generate the world deterministically
    pub fn init(self: *World, allocator: std.mem.Allocator, size: WorldSize, seed: u64) void {
        // Preconditions
        size.check_valid();

        // Postconditions
        defer assert(self.world_init);
        defer assert(std.meta.eql(size, self.world_size));
        defer assert(seed == self.world_seed);
        defer assert(self.world_out_pending_event == null);

        // Setup the event system
        self.world_in_event_queue = RingBuffer(Event).init(allocator, MAX_INPUT_EVENTS);
        self.world_event_pool = EventPool.init(allocator, MAX_OUTPUT_EVENTS);
        self.world_out_event_queue = RingBuffer(RefCountEvent).init(allocator, MAX_OUTPUT_EVENTS);
        self.world_out_pending_event = null;

        // Initialize the world
        self.world_size = size;
        self.world_seed = seed;

        // We prepend 4 bytes to hold the evalauated length of the world
        // This is an performance optimization for sending the world over the network
        // We can avoid duplicating the world to compress it
        const block_count = size.length * size.height * size.depth + 4;
        self.world_raw_blocks = allocator.alloc(u8, block_count) catch
            @panic("Failed to allocate memory for the world!");

        self.world_blocks.ptr = self.world_raw_blocks.ptr + 4;
        self.world_blocks.len = block_count - 4;

        self.world_allocator = allocator;
        self.world_init = true;
    }

    /// Deinitialize the world
    /// Deallocates the memory used by the world
    pub fn deinit(self: *World) void {
        assert(self.world_init);
        self.world_out_event_queue.deinit();
        self.world_event_pool.deinit();
        self.world_in_event_queue.deinit();
        self.world_allocator.dealloc(self.world_blocks);
        self.* = undefined;
    }
};
