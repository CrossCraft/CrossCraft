// --- Classic .dat save format (legacy CrossCraft custom binary) ---
//
// Header layout (all little-endian unless noted):
//   3 x u16 : world dimensions (length, height, depth)
//   1 x u64 : world seed
//   1 x u64 : tick count
//   4 x u8  : raw_blocks[0..4] -- the big-endian total volume prefix that
//             init_empty stamps into the data buffer for the LevelDataChunk
//             wire path. Persisted verbatim for save-file backward
//             compatibility; reconstructed on read into raw_blocks[0..4].
// Body:
//   blocks in YZX wire order, traversed as 16-byte chunk rows so the chunk-
//   aware in-memory layout streams without a scatter pass.
//
// classic_dat does not carry the ClassicWorld metadata (name, uuid,
// timestamps); LoadOutcome is filled with defaults on load.

const std = @import("std");
const common = @import("common");
const c = common.consts;

const Block = c.Block;
const SaveContext = @import("../SaveFormat.zig").SaveContext;
const LoadOutcome = @import("../SaveFormat.zig").LoadOutcome;

pub const ClassicDat = struct {
    pub fn save_world(
        _: ClassicDat,
        ctx: SaveContext,
        writer: *std.Io.Writer,
    ) !void {
        try writer.writeSliceEndian(u16, &ctx.world_size, .little);
        const seed_arr = [1]u64{ctx.seed};
        try writer.writeSliceEndian(u64, &seed_arr, .little);
        const tick_arr = [1]u64{ctx.tick_count};
        try writer.writeSliceEndian(u64, &tick_arr, .little);
        try writer.writeAll(ctx.raw_blocks[0..4]);
        try write_blocks_yzx(ctx.blocks, writer);
        try writer.flush();
    }

    pub fn load_world(
        _: ClassicDat,
        raw_blocks: []u8,
        blocks: []Block,
        reader: *std.Io.Reader,
    ) !LoadOutcome {
        var dims: [3]u16 = undefined;
        try reader.readSliceEndian(u16, &dims, .little);
        var saved_seed: [1]u64 = undefined;
        try reader.readSliceEndian(u64, &saved_seed, .little);
        var saved_tick: [1]u64 = undefined;
        try reader.readSliceEndian(u64, &saved_tick, .little);
        try reader.readSliceAll(raw_blocks[0..4]);
        try read_blocks_yzx(blocks, reader);
        return .{
            .dimensions = dims,
            .seed = saved_seed[0],
            .tick_count = saved_tick[0],
        };
    }
};

fn write_blocks_yzx(blocks: []const Block, writer: *std.Io.Writer) !void {
    for (0..c.WorldHeight) |yi| {
        for (0..c.WorldDepth) |zi| {
            for (0..c.ChunksX) |cxi| {
                const base = c.block_index(@intCast(cxi * c.ChunkSize), @intCast(yi), @intCast(zi));
                const slice: *const [c.ChunkSize]u8 = @ptrCast(blocks[base..][0..c.ChunkSize]);
                try writer.writeAll(slice);
            }
        }
    }
}

fn read_blocks_yzx(blocks: []Block, reader: *std.Io.Reader) !void {
    for (0..c.WorldHeight) |yi| {
        for (0..c.WorldDepth) |zi| {
            for (0..c.ChunksX) |cxi| {
                const base = c.block_index(@intCast(cxi * c.ChunkSize), @intCast(yi), @intCast(zi));
                const slice: *[c.ChunkSize]u8 = @ptrCast(blocks[base..][0..c.ChunkSize]);
                try reader.readSliceAll(slice);
            }
        }
    }
}
