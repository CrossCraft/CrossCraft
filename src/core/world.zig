const std = @import("std");
const c = @import("consts.zig");
const assert = std.debug.assert;

pub var backing_allocator: std.mem.Allocator = undefined;
pub var raw_blocks: []u8 = undefined;
pub var blocks: []u8 = undefined;
pub var world_size: [3]u16 = undefined;

pub fn init(allocator: std.mem.Allocator) !void {
    backing_allocator = allocator;

    raw_blocks = try allocator.alloc(u8, c.WorldDepth * c.WorldHeight * c.WorldLength + 4);
    blocks = raw_blocks[4..];

    world_size = .{ c.WorldLength, c.WorldHeight, c.WorldDepth };
    @memset(raw_blocks, 0x00);

    const size: u32 = c.WorldDepth * c.WorldHeight * c.WorldLength;
    std.mem.writeInt(u32, raw_blocks[0..4], size, .big);

    for (0..c.WorldDepth) |z| {
        for (0..c.WorldLength) |x| {
            set_block(@intCast(x), 0, @intCast(z), 7); // Bedrock
        }
    }

    // if (load("world.save")) {} else |_| {
    //     const FInt = fp.Fixed(32, 24, true);

    //     for (0..c.WorldLength) |x| {
    //         for (0..c.WorldDepth) |z| {
    //             var noise = perlin.noise3(.{ .value = @intCast(x << 19) }, .{ .value = @intCast(z << 19) }, FInt.from(0));
    //             noise = noise.add(.{ .value = 0xFFFFFF });

    //             for (0..@as(usize, @intCast(noise.value >> 19))) |h| {
    //                 set_block(@intCast(x), @intCast(h), @intCast(z), 1);
    //             }
    //         }
    //     }

    //     try save();
    // }
}

pub fn deinit() void {
    backing_allocator.free(raw_blocks);
    raw_blocks = undefined;
    blocks = undefined;
    world_size = undefined;
    backing_allocator = undefined;
}

fn get_index(x: usize, y: usize, z: usize) usize {
    return (y * c.WorldDepth + z) * c.WorldLength + x;
}

pub fn get_block(x: u16, y: u16, z: u16) u8 {
    assert(x >= 0 and x < c.WorldLength);
    assert(y >= 0 and y < c.WorldHeight);
    assert(z >= 0 and z < c.WorldDepth);

    const idx = get_index(x, y, z);
    return blocks[idx];
}

pub fn set_block(x: u16, y: u16, z: u16, block: u8) void {
    assert(x >= 0 and x < c.WorldLength);
    assert(y >= 0 and y < c.WorldHeight);
    assert(z >= 0 and z < c.WorldDepth);

    const idx = get_index(x, y, z);
    blocks[idx] = block;
}

pub fn tick() void {}

// TODO: Load & Save
