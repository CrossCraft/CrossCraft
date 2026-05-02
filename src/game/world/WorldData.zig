// --- WorldData ---
//
// Pure data: blocks, dimensions, light map, per-chunk counts. Reads, plus
// `apply_block` -- the single mutating primitive that maintains data
// invariants (chunk counts, sunlight column). No scheduler interaction;
// no save/load policy.

const std = @import("std");
const common = @import("common");
const c = common.consts;
const Xorshift64 = common.xorshift64.Xorshift64;
const assert = std.debug.assert;

const Block = c.Block;

pub const CHUNK_COUNT: u32 = c.ChunksX * c.ChunksZ * c.ChunksY;

const WorldData = @This();

backing_allocator: std.mem.Allocator,
raw_blocks: []u8,
blocks: []Block,
world_size: [3]u16,
seed: u64,
tick_count: u64,
/// World name as it appears in the ClassicWorld save. Padded with zeros
/// past `name_len`. Defaults to `"world"`; persisted/loaded by classic_cw.
name: [64]u8,
name_len: u8,
/// 16-byte stable identifier persisted in the ClassicWorld save. Random
/// at first generation; round-tripped through load.
uuid: [16]u8,
/// Java unix milliseconds at world creation. 0 if unknown (legacy
/// classic_dat saves don't carry it).
time_created: i64,
/// For each (x,z) column, stores Y+1 of the highest light-blocking block.
/// A value of 0 means the entire column is sunlit. Consumed by
/// `is_sunlit` and tree/grass growth checks, so it describes a light
/// occlusion map rather than a height/elevation map.
light_map: [c.WorldLength * c.WorldDepth]u8,
chunk_counts: [CHUNK_COUNT]u16,
chunk_non_opaque: [CHUNK_COUNT]u16,

const default_name = "world";

pub fn init(allocator: std.mem.Allocator, new_seed: u64) !WorldData {
    var self: WorldData = undefined;
    self.backing_allocator = allocator;
    self.raw_blocks = try allocator.alloc(u8, c.WorldDepth * c.WorldHeight * c.WorldLength + 4);
    self.blocks = @ptrCast(self.raw_blocks[4..]);
    self.world_size = .{ c.WorldLength, c.WorldHeight, c.WorldDepth };
    self.seed = new_seed;
    self.tick_count = 0;

    self.name = @splat(0);
    @memcpy(self.name[0..default_name.len], default_name);
    self.name_len = @intCast(default_name.len);
    self.uuid = @splat(0);
    self.time_created = 0;

    @memset(self.raw_blocks, 0x00);
    @memset(&self.light_map, 0);
    @memset(&self.chunk_counts, 0);
    @memset(&self.chunk_non_opaque, 0);

    // Big-endian total volume prefix kept in raw_blocks[0..4] for the
    // LevelDataChunk wire path (kept for save-file backward compatibility
    // too). Will move to the network sender in a later phase.
    const size: u32 = c.WorldDepth * c.WorldHeight * c.WorldLength;
    std.mem.writeInt(u32, self.raw_blocks[0..4], size, .big);

    return self;
}

/// Stamp the world with a fresh random UUID and the current real-clock
/// time. Called on first generation; load paths instead populate these
/// fields from the save file.
pub fn stamp_creation_metadata(self: *WorldData, io: std.Io) void {
    const real_ns: i64 = @truncate(std.Io.Clock.Timestamp.now(io, .real).raw.nanoseconds);
    var rng = Xorshift64.init(@bitCast(real_ns));
    std.mem.writeInt(u64, self.uuid[0..8], rng.next(), .little);
    std.mem.writeInt(u64, self.uuid[8..16], rng.next(), .little);
    self.time_created = @divTrunc(real_ns, std.time.ns_per_ms);
}

pub fn deinit(self: *WorldData) void {
    self.backing_allocator.free(self.raw_blocks);
    self.* = undefined;
}

pub fn get_index(_: *const WorldData, x: u16, y: u16, z: u16) u32 {
    assert(x < c.WorldLength);
    assert(y < c.WorldHeight);
    assert(z < c.WorldDepth);
    return c.block_index(@as(u32, x), @as(u32, y), @as(u32, z));
}

pub fn get_block(self: *const WorldData, x: u16, y: u16, z: u16) Block {
    return self.blocks[self.get_index(x, y, z)];
}

/// Pointer to ChunkSize contiguous blocks at chunk-aligned x.
/// In the chunk-aware layout, blocks at (x..x+15, y, z) are contiguous,
/// so callers can avoid per-block index computation in tight loops.
pub fn get_chunk_row(self: *const WorldData, x: u16, y: u16, z: u16) *const [c.ChunkSize]Block {
    assert(x % c.ChunkSize == 0);
    const base = self.get_index(x, y, z);
    return self.blocks[base..][0..c.ChunkSize];
}

/// Pointer to an entire 16x16x16 chunk (4 KiB). Index within the chunk
/// with `(ly * ChunkSize + lz) * ChunkSize + lx` -- the same 4-op
/// arithmetic as the old contiguous formula.
pub fn get_chunk_ptr(self: *const WorldData, chunk_cx: u32, chunk_cy: u32, chunk_cz: u32) *const [c.ChunkVolume]Block {
    const ci = (chunk_cy * c.ChunksZ + chunk_cz) * c.ChunksX + chunk_cx;
    return self.blocks[ci * c.ChunkVolume ..][0..c.ChunkVolume];
}

pub fn is_chunk_all_air(self: *const WorldData, cx: u32, cy: u32, cz: u32) bool {
    return self.chunk_counts[(cy * c.ChunksZ + cz) * c.ChunksX + cx] == 0;
}

pub fn is_chunk_all_opaque(self: *const WorldData, cx: u32, cy: u32, cz: u32) bool {
    return self.chunk_non_opaque[(cy * c.ChunksZ + cz) * c.ChunksX + cx] == 0;
}

fn chunk_idx(x: u16, y: u16, z: u16) u32 {
    return (@as(u32, y) / c.ChunkSize * c.ChunksZ + @as(u32, z) / c.ChunkSize) * c.ChunksX + @as(u32, x) / c.ChunkSize;
}

/// Pure data write. Maintains chunk count invariants and the light
/// column. Does NOT touch the scheduler -- that's the simulation's job.
pub fn apply_block(self: *WorldData, x: u16, y: u16, z: u16, block: Block) void {
    const idx = self.get_index(x, y, z);
    const old = self.blocks[idx];
    self.blocks[idx] = block;

    const ci = chunk_idx(x, y, z);
    if (old.is_air() and !block.is_air()) {
        self.chunk_counts[ci] += 1;
    } else if (!old.is_air() and block.is_air()) {
        self.chunk_counts[ci] -= 1;
    }
    const old_opq = old.is_opaque();
    const new_opq = block.is_opaque();
    if (old_opq and !new_opq) {
        self.chunk_non_opaque[ci] += 1;
    } else if (!old_opq and new_opq) {
        self.chunk_non_opaque[ci] -= 1;
    }

    self.update_height_column(x, y, z, block);
}

/// Scan each 4 KiB chunk and count non-air / non-opaque blocks. Called once
/// after generation or load; maintained incrementally by `apply_block` thereafter.
pub fn compute_chunk_counts(self: *WorldData) void {
    for (0..CHUNK_COUNT) |ci| {
        const base = ci * c.ChunkVolume;
        var non_air: u16 = 0;
        var non_opq: u16 = 0;
        for (self.blocks[base..][0..c.ChunkVolume]) |b| {
            if (!b.is_air()) non_air += 1;
            if (!b.is_opaque()) non_opq += 1;
        }
        self.chunk_counts[ci] = non_air;
        self.chunk_non_opaque[ci] = non_opq;
    }
}

/// Build the full light map. Called once after generation or load.
pub fn compute_light_map(self: *WorldData) void {
    for (0..c.WorldDepth) |z| {
        for (0..c.WorldLength) |x| {
            self.light_map[z * c.WorldLength + x] = self.column_height(@intCast(x), @intCast(z));
        }
    }
}

/// Scan a single column top-down; return Y+1 of highest light-blocking block (0 if none).
fn column_height(self: *const WorldData, x: u16, z: u16) u8 {
    var y: u16 = c.WorldHeight;
    while (y > 0) {
        y -= 1;
        const blk = self.get_block(x, y, z);
        if (!blk.light_passes()) {
            return @intCast(y + 1);
        }
    }
    return 0;
}

/// Incrementally update height map after a block change at (x,y,z).
fn update_height_column(self: *WorldData, x: u16, y: u16, z: u16, block: Block) void {
    const col_idx: u32 = @as(u32, z) * c.WorldLength + x;
    const cur = self.light_map[col_idx];
    const is_blocker = blocks_light(block);

    if (is_blocker) {
        const new_h: u8 = @intCast(y + 1);
        if (new_h > cur) self.light_map[col_idx] = new_h;
    } else if (y + 1 >= cur) {
        // Removed the top blocker; rescan
        self.light_map[col_idx] = self.column_height(x, z);
    }
}

/// O(1) sunlight query: true if no light-blocking block exists above (x,y,z).
pub fn is_sunlit(self: *const WorldData, x: u16, y: u16, z: u16) bool {
    return y + 1 >= self.light_map[@as(u32, z) * c.WorldLength + x];
}

/// True when sunlight cannot pass through this block type.
pub fn blocks_light(block: Block) bool {
    return !block.light_passes();
}

pub fn has_direct_sunlight(self: *const WorldData, x: u16, y: u16, z: u16) bool {
    var check_y: u16 = y + 1;
    while (check_y < c.WorldHeight) : (check_y += 1) {
        const blk = self.get_block(x, check_y, z);
        if (!blk.light_passes()) return false;
    }
    return true;
}

pub fn find_spawn(self: *const WorldData, io: std.Io) [3]u16 {
    const spawn_seed: u64 = @truncate(@as(u96, @bitCast(std.Io.Clock.Timestamp.now(io, .boot).raw.nanoseconds)));
    var spawn_rng = Xorshift64.init(spawn_seed);
    for (0..10) |attempt| {
        const bx: u16 = @intCast(spawn_rng.next_bounded(c.WorldLength));
        const bz: u16 = @intCast(spawn_rng.next_bounded(c.WorldDepth));
        var by: u16 = c.WorldHeight - 1;
        while (by > 0) : (by -= 1) {
            const blk = self.get_block(bx, by, bz);
            if (!blk.is_air() and !blk.is_fluid()) {
                const above: Block = if (by + 1 < c.WorldHeight) self.get_block(bx, by + 1, bz) else .{ .id = .air };
                if (above.is_fluid() and attempt < 9) break;
                return .{
                    @intCast(@as(u32, bx) * 32 + 16),
                    @intCast(@as(u32, by + 1) * 32 + 51),
                    @intCast(@as(u32, bz) * 32 + 16),
                };
            }
        }
    }
    const cx: u16 = c.WorldLength / 2;
    const cz: u16 = c.WorldDepth / 2;
    var fy: u16 = c.WorldHeight - 1;
    while (fy > 0) : (fy -= 1) {
        const blk = self.get_block(cx, fy, cz);
        if (!blk.is_air() and !blk.is_fluid()) {
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

/// Write all blocks in contiguous YZX wire order from chunk-aware memory.
/// Within each (y,z) row, the 16 x-values per chunk are contiguous in the
/// chunk-aware layout, so each inner iteration is a 16-byte slice copy.
/// Used by the network LevelDataChunk path. The save format owns its own
/// traversal in classic_dat.zig; this stays public for the wire path.
pub fn write_blocks_yzx(self: *const WorldData, writer: *std.Io.Writer) !void {
    for (0..c.WorldHeight) |yi| {
        for (0..c.WorldDepth) |zi| {
            for (0..c.ChunksX) |cxi| {
                const base = c.block_index(@intCast(cxi * c.ChunkSize), @intCast(yi), @intCast(zi));
                const slice: *const [c.ChunkSize]u8 = @ptrCast(self.blocks[base..][0..c.ChunkSize]);
                try writer.writeAll(slice);
            }
        }
    }
}

/// Read contiguous YZX wire-order data and scatter into chunk-aware positions.
pub fn read_blocks_yzx(self: *WorldData, reader: *std.Io.Reader) !void {
    for (0..c.WorldHeight) |yi| {
        for (0..c.WorldDepth) |zi| {
            for (0..c.ChunksX) |cxi| {
                const base = c.block_index(@intCast(cxi * c.ChunkSize), @intCast(yi), @intCast(zi));
                const slice: *[c.ChunkSize]u8 = @ptrCast(self.blocks[base..][0..c.ChunkSize]);
                try reader.readSliceAll(slice);
            }
        }
    }
}
