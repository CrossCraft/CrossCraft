const std = @import("std");
const wd = @import("../world_dims.zig");
const b = @import("../blocks.zig");
const assert = std.debug.assert;

const Block = b.Block;
pub const WorldDims = wd.WorldDims;

const WorldData = @This();

backing_allocator: std.mem.Allocator,
access_lock: std.Io.RwLock,
blocks: []Block,
dims: WorldDims,
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
/// occlusion map rather than a height/elevation map. `dims.length` long.
light_map: []u8,
/// Per-chunk non-air and non-opaque block counts, `dims.chunk_count()` long,
/// indexed by `dims.chunk_index`.
chunk_counts: []u16,
chunk_non_opaque: []u16,

const default_name = "world";

pub fn init_in_place(self: *WorldData, allocator: std.mem.Allocator, geometry: WorldDims, new_seed: u64) !void {
    self.* = .{
        .backing_allocator = allocator,
        .access_lock = .init,
        .blocks = &.{},
        .dims = geometry,
        .seed = new_seed,
        .tick_count = 0,
        .name = @splat(0),
        .name_len = 0,
        .uuid = @splat(0),
        .time_created = 0,
        .light_map = &.{},
        .chunk_counts = &.{},
        .chunk_non_opaque = &.{},
    };

    self.blocks = try allocator.alloc(Block, geometry.volume());
    errdefer allocator.free(self.blocks);
    self.light_map = try allocator.alloc(u8, geometry.length * geometry.depth);
    errdefer allocator.free(self.light_map);
    self.chunk_counts = try allocator.alloc(u16, geometry.chunk_count());
    errdefer allocator.free(self.chunk_counts);
    self.chunk_non_opaque = try allocator.alloc(u16, geometry.chunk_count());
    errdefer allocator.free(self.chunk_non_opaque);

    @memset(self.blocks, .air);
    @memset(self.light_map, 0);
    @memset(self.chunk_counts, 0);
    @memset(self.chunk_non_opaque, 0);

    @memcpy(self.name[0..default_name.len], default_name);
    self.name_len = @intCast(default_name.len);
}

/// Stamp the world with a fresh random UUID and the current real-clock
/// time. Called on first generation; load paths instead populate these
/// fields from the save file.
pub fn stamp_creation_metadata(self: *WorldData, io: std.Io) void {
    const real_ns: i64 = @truncate(std.Io.Clock.Timestamp.now(io, .real).raw.nanoseconds);
    var rng = std.Random.DefaultPrng.init(@bitCast(real_ns));
    std.mem.writeInt(u64, self.uuid[0..8], rng.next(), .little);
    std.mem.writeInt(u64, self.uuid[8..16], rng.next(), .little);
    self.time_created = @divTrunc(real_ns, std.time.ns_per_ms);
}

pub fn deinit(self: *WorldData) void {
    const allocator = self.backing_allocator;
    if (self.blocks.len > 0) allocator.free(self.blocks);
    if (self.light_map.len > 0) allocator.free(self.light_map);
    if (self.chunk_counts.len > 0) allocator.free(self.chunk_counts);
    if (self.chunk_non_opaque.len > 0) allocator.free(self.chunk_non_opaque);
    self.* = undefined;
}

pub fn lock(self: *WorldData, io: std.Io) void {
    self.access_lock.lockUncancelable(io);
}

pub fn unlock(self: *WorldData, io: std.Io) void {
    self.access_lock.unlock(io);
}

pub fn lock_shared(self: *WorldData, io: std.Io) void {
    self.access_lock.lockSharedUncancelable(io);
}

pub fn unlock_shared(self: *WorldData, io: std.Io) void {
    self.access_lock.unlockShared(io);
}

/// Free the block storage. Used on the generate path, where the generator
/// returns its own full-volume buffer that is adopted afterwards.
pub fn release_blocks(self: *WorldData) void {
    if (self.blocks.len == 0) return;
    self.backing_allocator.free(self.blocks);
    self.blocks = &.{};
}

/// Take ownership of a full-volume block buffer.
pub fn adopt_blocks(self: *WorldData, blocks: []u8) void {
    assert(blocks.len == self.dims.volume());
    self.blocks = @ptrCast(blocks);
}

pub fn get_index(self: *const WorldData, x: u16, y: u16, z: u16) u32 {
    assert(x < self.dims.length);
    assert(y < self.dims.height);
    assert(z < self.dims.depth);
    return self.dims.block_index(x, y, z);
}

pub fn get_block(self: *const WorldData, x: u16, y: u16, z: u16) Block {
    return self.blocks[self.get_index(x, y, z)];
}

/// Pointer to chunk_size contiguous blocks at chunk-aligned x.
/// In the chunk-aware layout, blocks at (x..x+15, y, z) are contiguous,
/// so callers can avoid per-block index computation in tight loops.
pub fn get_chunk_row(self: *const WorldData, x: u16, y: u16, z: u16) *const [wd.chunk_size]Block {
    assert(x % wd.chunk_size == 0);
    const base = self.get_index(x, y, z);
    return self.blocks[base..][0..wd.chunk_size];
}

pub fn is_chunk_all_air(self: *const WorldData, cx: u32, cy: u32, cz: u32) bool {
    return self.chunk_counts[self.dims.chunk_at(cx, cy, cz)] == 0;
}

pub fn is_chunk_all_opaque(self: *const WorldData, cx: u32, cy: u32, cz: u32) bool {
    return self.chunk_non_opaque[self.dims.chunk_at(cx, cy, cz)] == 0;
}

fn chunk_idx(self: *const WorldData, x: u16, y: u16, z: u16) u32 {
    return self.dims.chunk_index(x, y, z);
}

/// Pure data write. Maintains chunk count invariants and the light
/// column. Does NOT touch the scheduler -- that's the simulation's job.
pub fn apply_block(self: *WorldData, x: u16, y: u16, z: u16, block: Block) void {
    const idx = self.get_index(x, y, z);
    const old = self.blocks[idx];
    self.blocks[idx] = block;

    const ci = self.chunk_idx(x, y, z);
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
    for (0..self.chunk_counts.len) |ci| {
        const base = ci * wd.chunk_volume;
        var non_air: u16 = 0;
        var non_opq: u16 = 0;
        for (self.blocks[base..][0..wd.chunk_volume]) |blk| {
            if (!blk.is_air()) non_air += 1;
            if (!blk.is_opaque()) non_opq += 1;
        }
        self.chunk_counts[ci] = non_air;
        self.chunk_non_opaque[ci] = non_opq;
    }
}

/// Build the full light map. Called once after generation or load.
pub fn compute_light_map(self: *WorldData) void {
    for (0..self.dims.depth) |z| {
        for (0..self.dims.length) |x| {
            self.light_map[self.column_index(@intCast(z), @intCast(x))] = self.column_height(@intCast(x), @intCast(z));
        }
    }
}

/// Column-major into `light_map`; X is the fast axis, so a shift-and-or.
fn column_index(self: *const WorldData, z: u16, x: u16) u32 {
    return (@as(u32, z) << self.dims.log2_length) | x;
}

/// Scan a single column top-down; return Y+1 of highest light-blocking block (0 if none).
fn column_height(self: *const WorldData, x: u16, z: u16) u8 {
    var y: u32 = self.dims.height;
    while (y > 0) {
        y -= 1;
        const blk = self.get_block(x, @intCast(y), z);
        if (!blk.light_passes()) {
            return @intCast(y + 1);
        }
    }
    return 0;
}

/// Incrementally update height map after a block change at (x,y,z).
fn update_height_column(self: *WorldData, x: u16, y: u16, z: u16, block: Block) void {
    const col_idx = self.column_index(z, x);
    const cur = self.light_map[col_idx];
    const is_blocker = blocks_light(block);

    if (is_blocker) {
        const new_h: u8 = @intCast(y + 1);
        if (new_h > cur) self.light_map[col_idx] = new_h;
    } else if (y + 1 >= cur) {
        self.light_map[col_idx] = self.column_height(x, z);
    }
}

/// O(1) sunlight query: true if no light-blocking block exists above (x,y,z).
pub fn is_sunlit(self: *const WorldData, x: u16, y: u16, z: u16) bool {
    return y + 1 >= self.light_map[self.column_index(z, x)];
}

/// True when sunlight cannot pass through this block type.
pub fn blocks_light(block: Block) bool {
    return !block.light_passes();
}

pub fn find_spawn(self: *const WorldData, io: std.Io) [3]u16 {
    const spawn_seed: u64 = @truncate(@as(u96, @bitCast(std.Io.Clock.Timestamp.now(io, .boot).raw.nanoseconds)));
    var spawn_rng = std.Random.DefaultPrng.init(spawn_seed);
    for (0..10) |attempt| {
        const bx: u16 = @intCast(spawn_rng.next() % self.dims.length);
        const bz: u16 = @intCast(spawn_rng.next() % self.dims.depth);
        var by: u32 = self.dims.height - 1;
        while (by > 0) : (by -= 1) {
            const blk = self.get_block(bx, @intCast(by), bz);
            if (!blk.is_air() and !blk.is_fluid()) {
                const above: Block = if (by + 1 < self.dims.height)
                    self.get_block(bx, @intCast(by + 1), bz)
                else
                    .air;
                if (above.is_fluid() and attempt < 9) break;
                return .{
                    @intCast(@as(u32, bx) * 32 + 16),
                    @intCast((by + 1) * 32 + 51),
                    @intCast(@as(u32, bz) * 32 + 16),
                };
            }
        }
    }
    const cx: u16 = @intCast(self.dims.length / 2);
    const cz: u16 = @intCast(self.dims.depth / 2);
    var fy: u32 = self.dims.height - 1;
    while (fy > 0) : (fy -= 1) {
        const blk = self.get_block(cx, @intCast(fy), cz);
        if (!blk.is_air() and !blk.is_fluid()) {
            return .{
                @intCast(@as(u32, cx) * 32 + 16),
                @intCast((fy + 1) * 32 + 51),
                @intCast(@as(u32, cz) * 32 + 16),
            };
        }
    }
    return .{
        @intCast(@as(u32, cx) * 32 + 16),
        @as(u16, 32 + 51),
        @intCast(@as(u32, cz) * 32 + 16),
    };
}

/// Stream a race-free progressive capture in YZX order. Each band is copied
/// under the shared lock, which is released before compression or file I/O.
pub fn write_blocks_yzx(self: *WorldData, io: std.Io, writer: *std.Io.Writer) !void {
    var band_storage: [wd.max_length * wd.chunk_size]u8 = undefined;
    const band = band_storage[0..self.dims.band_len()];

    for (0..self.dims.height) |y| {
        var z: u32 = 0;
        while (z < self.dims.depth) : (z += wd.chunk_size) {
            self.lock_shared(io);
            self.copy_blocks_yzx_band(@intCast(y), @intCast(z), band);
            self.unlock_shared(io);
            try writer.writeAll(band);
        }
    }
}

/// Copy one wire-contiguous YZX band: all X values for chunk_size adjacent Z
/// rows at one Y level. This bounds shared-lock hold time to a short memcpy.
pub fn copy_blocks_yzx_band(
    self: *const WorldData,
    y: u16,
    z_start: u16,
    out: []u8,
) void {
    assert(y < self.dims.height);
    assert(z_start + wd.chunk_size <= self.dims.depth);
    assert(z_start % wd.chunk_size == 0);
    assert(out.len == self.dims.band_len());

    var offset: usize = 0;
    for (0..wd.chunk_size) |z_offset| {
        const z: u16 = z_start + @as(u16, @intCast(z_offset));
        for (0..self.dims.chunks_x) |chunk_x| {
            const base = self.dims.block_index(@intCast(chunk_x * wd.chunk_size), y, z);
            const row: *const [wd.chunk_size]u8 = @ptrCast(self.blocks[base..][0..wd.chunk_size]);
            @memcpy(out[offset..][0..wd.chunk_size], row);
            offset += wd.chunk_size;
        }
    }
}

pub fn read_blocks_yzx(self: *WorldData, reader: *std.Io.Reader) !void {
    return read_blocks_yzx_into(self.dims, self.blocks, reader);
}

pub fn read_blocks_yzx_into(dims: WorldDims, blocks: []Block, reader: *std.Io.Reader) !void {
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

/// Convert a contiguous YZX buffer (worldgen/wire order) to the chunk-aware
/// layout, in place. The move unit is a chunk_size-byte x-row; destinations
/// overlap not-yet-moved sources, so cycles are followed with one bit of
/// `visited` per row and the carry row is staged through `lookaside`.
/// `visited.len * 8` must cover `blocks.len / chunk_size` rows.
pub fn remap_yzx_to_chunk_aware(
    dims: WorldDims,
    blocks: []u8,
    lookaside: *[wd.chunk_volume]u8,
    visited: []u8,
) void {
    const rows = blocks.len / wd.chunk_size;
    const rows_per_slab_shift = dims.shift_slab;
    const rows_per_chunk = wd.chunk_size * wd.chunk_size;
    assert(blocks.len % wd.chunk_size == 0);
    assert(visited.len * 8 >= rows);

    var start: usize = 0;
    while (start < rows) : (start += 1) {
        if (row_bit(visited, start)) continue;
        @memcpy(lookaside[0..wd.chunk_size], blocks[start * wd.chunk_size ..][0..wd.chunk_size]);
        var j = start;
        while (true) {
            const k = blk: {
                const y = j >> rows_per_slab_shift;
                const rem = j & ((@as(usize, 1) << rows_per_slab_shift) - 1);
                const z = rem >> dims.shift_cz;
                const cx = rem & (dims.chunks_x - 1);
                const chunk = dims.chunk_index(
                    @intCast(cx * wd.chunk_size),
                    @intCast(y),
                    @intCast(z),
                );
                const within = (y & wd.chunk_mask) * wd.chunk_size + (z & wd.chunk_mask);
                break :blk chunk * rows_per_chunk + within;
            };
            if (k == start) {
                @memcpy(blocks[k * wd.chunk_size ..][0..wd.chunk_size], lookaside[0..wd.chunk_size]);
                set_row_bit(visited, k);
                break;
            }
            @memcpy(lookaside[wd.chunk_size .. 2 * wd.chunk_size], blocks[k * wd.chunk_size ..][0..wd.chunk_size]);
            @memcpy(blocks[k * wd.chunk_size ..][0..wd.chunk_size], lookaside[0..wd.chunk_size]);
            @memcpy(lookaside[0..wd.chunk_size], lookaside[wd.chunk_size .. 2 * wd.chunk_size]);
            set_row_bit(visited, k);
            j = k;
        }
    }
}

fn set_row_bit(visited: []u8, row: usize) void {
    visited[row / 8] |= @as(u8, 1) << @intCast(row % 8);
}

fn row_bit(visited: []const u8, row: usize) bool {
    return (visited[row / 8] >> @intCast(row % 8)) & 1 != 0;
}

test "remap_yzx_to_chunk_aware matches row scatter" {
    const dims = wd.default;
    const volume = dims.volume();
    const rows = volume / wd.chunk_size;
    const yzx = try std.testing.allocator.alloc(u8, volume);
    defer std.testing.allocator.free(yzx);
    const chunked = try std.testing.allocator.alloc(u8, volume);
    defer std.testing.allocator.free(chunked);
    const visited = try std.testing.allocator.alloc(u8, rows / 8);
    defer std.testing.allocator.free(visited);
    var lookaside: [wd.chunk_volume]u8 = undefined;

    var prng = std.Random.DefaultPrng.init(0xC0FFEE);
    prng.random().bytes(yzx);

    var src_row: usize = 0;
    for (0..dims.height) |y| {
        for (0..dims.depth) |z| {
            for (0..dims.chunks_x) |cxi| {
                const dst = dims.block_index(@intCast(cxi * wd.chunk_size), @intCast(y), @intCast(z));
                @memcpy(chunked[dst..][0..wd.chunk_size], yzx[src_row * wd.chunk_size ..][0..wd.chunk_size]);
                src_row += 1;
            }
        }
    }

    @memset(visited, 0);
    remap_yzx_to_chunk_aware(dims, yzx, &lookaside, visited);

    try std.testing.expectEqualSlices(u8, chunked, yzx);
}

test "copy_blocks_yzx_band preserves wire row order" {
    var data: WorldData = undefined;
    try data.init_in_place(std.testing.allocator, wd.default, 1);
    defer data.deinit();

    const y: u16 = 7;
    const z_start: u16 = 32;
    for (0..wd.chunk_size) |z_offset| {
        const z: u16 = z_start + @as(u16, @intCast(z_offset));
        for (0..data.dims.length) |x| {
            const value: u8 = @truncate(x + z_offset * 17);
            data.blocks[data.get_index(@intCast(x), y, z)] = @enumFromInt(value);
        }
    }

    const band = try std.testing.allocator.alloc(u8, data.dims.band_len());
    defer std.testing.allocator.free(band);
    data.copy_blocks_yzx_band(y, z_start, band);
    for (0..wd.chunk_size) |z_offset| {
        for (0..data.dims.length) |x| {
            const expected: u8 = @truncate(x + z_offset * 17);
            try std.testing.expectEqual(expected, band[z_offset * data.dims.length + x]);
        }
    }
}

test "write_blocks_yzx releases the lock before writing each band" {
    const io = std.testing.io;
    var data: WorldData = undefined;
    try data.init_in_place(std.testing.allocator, wd.from_presets(.tiny, .normal), 1);
    defer data.deinit();

    const ProbeWriter = struct {
        interface: std.Io.Writer,
        world: *WorldData,
        calls: usize = 0,
        valid_bands: bool = true,
        first_bytes: [2]u8 = @splat(0),

        fn init(world: *WorldData) @This() {
            return .{
                .interface = .{
                    .vtable = &.{ .drain = drain },
                    .buffer = &.{},
                },
                .world = world,
            };
        }

        fn drain(writer: *std.Io.Writer, chunks: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
            const self: *@This() = @alignCast(@fieldParentPtr("interface", writer));
            if (chunks.len != 1 or splat != 1 or chunks[0].len != self.world.dims.band_len()) {
                self.valid_bands = false;
            }
            if (self.calls < self.first_bytes.len and chunks.len > 0 and chunks[0].len > 0) {
                self.first_bytes[self.calls] = chunks[0][0];
            }

            if (!self.world.access_lock.tryLock(io)) return error.WriteFailed;
            defer self.world.access_lock.unlock(io);
            if (self.calls == 0) {
                self.world.blocks[self.world.get_index(0, 0, wd.chunk_size)] = .stone;
            }

            self.calls += 1;
            return writer.consume(writer.end + std.Io.Writer.countSplat(chunks, splat));
        }
    };

    var probe = ProbeWriter.init(&data);
    try data.write_blocks_yzx(io, &probe.interface);

    try std.testing.expect(probe.valid_bands);
    try std.testing.expectEqual(@as(usize, data.dims.height * data.dims.chunks_z), probe.calls);
    try std.testing.expectEqual(@intFromEnum(Block.air), probe.first_bytes[0]);
    try std.testing.expectEqual(@intFromEnum(Block.stone), probe.first_bytes[1]);
}

test "apply_block maintains the sunlight column" {
    var data: WorldData = undefined;
    try data.init_in_place(std.testing.allocator, wd.default, 1);
    defer data.deinit();
    data.compute_chunk_counts();
    data.compute_light_map();

    try std.testing.expect(data.is_sunlit(10, 10, 10));
    data.apply_block(10, 20, 10, .stone);
    try std.testing.expect(!data.is_sunlit(10, 19, 10));
    try std.testing.expect(data.is_sunlit(10, 20, 10));

    data.apply_block(10, 5, 10, .stone);
    data.apply_block(10, 20, 10, .air);
    try std.testing.expect(!data.is_sunlit(10, 4, 10));
    try std.testing.expect(data.is_sunlit(10, 5, 10));
    data.apply_block(10, 5, 10, .air);
    try std.testing.expect(data.is_sunlit(10, 4, 10));
}
