const std = @import("std");
const assert = std.debug.assert;

pub const World = struct {
    /// The size of the world in blocks
    /// The size must be a multiple of 16
    /// The size must not be greater than 512
    /// The size must be greater than 0
    pub const WorldSize = struct {
        length: u16,
        height: u16,
        depth: u16,

        /// Check the invariants of the WorldSize
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

    world_allocator: std.mem.Allocator = undefined,
    world_init: bool = false,
    world_blocks: []u8 = undefined,
    world_size: WorldSize = undefined,
    world_seed: u64 = std.math.maxInt(u64),

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
        assert(!self.world_init);
        size.check_valid();

        // Postconditions
        defer assert(self.world_init);
        defer assert(std.meta.eql(size, self.world_size));
        defer assert(seed == self.world_seed);

        // Initialize the world
        self.world_size = size;
        self.world_seed = seed;

        const block_count = size.length * size.height * size.depth;
        self.world_blocks = allocator.alloc(u8, block_count) catch
            @panic("Failed to allocate memory for the world!");

        self.world_allocator = allocator;
        self.world_init = true;
    }

    /// Deinitialize the world
    /// Deallocates the memory used by the world
    pub fn deinit(self: *World) void {
        assert(self.world_init);
        self.world_allocator.dealloc(self.world_blocks);
        self.world_init = false;
    }
};
