// --- Classic .dat save format (legacy CrossCraft custom binary) ---
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
const wd = @import("../../world_dims.zig");

const Block = b.Block;
const WorldDims = wd.WorldDims;
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
        std.mem.writeInt(u32, &prefix, @intCast(ctx.blocks.len), .big);
        try writer.writeAll(&prefix);
        try write_blocks_yzx(ctx.dims, ctx.blocks, writer);
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
        try read_blocks_yzx(dims, blocks, reader);
        return .{
            .dimensions = saved_dims,
            .seed = saved_seed[0],
            .tick_count = saved_tick[0],
        };
    }
};

fn write_blocks_yzx(dims: WorldDims, blocks: []const Block, writer: *std.Io.Writer) !void {
    for (0..dims.height) |yi| {
        for (0..dims.depth) |zi| {
            for (0..dims.chunks_x) |cxi| {
                const base = dims.block_index(@intCast(cxi * wd.chunk_size), @intCast(yi), @intCast(zi));
                const slice: *const [wd.chunk_size]u8 = @ptrCast(blocks[base..][0..wd.chunk_size]);
                try writer.writeAll(slice);
            }
        }
    }
}

fn read_blocks_yzx(dims: WorldDims, blocks: []Block, reader: *std.Io.Reader) !void {
    for (0..dims.height) |yi| {
        for (0..dims.depth) |zi| {
            for (0..dims.chunks_x) |cxi| {
                const base = dims.block_index(@intCast(cxi * wd.chunk_size), @intCast(yi), @intCast(zi));
                const slice: *[wd.chunk_size]u8 = @ptrCast(blocks[base..][0..wd.chunk_size]);
                try reader.readSliceAll(slice);
            }
        }
    }
}
