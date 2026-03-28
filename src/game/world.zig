const std = @import("std");
const c = @import("common").consts;
const assert = std.debug.assert;

const FP = @import("common").fp.FP;
const perlin = @import("common").perlin;

pub var backing_allocator: std.mem.Allocator = undefined;
pub var raw_blocks: []u8 = undefined;
pub var blocks: []u8 = undefined;
pub var world_size: [3]u16 = undefined;

const Block = c.Block;

pub fn save() !void {}

pub fn load(path: []const u8) bool {
    _ = path;
    return false;
}

pub fn init(allocator: std.mem.Allocator, _: u64) !void {
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
}

pub fn deinit() void {
    save() catch unreachable;

    backing_allocator.free(raw_blocks);
    raw_blocks = undefined;
    blocks = undefined;
    world_size = undefined;
    backing_allocator = undefined;
}

fn get_index(x: usize, y: usize, z: usize) usize {
    assert(x < c.WorldLength);
    assert(y < c.WorldHeight);
    assert(z < c.WorldDepth);
    return (y * c.WorldDepth + z) * c.WorldLength + x;
}

pub fn get_block(x: usize, y: usize, z: usize) u8 {
    const idx = get_index(x, y, z);
    return blocks[idx];
}

pub fn set_block(x: usize, y: usize, z: usize, block: u8) void {
    const idx = get_index(x, y, z);
    blocks[idx] = block;
}

pub fn tick() void {}
