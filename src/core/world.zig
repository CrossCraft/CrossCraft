const std = @import("std");
const c = @import("consts.zig");
const assert = std.debug.assert;

const FP = @import("fp.zig").FP;
const perlin = @import("perlin.zig");

pub var backing_allocator: std.mem.Allocator = undefined;
pub var raw_blocks: []u8 = undefined;
pub var blocks: []u8 = undefined;
pub var world_size: [3]u16 = undefined;

const Block = c.Block;

pub fn save() !void {
    var file = try std.fs.cwd().createFile("world.save", .{});
    defer file.close();

    try file.writeAll(raw_blocks);
}

pub fn load(path: []const u8) bool {
    var file = std.fs.cwd().openFile(path, .{}) catch return false;
    defer file.close();

    const size = file.readAll(raw_blocks) catch return false;
    assert(size == raw_blocks.len);

    return true;
}

pub fn init(allocator: std.mem.Allocator, seed: u64) !void {
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

    if (!load("world.save")) {
        const FInt = FP(32, 24, true);
        for (0..c.WorldLength) |x| {
            for (0..c.WorldDepth) |z| {
                var noise = perlin.noise3(.{ .value = @intCast(x << 19) }, .{ .value = @intCast(z << 19) }, FInt.from(@bitCast(@as(u32, @truncate(seed)))));
                noise = noise.add(.{ .value = 0xFFFFFF });

                const h = @as(usize, @intCast(noise.value >> 20)) + 20;
                for (0..@max(c.Water_Level, h)) |y| {
                    if (y >= h and y < c.Water_Level) {
                        set_block(x, y, z, Block.Flowing_Water); // Water
                    } else if (y == h - 1) {
                        if (y < c.Water_Level - 1) {
                            set_block(x, y, z, Block.Dirt); // Dirt
                        } else {
                            set_block(x, y, z, Block.Grass); // Grass
                        }
                    } else if (y > h and y < c.WorldHeight - 1) {
                        set_block(x, y, z, Block.Air); // Air
                    } else if (y < h and y > h - 5) {
                        set_block(x, y, z, Block.Dirt); // Dirt
                    } else {
                        set_block(x, y, z, Block.Stone);
                    }
                }
            }
        }

        try save();
    }
}

pub fn deinit() void {
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
