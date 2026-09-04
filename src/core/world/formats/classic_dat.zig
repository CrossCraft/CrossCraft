// Legacy CrossCraft .dat save format.
//
// Header layout (all little-endian unless noted):
//   3 x u16 : world dimensions (length, height, depth)
//   1 x u64 : world seed
//   1 x u64 : tick count
//   4 x u8  : big-endian total volume prefix, written verbatim for save-file
//             backward compatibility and validated/dropped on read.
// Body:
//   blocks in YZX wire order, traversed as 16-byte chunk rows so the chunk-
//   aware in-memory layout streams without a scatter pass.
//
// classic_dat does not carry the ClassicWorld metadata (name, uuid,
// timestamps); LoadOutcome is filled with defaults on load.

const std = @import("std");
const b = @import("../../blocks.zig");
const Block = b.Block;
const WorldDims = @import("../../world_dims.zig").WorldDims;
const WorldData = @import("../WorldData.zig");
const SaveContext = @import("../SaveFormat.zig").SaveContext;
const LoadOutcome = @import("../SaveFormat.zig").LoadOutcome;

const log = std.log.scoped(.world);

pub const ClassicDat = struct {
    pub fn save_world(
        _: ClassicDat,
        ctx: SaveContext,
        writer: *std.Io.Writer,
    ) !void {
        const size = ctx.dims.to_array();
        try writer.writeSliceEndian(u16, &size, .little);
        const seed_arr = [1]u64{ctx.seed};
        try writer.writeSliceEndian(u64, &seed_arr, .little);
        const tick_arr = [1]u64{ctx.tick_count};
        try writer.writeSliceEndian(u64, &tick_arr, .little);
        var prefix: [4]u8 = undefined;
        std.mem.writeInt(u32, &prefix, @intCast(ctx.dims.volume()), .big);
        try writer.writeAll(&prefix);
        try ctx.world.write_blocks_yzx(ctx.io, writer);
        try writer.flush();
    }

    pub fn load_world(
        _: ClassicDat,
        _: std.mem.Allocator,
        dims: WorldDims,
        blocks: []Block,
        reader: *std.Io.Reader,
    ) !LoadOutcome {
        var saved_dims: [3]u16 = undefined;
        try reader.readSliceEndian(u16, &saved_dims, .little);
        if (!dims.matches(saved_dims)) {
            log.err("classic_dat save is {}x{}x{}, expected {}x{}x{}", .{
                saved_dims[0], saved_dims[1], saved_dims[2],
                dims.length,   dims.height,   dims.depth,
            });
            return error.DimensionMismatch;
        }
        var saved_seed: [1]u64 = undefined;
        try reader.readSliceEndian(u64, &saved_seed, .little);
        var saved_tick: [1]u64 = undefined;
        try reader.readSliceEndian(u64, &saved_tick, .little);
        var prefix: [4]u8 = undefined;
        try reader.readSliceAll(&prefix);
        const saved_volume = std.mem.readInt(u32, &prefix, .big);
        if (saved_volume != dims.volume()) return error.UnexpectedBlockCount;
        try WorldData.read_blocks_yzx_into(dims, blocks, reader);
        return .{
            .dimensions = saved_dims,
            .seed = saved_seed[0],
            .tick_count = saved_tick[0],
        };
    }

    /// Dimensions announced in the 3 x u16 little-endian header, without
    /// reading the block payload. Null when the prefix is truncated or the
    /// dims fall outside the supported lattice.
    pub fn sniff_dims(_: ClassicDat, prefix: []const u8, _: std.mem.Allocator) ?WorldDims {
        if (prefix.len < 6) return null;
        var dims: [3]u16 = undefined;
        for (0..3) |i| {
            dims[i] = std.mem.readInt(u16, prefix[i * 2 ..][0..2], .little);
        }
        return WorldDims.from_array(dims);
    }
};

test "sniff_dims reads the 3 x u16 header" {
    var prefix: [8]u8 = @splat(0);
    std.mem.writeInt(u16, prefix[0..2], 512, .little);
    std.mem.writeInt(u16, prefix[2..4], 128, .little);
    std.mem.writeInt(u16, prefix[4..6], 512, .little);

    const dims = ClassicDat.sniff_dims(.{}, &prefix, std.testing.allocator).?;
    try std.testing.expectEqual(@as(u32, 512), dims.length);
    try std.testing.expectEqual(@as(u32, 128), dims.height);
    try std.testing.expectEqual(@as(u32, 512), dims.depth);
}

test "sniff_dims rejects truncation and unsupported dims" {
    var prefix: [8]u8 = @splat(0);
    std.mem.writeInt(u16, prefix[0..2], 256, .little);
    try std.testing.expect(ClassicDat.sniff_dims(.{}, prefix[0..5], std.testing.allocator) == null);

    std.mem.writeInt(u16, prefix[0..2], 192, .little); // not a power of two
    try std.testing.expect(ClassicDat.sniff_dims(.{}, &prefix, std.testing.allocator) == null);

    std.mem.writeInt(u16, prefix[0..2], 1024, .little); // above max_length
    try std.testing.expect(ClassicDat.sniff_dims(.{}, &prefix, std.testing.allocator) == null);
}

test "load rejects a mismatched volume prefix before writing blocks" {
    const dims = WorldDims.init(128, 64, 128);
    var bytes: [26]u8 = undefined;
    var writer = std.Io.Writer.fixed(&bytes);
    const saved_dims = dims.to_array();
    try writer.writeSliceEndian(u16, &saved_dims, .little);
    try writer.writeInt(u64, 123, .little);
    try writer.writeInt(u64, 456, .little);
    try writer.writeInt(u32, @intCast(dims.volume() - 1), .big);

    var blocks = [1]Block{.stone};
    var reader = std.Io.Reader.fixed(writer.buffered());
    try std.testing.expectError(
        error.UnexpectedBlockCount,
        ClassicDat.load_world(.{}, std.testing.allocator, dims, &blocks, &reader),
    );
    try std.testing.expectEqual(Block.stone, blocks[0]);
}

test "writer and loader round trip chunk-aware blocks and counters" {
    const io = std.testing.io;
    const dims = WorldDims.init(128, 64, 128);
    var source: WorldData = undefined;
    try source.init_in_place(std.testing.allocator, dims, 0x0123_4567_89ab_cdef);
    defer source.deinit();
    source.tick_count = 0xfedc_ba98_7654_3210;

    const markers = [_]struct { x: u16, y: u16, z: u16, block: Block }{
        .{ .x = 0, .y = 0, .z = 0, .block = .stone },
        .{ .x = 15, .y = 7, .z = 15, .block = .glass },
        .{ .x = 16, .y = 7, .z = 15, .block = .flowing_water },
        .{ .x = 17, .y = 7, .z = 16, .block = .flowing_lava },
        .{ .x = 127, .y = 63, .z = 127, .block = .magenta_wool },
    };
    for (markers) |marker| {
        source.blocks[source.get_index(marker.x, marker.y, marker.z)] = marker.block;
    }

    const encoded = try std.testing.allocator.alloc(u8, dims.volume() + 26);
    defer std.testing.allocator.free(encoded);
    var writer = std.Io.Writer.fixed(encoded);
    try ClassicDat.save_world(.{}, .{
        .dims = dims,
        .seed = source.seed,
        .tick_count = source.tick_count,
        .world = &source,
        .io = io,
        .name = "unused",
        .uuid = @splat(0),
        .spawn = @splat(0),
        .time_created = 0,
        .last_modified = 0,
    }, &writer);

    const loaded = try std.testing.allocator.alloc(Block, dims.volume());
    defer std.testing.allocator.free(loaded);
    @memset(loaded, .bedrock);
    var reader = std.Io.Reader.fixed(writer.buffered());
    const outcome = try ClassicDat.load_world(.{}, std.testing.allocator, dims, loaded, &reader);

    try std.testing.expectEqual(dims.to_array(), outcome.dimensions);
    try std.testing.expectEqual(source.seed, outcome.seed);
    try std.testing.expectEqual(source.tick_count, outcome.tick_count);
    try std.testing.expectEqualSlices(Block, source.blocks, loaded);
    for (markers) |marker| {
        try std.testing.expectEqual(marker.block, loaded[source.get_index(marker.x, marker.y, marker.z)]);
    }
}
