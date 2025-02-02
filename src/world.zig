const std = @import("std");
const c = @import("constants.zig");
const fp = @import("fixedpoint.zig");
const perlin = @import("perlin.zig");

const assert = std.debug.assert;

const Self = @This();

backing_allocator: std.mem.Allocator,
raw_blocks: []u8,
blocks: []u8,
world_size: [3]u16,

pub fn init(allocator: std.mem.Allocator) !Self {
    var world: Self = .{
        .backing_allocator = allocator,
        .raw_blocks = try allocator.alloc(u8, c.WorldDepth * c.WorldHeight * c.WorldLength + 4),
        .blocks = undefined,
        .world_size = .{ c.WorldLength, c.WorldHeight, c.WorldDepth },
    };

    @memset(world.raw_blocks, 0x00);

    const size: u32 = c.WorldDepth * c.WorldHeight * c.WorldLength;
    std.mem.writeInt(u32, world.raw_blocks[0..4], size, .big);
    const FInt = fp.Fixed(32, 24, true);

    world.blocks = world.raw_blocks[4..];

    for (0..c.WorldLength) |x| {
        for (0..c.WorldDepth) |z| {
            var noise = perlin.noise3(.{ .value = @intCast(x << 19) }, .{ .value = @intCast(z << 19) }, FInt.from(0));
            noise = noise.add(.{ .value = 0xFFFFFF });

            for (0..@as(usize, @intCast(noise.value >> 19))) |h| {
                world.set_block(@intCast(x), @intCast(h), @intCast(z), 1);
            }
        }
    }

    return world;
}

pub fn get_block(self: *Self, x: u16, y: u16, z: u16) u8 {
    assert(x >= 0 and x < c.WorldLength);
    assert(y >= 0 and y < c.WorldHeight);
    assert(z >= 0 and z < c.WorldDepth);
    return self.blocks[(y * c.WorldLength * c.WorldDepth) + (z * c.WorldLength) + x];
}

pub fn set_block(self: *Self, x: u16, y: u16, z: u16, block: u8) void {
    assert(x >= 0 and x < c.WorldLength);
    assert(y >= 0 and y < c.WorldHeight);
    assert(z >= 0 and z < c.WorldDepth);
    self.blocks[(y * c.WorldLength * c.WorldDepth) + (z * c.WorldLength) + x] = block;
}

pub fn deinit(self: *Self) void {
    self.backing_allocator.free(self.raw_blocks);
    self.* = undefined;
}
