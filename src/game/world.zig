const std = @import("std");
const c = @import("common").consts;
const assert = std.debug.assert;

const log = std.log.scoped(.world);

pub var backing_allocator: std.mem.Allocator = undefined;
pub var raw_blocks: []u8 = undefined;
pub var blocks: []u8 = undefined;
pub var world_size: [3]u16 = undefined;
pub var seed: u64 = undefined;
pub var io: std.Io = undefined;
var tick_counter: u32 = 0;

/// File header: 3 little-endian u16 (x, y, z), 1 little-endian u64 (seed), then raw block data.
pub fn save() !void {
    const file = std.Io.Dir.cwd().createFile(io, "world.dat", .{}) catch |err| {
        log.err("Failed to create world.dat: {}", .{err});
        return err;
    };
    defer file.close(io);

    var write_buf: [4096]u8 = undefined;
    var writer = file.writer(io, &write_buf);

    try writer.interface.writeSliceEndian(u16, &world_size, .little);
    const seed_arr = [1]u64{seed};
    try writer.interface.writeSliceEndian(u64, &seed_arr, .little);
    try writer.interface.writeAll(raw_blocks);
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

    var saved_seed: [1]u64 = undefined;
    reader.interface.readSliceEndian(u64, &saved_seed, .little) catch return false;
    reader.interface.readSliceAll(raw_blocks) catch return false;

    world_size = dims;
    seed = saved_seed[0];
    log.info("Loaded world from world.dat", .{});
    return true;
}

pub fn init(allocator: std.mem.Allocator, scratch: std.mem.Allocator, _io: std.Io, new_seed: u64) !void {
    backing_allocator = allocator;
    io = _io;

    raw_blocks = try allocator.alloc(u8, c.WorldDepth * c.WorldHeight * c.WorldLength + 4);
    blocks = raw_blocks[4..];

    world_size = .{ c.WorldLength, c.WorldHeight, c.WorldDepth };
    @memset(raw_blocks, 0x00);

    const size: u32 = c.WorldDepth * c.WorldHeight * c.WorldLength;
    std.mem.writeInt(u32, raw_blocks[0..4], size, .big);

    if (!load()) {
        seed = new_seed;
        const worldgen = @import("common").worldgen;
        const start = std.Io.Clock.Timestamp.now(io, .boot);
        try worldgen.generate(scratch, blocks, seed, io);
        const end = std.Io.Clock.Timestamp.now(io, .boot);
        const elapsed_ns: i96 = end.raw.nanoseconds - start.raw.nanoseconds;
        const elapsed_ms = @divTrunc(elapsed_ns, std.time.ns_per_ms);
        log.info("World generation took {d}ms", .{elapsed_ms});
    }
    log.info("World seed: {d}", .{seed});
}

pub fn deinit() void {
    save() catch {};

    backing_allocator.free(raw_blocks);
    raw_blocks = undefined;
    blocks = undefined;
    world_size = undefined;
    seed = undefined;
    backing_allocator = undefined;
}

fn get_index(x: u16, y: u16, z: u16) u32 {
    assert(x < c.WorldLength);
    assert(y < c.WorldHeight);
    assert(z < c.WorldDepth);
    return (@as(u32, y) * c.WorldDepth + z) * c.WorldLength + x;
}

pub fn get_block(x: u16, y: u16, z: u16) u8 {
    const idx = get_index(x, y, z);
    return blocks[idx];
}

pub fn set_block(x: u16, y: u16, z: u16, block: u8) void {
    const idx = get_index(x, y, z);
    blocks[idx] = block;
}

pub fn find_spawn() [3]u16 {
    const B = c.Block;
    const spawn_seed: u64 = @truncate(@as(u96, @bitCast(std.Io.Clock.Timestamp.now(io, .boot).raw.nanoseconds)));
    var rng = @import("common").xorshift64.Xorshift64.init(spawn_seed);
    for (0..10) |attempt| {
        const bx: u16 = @intCast(rng.next_bounded(c.WorldLength));
        const bz: u16 = @intCast(rng.next_bounded(c.WorldDepth));
        // Walk down from top to find surface
        var by: u16 = c.WorldHeight - 1;
        while (by > 0) : (by -= 1) {
            const blk = get_block(bx, by, bz);
            if (blk != B.Air and blk != B.Flowing_Water and blk != B.Still_Water and
                blk != B.Flowing_Lava and blk != B.Still_Lava)
            {
                // Found solid ground; spawn one block above
                const above = if (by + 1 < c.WorldHeight) get_block(bx, by + 1, bz) else B.Air;
                const in_fluid = above == B.Still_Water or above == B.Flowing_Water or
                    above == B.Still_Lava or above == B.Flowing_Lava;
                if (in_fluid and attempt < 9) break;
                return .{
                    @intCast(@as(u32, bx) * 32 + 16),
                    @intCast(@as(u32, by + 1) * 32 + 51),
                    @intCast(@as(u32, bz) * 32 + 16),
                };
            }
        }
    }
    // Fallback: world center, walk down to find surface
    const cx: u16 = c.WorldLength / 2;
    const cz: u16 = c.WorldDepth / 2;
    var fy: u16 = c.WorldHeight - 1;
    while (fy > 0) : (fy -= 1) {
        const blk = get_block(cx, fy, cz);
        if (blk != B.Air and blk != B.Flowing_Water and blk != B.Still_Water and
            blk != B.Flowing_Lava and blk != B.Still_Lava)
        {
            return .{
                @intCast(@as(u32, cx) * 32 + 16),
                @intCast(@as(u32, fy + 1) * 32 + 51),
                @intCast(@as(u32, cz) * 32 + 16),
            };
        }
    }
    return .{
        @intCast(@as(u32, cx) * 32 + 16),
        @intCast(@as(u32, 1) * 32 + 51),
        @intCast(@as(u32, cz) * 32 + 16),
    };
}

pub fn tick() void {
    tick_counter += 1;
    if (tick_counter >= 200) {
        tick_counter = 0;
        save() catch {};
    }
}
