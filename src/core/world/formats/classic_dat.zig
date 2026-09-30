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
