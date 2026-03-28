const std = @import("std");
const c = @import("common").consts;
const assert = std.debug.assert;
const flate = std.compress.flate;

const FP = @import("common").fp.FP;
const perlin = @import("common").perlin;

const log = std.log.scoped(.world);

pub var backing_allocator: std.mem.Allocator = undefined;
pub var raw_blocks: []u8 = undefined;
pub var blocks: []u8 = undefined;
pub var world_size: [3]u16 = undefined;
pub var io: std.Io = undefined;

const Block = c.Block;

/// File header: 3 little-endian u16 values (x, y, z) followed by gzip-compressed block data.
pub fn save() !void {
    const file = std.Io.Dir.cwd().createFile(io, "world.dat", .{}) catch |err| {
        log.err("Failed to create world.dat: {}", .{err});
        return err;
    };
    defer file.close(io);

    var write_buf: [4096]u8 = undefined;
    var writer = file.writer(io, &write_buf);

    // Header: world dimensions.
    try writer.interface.writeSliceEndian(u16, &world_size, .little);

    // Gzip-compressed raw block data.
    var compress_buf: [flate.max_window_len]u8 = undefined;
    var compressor = try flate.Compress.init(&writer.interface, &compress_buf, .gzip, .fastest);
    try compressor.writer.writeAll(raw_blocks);
    try compressor.finish();
    try writer.interface.flush();

    log.info("Saved world to world.dat", .{});
}

pub fn load() bool {
    const file = std.Io.Dir.cwd().openFile(io, "world.dat", .{}) catch {
        return false;
    };
    defer file.close(io);

    var read_buf: [4096]u8 = undefined;
    var reader = file.reader(io, &read_buf);

    // Header: world dimensions.
    var dims: [3]u16 = undefined;
    reader.interface.readSliceEndian(u16, &dims, .little) catch return false;

    if (dims[0] != c.WorldLength or dims[1] != c.WorldHeight or dims[2] != c.WorldDepth) {
        log.err("World dimensions mismatch: expected {}x{}x{}, got {}x{}x{}", .{
            c.WorldLength, c.WorldHeight, c.WorldDepth,
            dims[0],       dims[1],       dims[2],
        });
        return false;
    }

    // Gzip-compressed raw block data.
    var decompress_buf: [flate.max_window_len]u8 = undefined;
    var decompressor = flate.Decompress.init(&reader.interface, .gzip, &decompress_buf);
    decompressor.reader.readSliceAll(raw_blocks) catch return false;

    world_size = dims;
    log.info("Loaded world from world.dat", .{});
    return true;
}

pub fn init(allocator: std.mem.Allocator, _io: std.Io, seed: u64) !void {
    backing_allocator = allocator;
    io = _io;

    raw_blocks = try allocator.alloc(u8, c.WorldDepth * c.WorldHeight * c.WorldLength + 4);
    blocks = raw_blocks[4..];

    world_size = .{ c.WorldLength, c.WorldHeight, c.WorldDepth };
    @memset(raw_blocks, 0x00);

    const size: u32 = c.WorldDepth * c.WorldHeight * c.WorldLength;
    std.mem.writeInt(u32, raw_blocks[0..4], size, .big);

    if (!load()) {
        _ = seed;
        // No saved world — generate default.
        for (0..c.WorldDepth) |z| {
            for (0..c.WorldLength) |x| {
                set_block(@intCast(x), 0, @intCast(z), 7); // Bedrock
            }
        }

        try save();
    }
}

pub fn deinit() void {
    save() catch {};

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
