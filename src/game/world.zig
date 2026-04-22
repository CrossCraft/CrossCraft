const std = @import("std");
const common = @import("common");
const c = common.consts;
const Xorshift64 = common.xorshift64.Xorshift64;
const BlockRegistry = common.BlockRegistry;
const assert = std.debug.assert;

const Server = @import("server.zig");
const log = std.log.scoped(.world);

const Block = c.Block;
const Location = c.Location;

inline fn sim_props(block: Block) BlockRegistry.SimProps {
    return BlockRegistry.global.sim_props[@intFromEnum(block.id)];
}

inline fn mesh_props(block: Block) BlockRegistry.MeshProps {
    return BlockRegistry.global.mesh_props[@intFromEnum(block.id)];
}

pub const BlockChange = struct {
    x: u16,
    y: u16,
    z: u16,
    block: Block,
};

const MAX_PENDING_CHANGES: u32 = 512;
pub var pending_changes: [MAX_PENDING_CHANGES]BlockChange = undefined;
pub var pending_count: u32 = 0;

// -- Timer wheel -----------------------------------------------------------
// 1024 buckets (one per tick modulo WHEEL_SIZE). Each bucket is a singly-
// linked list threaded through a pool of fixed-size nodes. Entries land in
// bucket[ready_tick % WHEEL_SIZE] so only the current tick's bucket is
// drained each tick - no dequeue-decrement-reenqueue of deferred entries.
const WHEEL_SIZE: u32 = 1024;
const WHEEL_MASK: u32 = WHEEL_SIZE - 1;
const POOL_CAPACITY: u32 = 1 << 13; // 8192 nodes

const SENTINEL: u32 = std.math.maxInt(u32);

const WheelNode = packed struct(u64) {
    loc: Location,
    next: u32, // index into node pool, SENTINEL = end-of-list
};

var wheel_buckets: [WHEEL_SIZE]u32 = @splat(SENTINEL); // head index per bucket
var node_pool: []WheelNode = undefined;
var free_head: u32 = 0; // head of the free list
var pool_used: u32 = 0; // live count
var pool_used_peak: u32 = 0; // high-water across the session, logged on deinit
var rng: Xorshift64 = .{ .state = 1 };

// -- Per-chunk block counts (work-skipping) --------------------------------
const CHUNK_COUNT: u32 = c.ChunksX * c.ChunksZ * c.ChunksY;
var chunk_counts: [CHUNK_COUNT]u16 = undefined; // non-air blocks
var chunk_non_opaque: [CHUNK_COUNT]u16 = undefined; // non-opaque blocks

// -- Enqueue dedup (fixed-capacity flat set, linear scan) ------------------
// At POOL_CAPACITY=8192 entries, a flat u32 array is 32 KiB and every op
// fits in a single SIMD-friendly scan - faster and ~40x smaller than a
// hashmap once the index table and load-factor padding are counted.
// Pre-reserved at init; runtime ops never grow.
var enqueued: std.ArrayListUnmanaged(u32) = .empty;

pub const LoadStatus = union(enum) {
    loading,
    generating: @import("worldgen.zig").GenPhase,
    downloading: u8,
    complete,
};

pub var load_status: LoadStatus = .loading;

/// False for worlds streamed from a remote server (multiplayer client).
/// All save/autosave paths early-return when this is false so an MP client
/// can never persist a snapshot of somebody else's world as its own.
pub var owned_locally: bool = false;

/// Periodic in-tick autosave. Left on for the dedicated server (crash
/// insurance across long uptimes) and off for singleplayer, which saves
/// explicitly on worldgen completion and on shutdown via `deinit`.
pub var autosave_enabled: bool = true;

pub var backing_allocator: std.mem.Allocator = undefined;
pub var raw_blocks: []u8 = undefined;
pub var blocks: []Block = undefined;
pub var world_size: [3]u16 = undefined;
pub var seed: u64 = undefined;
pub var tick_count: u64 = 0;
pub var io: std.Io = undefined;
/// Per-user data dir (ae.Core.paths.Dirs.data). world.dat is rooted here
/// so Finder-launched `.app` bundles and other read-only install layouts
/// don't try to write into CWD.
pub var data_dir: std.Io.Dir = undefined;
var save_counter: u32 = 0;

/// For each (x,z) column, stores Y+1 of the highest light-blocking block.
/// A value of 0 means the entire column is sunlit. Consumed by
/// `is_sunlit` and tree/grass growth checks, so it describes a light
/// occlusion map rather than a height/elevation map.
pub var light_map: [c.WorldLength * c.WorldDepth]u8 = undefined;

const BLOCK_SIZE = 32768;
/// File header: 3 little-endian u16 (x, y, z), 1 little-endian u64 (seed), then raw block data.
pub fn save() !void {
    if (!owned_locally) return;
    const file = data_dir.createFile(io, "world.dat", .{}) catch |err| {
        log.err("Failed to create world.dat: {}", .{err});
        return err;
    };
    defer file.close(io);

    var write_buf: [BLOCK_SIZE]u8 = undefined;
    var writer = file.writer(io, &write_buf);

    const start = std.Io.Clock.Timestamp.now(io, .boot);
    try writer.interface.writeSliceEndian(u16, &world_size, .little);
    const seed_arr = [1]u64{seed};
    try writer.interface.writeSliceEndian(u64, &seed_arr, .little);
    const tick_arr = [1]u64{tick_count};
    try writer.interface.writeSliceEndian(u64, &tick_arr, .little);
    try writer.interface.writeAll(raw_blocks[0..4]);
    try write_blocks_yzx(&writer.interface);
    try writer.interface.flush();
    const end = std.Io.Clock.Timestamp.now(io, .boot);

    const total_bytes: u64 = 6 + 8 + 8 + 4 +
        @as(u64, c.WorldLength) * @as(u64, c.WorldDepth) * @as(u64, c.WorldHeight);
    const elapsed_ns: i64 = @truncate(end.raw.nanoseconds - start.raw.nanoseconds);
    const elapsed_us: i64 = @max(1, @divTrunc(elapsed_ns, std.time.ns_per_us));
    const mib_per_s: u64 = (total_bytes * std.time.us_per_s) /
        (@as(u64, @intCast(elapsed_us)) * 1024 * 1024);
    log.info("Saved world to world.dat ({d} bytes in {d}us, {d} MiB/s)", .{
        total_bytes, elapsed_us, mib_per_s,
    });
}

pub fn load() bool {
    const file = data_dir.openFile(io, "world.dat", .{}) catch {
        return false;
    };
    defer file.close(io);

    var read_buf: [BLOCK_SIZE]u8 = undefined;
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
    var saved_tick: [1]u64 = undefined;
    reader.interface.readSliceEndian(u64, &saved_tick, .little) catch return false;
    reader.interface.readSliceAll(raw_blocks[0..4]) catch return false;
    read_blocks_yzx(&reader.interface) catch return false;

    world_size = dims;
    seed = saved_seed[0];
    tick_count = saved_tick[0];
    log.info("Loaded world from world.dat", .{});
    return true;
}

/// Allocate tick wheel, bitmap, and `raw_blocks` without populating the
/// world. Used both by the full singleplayer init (which then generates or
/// loads and flips `owned_locally` to true) and by the multiplayer client
/// (which fills `blocks` via the level-data-chunk decompression path and
/// leaves `owned_locally` false so save/autosave paths are suppressed).
pub fn init_empty(allocator: std.mem.Allocator, _io: std.Io, _data_dir: std.Io.Dir, new_seed: u64) !void {
    backing_allocator = allocator;
    io = _io;
    data_dir = _data_dir;
    owned_locally = false;

    node_pool = try allocator.alloc(WheelNode, POOL_CAPACITY);
    // Build free list: each node points to the next, last points to SENTINEL
    for (0..POOL_CAPACITY) |i| {
        node_pool[i] = .{
            .loc = .{ .x = 0, .z = 0, .y = 0 },
            .next = if (i + 1 < POOL_CAPACITY) @intCast(i + 1) else SENTINEL,
        };
    }
    free_head = 0;
    pool_used = 0;
    pool_used_peak = 0;
    @memset(&wheel_buckets, SENTINEL);
    try enqueued.ensureTotalCapacityPrecise(allocator, POOL_CAPACITY);

    raw_blocks = try allocator.alloc(u8, c.WorldDepth * c.WorldHeight * c.WorldLength + 4);
    blocks = @ptrCast(raw_blocks[4..]);

    world_size = .{ c.WorldLength, c.WorldHeight, c.WorldDepth };
    @memset(raw_blocks, 0x00);
    @memset(&chunk_counts, 0);
    @memset(&chunk_non_opaque, 0);

    const size: u32 = c.WorldDepth * c.WorldHeight * c.WorldLength;
    std.mem.writeInt(u32, raw_blocks[0..4], size, .big);

    rng = Xorshift64.init(new_seed);
    seed = new_seed;

    load_status = .loading;
}

/// Compute the sunlight height map and mark the world as fully loaded.
/// Called by both the SP generate/load path and the MP download path once
/// `blocks` is populated.
pub fn finalize_loaded() void {
    compute_chunk_counts();
    compute_light_map();
    load_status = .complete;
    log.info("World seed: {d}", .{seed});
}

/// Scan each 4 KiB chunk and count non-air / non-opaque blocks. Called once
/// after generation or load; maintained incrementally by set_block thereafter.
fn compute_chunk_counts() void {
    for (0..CHUNK_COUNT) |ci| {
        const base = ci * c.ChunkVolume;
        var non_air: u16 = 0;
        var non_opq: u16 = 0;
        for (blocks[base..][0..c.ChunkVolume]) |b| {
            if (b.id != .air) non_air += 1;
            if (!mesh_props(b).@"opaque") non_opq += 1;
        }
        chunk_counts[ci] = non_air;
        chunk_non_opaque[ci] = non_opq;
    }
}

pub fn init(allocator: std.mem.Allocator, scratch: std.mem.Allocator, _io: std.Io, _data_dir: std.Io.Dir, new_seed: u64) !void {
    try init_empty(allocator, _io, _data_dir, new_seed);
    // Singleplayer owns its world and is allowed to persist it to disk.
    // This must happen before `load()` so the read side can be symmetric
    // later if we ever guard reads too.
    owned_locally = true;

    // Let loadscreen catch up
    try io.sleep(.fromMilliseconds(250), .real);

    if (!load()) {
        seed = new_seed;
        const worldgen = @import("worldgen.zig");
        load_status = .{ .generating = .raising };
        const start = std.Io.Clock.Timestamp.now(io, .boot);
        try worldgen.generate(scratch, blocks, seed, io, &load_status.generating);
        const end = std.Io.Clock.Timestamp.now(io, .boot);
        const elapsed_ns: i64 = @truncate(end.raw.nanoseconds - start.raw.nanoseconds);
        const elapsed_ms = @divTrunc(elapsed_ns, std.time.ns_per_ms);
        log.info("World generation took {d}ms", .{elapsed_ms});
        save() catch |err| {
            log.err("failed to save world: {}", .{err});
        };
    }
    finalize_loaded();
}

pub fn deinit() void {
    save() catch |err| {
        log.err("failed to save world: {}", .{err});
    };

    log.info("world update wheel peak: {d}/{d}", .{ pool_used_peak, POOL_CAPACITY });

    backing_allocator.free(raw_blocks);
    backing_allocator.free(node_pool);
    enqueued.deinit(backing_allocator);
    raw_blocks = undefined;
    node_pool = undefined;
    enqueued = .empty;
    blocks = undefined;
    world_size = undefined;
    seed = undefined;
    backing_allocator = undefined;
}

fn get_index(x: u16, y: u16, z: u16) u32 {
    assert(x < c.WorldLength);
    assert(y < c.WorldHeight);
    assert(z < c.WorldDepth);
    return c.block_index(@as(u32, x), @as(u32, y), @as(u32, z));
}

pub fn get_block(x: u16, y: u16, z: u16) Block {
    const idx = get_index(x, y, z);
    return blocks[idx];
}

/// Pointer to ChunkSize contiguous blocks at chunk-aligned x.
/// In the chunk-aware layout, blocks at (x..x+15, y, z) are contiguous,
/// so callers can avoid per-block index computation in tight loops.
pub fn get_chunk_row(x: u16, y: u16, z: u16) *const [c.ChunkSize]Block {
    assert(x % c.ChunkSize == 0);
    const base = get_index(x, y, z);
    return blocks[base..][0..c.ChunkSize];
}

/// Pointer to an entire 16x16x16 chunk (4 KiB). Index within the chunk
/// with `(ly * ChunkSize + lz) * ChunkSize + lx` -- the same 4-op
/// arithmetic as the old contiguous formula.
pub fn get_chunk_ptr(chunk_cx: u32, chunk_cy: u32, chunk_cz: u32) *const [c.ChunkVolume]Block {
    const ci = (chunk_cy * c.ChunksZ + chunk_cz) * c.ChunksX + chunk_cx;
    return blocks[ci * c.ChunkVolume ..][0..c.ChunkVolume];
}

pub fn set_block(x: u16, y: u16, z: u16, block: Block) void {
    const idx = get_index(x, y, z);
    const old = blocks[idx];
    blocks[idx] = block;

    // Maintain per-chunk counts for work-skipping.
    const ci = chunk_idx(x, y, z);
    if (old.id == .air and block.id != .air) {
        chunk_counts[ci] += 1;
    } else if (old.id != .air and block.id == .air) {
        chunk_counts[ci] -= 1;
    }
    const old_opq = mesh_props(old).@"opaque";
    const new_opq = mesh_props(block).@"opaque";
    if (old_opq and !new_opq) {
        chunk_non_opaque[ci] += 1;
    } else if (!old_opq and new_opq) {
        chunk_non_opaque[ci] -= 1;
    }

    update_height_column(x, y, z, block);
    // The enqueue dedup set is keyed by location, not block type. If the
    // block at this loc was previously something with a slow tick (e.g.
    // dirt/grass at 100-999 ticks) and is now something fast (water/lava
    // at 4 ticks), a stale entry would prevent try_enqueue from scheduling
    // the new block at its faster delay until the slow timer eventually
    // fires (5-50s later). Clearing here lets the next neighbor pass insert
    // at the correct delay; any orphan wheel entry just no-ops when it
    // finally fires because process_block_update re-reads the block.
    enqueued_remove(idx);
}

pub fn is_chunk_all_air(cx: u32, cy: u32, cz: u32) bool {
    return chunk_counts[(cy * c.ChunksZ + cz) * c.ChunksX + cx] == 0;
}

pub fn is_chunk_all_opaque(cx: u32, cy: u32, cz: u32) bool {
    return chunk_non_opaque[(cy * c.ChunksZ + cz) * c.ChunksX + cx] == 0;
}

fn chunk_idx(x: u16, y: u16, z: u16) u32 {
    return (@as(u32, y) / c.ChunkSize * c.ChunksZ + @as(u32, z) / c.ChunkSize) * c.ChunksX + @as(u32, x) / c.ChunkSize;
}

// -- Protocol-order serialization (contiguous YZX for Java Classic compat) ----

/// Write all blocks in contiguous YZX wire order from chunk-aware memory.
/// Within each (y,z) row, the 16 x-values per chunk are contiguous in the
/// chunk-aware layout, so each inner iteration is a 16-byte slice copy.
pub fn write_blocks_yzx(writer: *std.Io.Writer) !void {
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

/// Read contiguous YZX wire-order data and scatter into chunk-aware positions.
pub fn read_blocks_yzx(reader: *std.Io.Reader) !void {
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

// -- Sunlight height map ------------------------------------------------------

/// Scan a single column top-down; return Y+1 of highest light-blocking block (0 if none).
fn column_height(x: u16, z: u16) u8 {
    var y: u16 = c.WorldHeight;
    while (y > 0) {
        y -= 1;
        const blk = get_block(x, y, z);
        if (!sim_props(blk).light_passes) {
            return @intCast(y + 1);
        }
    }
    return 0;
}

/// Build the full light map. Called once after generation or load.
pub fn compute_light_map() void {
    for (0..c.WorldDepth) |z| {
        for (0..c.WorldLength) |x| {
            light_map[z * c.WorldLength + x] = column_height(
                @intCast(x),
                @intCast(z),
            );
        }
    }
}

/// O(1) sunlight query: true if no light-blocking block exists above (x,y,z).
pub fn is_sunlit(x: u16, y: u16, z: u16) bool {
    return y + 1 >= light_map[@as(u32, z) * c.WorldLength + x];
}

/// True when sunlight cannot pass through this block type.
pub fn blocks_light(block: Block) bool {
    return !sim_props(block).light_passes;
}

/// Incrementally update height map after a block change at (x,y,z).
fn update_height_column(x: u16, y: u16, z: u16, block: Block) void {
    const col_idx: u32 = @as(u32, z) * c.WorldLength + x;
    const cur = light_map[col_idx];
    const is_blocker = blocks_light(block);

    if (is_blocker) {
        const new_h: u8 = @intCast(y + 1);
        if (new_h > cur) light_map[col_idx] = new_h;
    } else if (y + 1 >= cur) {
        // Removed the top blocker; rescan
        light_map[col_idx] = column_height(x, z);
    }
}

pub fn find_spawn() [3]u16 {
    const spawn_seed: u64 = @truncate(@as(u96, @bitCast(std.Io.Clock.Timestamp.now(io, .boot).raw.nanoseconds)));
    var spawn_rng = Xorshift64.init(spawn_seed);
    for (0..10) |attempt| {
        const bx: u16 = @intCast(spawn_rng.next_bounded(c.WorldLength));
        const bz: u16 = @intCast(spawn_rng.next_bounded(c.WorldDepth));
        // Walk down from top to find surface
        var by: u16 = c.WorldHeight - 1;
        while (by > 0) : (by -= 1) {
            const blk = get_block(bx, by, bz);
            if (blk.id != .air and blk.id != .flowing_water and blk.id != .still_water and
                blk.id != .flowing_lava and blk.id != .still_lava)
            {
                // Found solid ground; spawn one block above
                const above: Block = if (by + 1 < c.WorldHeight) get_block(bx, by + 1, bz) else .{ .id = .air };
                const in_fluid = above.id == .still_water or above.id == .flowing_water or
                    above.id == .still_lava or above.id == .flowing_lava;
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
        if (blk.id != .air and blk.id != .flowing_water and blk.id != .still_water and
            blk.id != .flowing_lava and blk.id != .still_lava)
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
    pending_count = 0;

    const slot = @as(u32, @intCast(tick_count & WHEEL_MASK));
    var node_idx = wheel_buckets[slot];
    wheel_buckets[slot] = SENTINEL;

    while (node_idx != SENTINEL) {
        const node = node_pool[node_idx];
        const next = node.next;
        // Return node to free list
        node_pool[node_idx].next = free_head;
        free_head = node_idx;
        pool_used -= 1;

        process_block_update(node.loc);
        node_idx = next;
    }

    tick_count +%= 1;
    if (autosave_enabled) {
        save_counter += 1;
        if (save_counter >= 6000) {
            save_counter = 0;
            save() catch |err| {
                log.err("failed to save world: {}", .{err});
            };
        }
    }
}

fn process_block_update(loc: Location) void {
    enqueued_remove(loc.to_index());
    const x: u16 = loc.x;
    const y: u16 = loc.y;
    const z: u16 = loc.z;
    const block = get_block(x, y, z);

    if ((block.id == .sand or block.id == .gravel) and y > 0) {
        const below = get_block(x, y - 1, z);
        if (below.id == .air or below.id == .flowing_water or below.id == .still_water or
            below.id == .flowing_lava or below.id == .still_lava)
        {
            queue_block_change(x, y, z, .{ .id = .air });
            queue_block_change(x, y - 1, z, block);
        }
    } else if (block.id == .dirt and has_direct_sunlight(x, y, z)) {
        queue_block_change(x, y, z, .{ .id = .grass });
    } else if (block.id == .grass and !has_direct_sunlight(x, y, z)) {
        queue_block_change(x, y, z, .{ .id = .dirt });
    } else if (block.id == .sapling and has_direct_sunlight(x, y, z)) {
        const height: u32 = rng.next_bounded(3) + 4;
        grow_tree(x, y, z, height);
    } else if ((block.id == .sapling or block.id == .flower_1 or block.id == .flower_2) and
        !has_direct_sunlight(x, y, z))
    {
        queue_block_change(x, y, z, .{ .id = .air });
    } else if ((block.id == .mushroom_1 or block.id == .mushroom_2) and
        has_direct_sunlight(x, y, z))
    {
        queue_block_change(x, y, z, .{ .id = .air });
    } else if (is_water(block) or is_lava(block)) {
        process_fluid(x, y, z, block);
    }
}

// -- Timer wheel operations ------------------------------------------------

fn wheel_insert(loc: Location, delay: u32) void {
    assert(delay < WHEEL_SIZE);
    assert(free_head != SENTINEL); // pool not exhausted
    const node_idx = free_head;
    free_head = node_pool[node_idx].next;
    pool_used += 1;
    if (pool_used > pool_used_peak) pool_used_peak = pool_used;

    const slot = @as(u32, @intCast((tick_count +% delay) & WHEEL_MASK));
    node_pool[node_idx] = .{ .loc = loc, .next = wheel_buckets[slot] };
    wheel_buckets[slot] = node_idx;
}

/// Enqueue a block and its 6 face neighbors for deferred update.
pub fn enqueue_neighbors_of(x: u16, y: u16, z: u16) void {
    try_enqueue(x, y, z);
    if (x > 0) try_enqueue(x - 1, y, z);
    if (x + 1 < c.WorldLength) try_enqueue(x + 1, y, z);
    if (y > 0) try_enqueue(x, y - 1, z);
    if (y + 1 < c.WorldHeight) try_enqueue(x, y + 1, z);
    if (z > 0) try_enqueue(x, y, z - 1);
    if (z + 1 < c.WorldDepth) try_enqueue(x, y, z + 1);
}

/// Tick delay per block type: fluids and gravity use 4 ticks, vegetation is random.
fn tick_delay(block: Block) u32 {
    if (sim_props(block).fast_tick) return 4;
    return rng.next_bounded(900) + 100;
}

fn try_enqueue(x: u16, y: u16, z: u16) void {
    const block = get_block(x, y, z);
    if (!sim_props(block).ticks) return;
    const idx = get_index(x, y, z);
    if (std.mem.indexOfScalar(u32, enqueued.items, idx) != null) return;
    if (free_head == SENTINEL or enqueued.items.len >= POOL_CAPACITY) {
        log.warn("world update dropped: wheel full (pool_used={d})", .{pool_used});
        return;
    }
    enqueued.appendAssumeCapacity(idx);
    const loc: Location = .{ .x = @intCast(x), .z = @intCast(z), .y = @intCast(y) };
    wheel_insert(loc, tick_delay(block));
}

fn enqueued_remove(idx: u32) void {
    if (std.mem.indexOfScalar(u32, enqueued.items, idx)) |i| {
        _ = enqueued.swapRemove(i);
    }
}

fn has_direct_sunlight(x: u16, y: u16, z: u16) bool {
    var check_y: u16 = y + 1;
    while (check_y < c.WorldHeight) : (check_y += 1) {
        const blk = get_block(x, check_y, z);
        if (!sim_props(blk).light_passes) return false;
    }
    return true;
}

// -- Fluid physics ---------------------------------------------------------

fn is_water(block: Block) bool {
    return BlockRegistry.global.fluid_kind[@intFromEnum(block.id)] == .water;
}

fn is_lava(block: Block) bool {
    return BlockRegistry.global.fluid_kind[@intFromEnum(block.id)] == .lava;
}

fn process_fluid(x: u16, y: u16, z: u16, block: Block) void {
    const water = is_water(block);
    const flow: Block = if (water) .{ .id = .flowing_water } else .{ .id = .flowing_lava };

    // Water converts adjacent lava to stone; lava adjacent to water becomes stone
    if (check_lava_water(x, y, z, water)) return;

    // Flowing blocks without a fluid neighbor vanish
    if ((block.id == .flowing_water or block.id == .flowing_lava) and
        !has_fluid_neighbor(x, y, z, water))
    {
        queue_block_change(x, y, z, .{ .id = .air });
        return;
    }

    // Spread down
    if (y > 0 and get_block(x, y - 1, z).id == .air) {
        if (!water or !is_near_sponge(x, y - 1, z)) {
            queue_block_change(x, y - 1, z, flow);
            return;
        }
    }

    // Spread horizontal (only when no downward spread)
    spread_horizontal(x, y, z, flow, water);
}

/// Returns true if the current block was consumed (lava turned to stone).
fn check_lava_water(x: u16, y: u16, z: u16, water: bool) bool {
    if (water) {
        if (x > 0 and is_lava(get_block(x - 1, y, z))) queue_block_change(x - 1, y, z, .{ .id = .stone });
        if (x + 1 < c.WorldLength and is_lava(get_block(x + 1, y, z))) queue_block_change(x + 1, y, z, .{ .id = .stone });
        if (y > 0 and is_lava(get_block(x, y - 1, z))) queue_block_change(x, y - 1, z, .{ .id = .stone });
        if (y + 1 < c.WorldHeight and is_lava(get_block(x, y + 1, z))) queue_block_change(x, y + 1, z, .{ .id = .stone });
        if (z > 0 and is_lava(get_block(x, y, z - 1))) queue_block_change(x, y, z - 1, .{ .id = .stone });
        if (z + 1 < c.WorldDepth and is_lava(get_block(x, y, z + 1))) queue_block_change(x, y, z + 1, .{ .id = .stone });
        return false;
    } else {
        if ((x > 0 and is_water(get_block(x - 1, y, z))) or
            (x + 1 < c.WorldLength and is_water(get_block(x + 1, y, z))) or
            (y > 0 and is_water(get_block(x, y - 1, z))) or
            (y + 1 < c.WorldHeight and is_water(get_block(x, y + 1, z))) or
            (z > 0 and is_water(get_block(x, y, z - 1))) or
            (z + 1 < c.WorldDepth and is_water(get_block(x, y, z + 1))))
        {
            queue_block_change(x, y, z, .{ .id = .stone });
            return true;
        }
        return false;
    }
}

fn has_fluid_neighbor(x: u16, y: u16, z: u16, water: bool) bool {
    if (x > 0 and is_same_fluid(get_block(x - 1, y, z), water)) return true;
    if (x + 1 < c.WorldLength and is_same_fluid(get_block(x + 1, y, z), water)) return true;
    if (y > 0 and is_same_fluid(get_block(x, y - 1, z), water)) return true;
    if (y + 1 < c.WorldHeight and is_same_fluid(get_block(x, y + 1, z), water)) return true;
    if (z > 0 and is_same_fluid(get_block(x, y, z - 1), water)) return true;
    if (z + 1 < c.WorldDepth and is_same_fluid(get_block(x, y, z + 1), water)) return true;
    return false;
}

fn is_same_fluid(block: Block, water: bool) bool {
    return if (water) is_water(block) else is_lava(block);
}

fn spread_horizontal(x: u16, y: u16, z: u16, flow: Block, water: bool) void {
    if (x > 0 and get_block(x - 1, y, z).id == .air and (!water or !is_near_sponge(x - 1, y, z)))
        queue_block_change(x - 1, y, z, flow);
    if (x + 1 < c.WorldLength and get_block(x + 1, y, z).id == .air and (!water or !is_near_sponge(x + 1, y, z)))
        queue_block_change(x + 1, y, z, flow);
    if (z > 0 and get_block(x, y, z - 1).id == .air and (!water or !is_near_sponge(x, y, z - 1)))
        queue_block_change(x, y, z - 1, flow);
    if (z + 1 < c.WorldDepth and get_block(x, y, z + 1).id == .air and (!water or !is_near_sponge(x, y, z + 1)))
        queue_block_change(x, y, z + 1, flow);
}

/// Called when a sponge is placed: absorb all water in a 5x5x5 cube.
pub fn sponge_absorb(cx: u16, cy: u16, cz: u16) void {
    var dx: i32 = -2;
    while (dx <= 2) : (dx += 1) {
        var dy: i32 = -2;
        while (dy <= 2) : (dy += 1) {
            var dz: i32 = -2;
            while (dz <= 2) : (dz += 1) {
                const nx = @as(i32, cx) + dx;
                const ny = @as(i32, cy) + dy;
                const nz = @as(i32, cz) + dz;
                if (nx < 0 or nx >= c.WorldLength or ny < 0 or ny >= c.WorldHeight or nz < 0 or nz >= c.WorldDepth) continue;
                const ux: u16 = @intCast(nx);
                const uy: u16 = @intCast(ny);
                const uz: u16 = @intCast(nz);
                const blk = get_block(ux, uy, uz);
                if (blk.id == .flowing_water or blk.id == .still_water) {
                    set_block(ux, uy, uz, .{ .id = .air });
                    Server.broadcast_block_change(ux, uy, uz, .{ .id = .air });
                    enqueue_neighbors_of(ux, uy, uz);
                }
            }
        }
    }
}

const SPONGE_RADIUS: i32 = 2;

/// Called when a sponge is destroyed: enqueue neighbors in a radius to re-evaluate water flow.
pub fn sponge_release(cx: u16, cy: u16, cz: u16) void {
    var dx: i32 = -SPONGE_RADIUS;
    while (dx <= SPONGE_RADIUS) : (dx += 1) {
        var dy: i32 = -SPONGE_RADIUS;
        while (dy <= SPONGE_RADIUS) : (dy += 1) {
            var dz: i32 = -SPONGE_RADIUS;
            while (dz <= SPONGE_RADIUS) : (dz += 1) {
                const nx = @as(i32, cx) + dx;
                const ny = @as(i32, cy) + dy;
                const nz = @as(i32, cz) + dz;
                if (nx < 0 or nx >= c.WorldLength or ny < 0 or ny >= c.WorldHeight or nz < 0 or nz >= c.WorldDepth) continue;
                enqueue_neighbors_of(@intCast(nx), @intCast(ny), @intCast(nz));
            }
        }
    }
}

fn is_near_sponge(x: u16, y: u16, z: u16) bool {
    var dx: i32 = -2;
    while (dx <= 2) : (dx += 1) {
        var dy: i32 = -2;
        while (dy <= 2) : (dy += 1) {
            var dz: i32 = -2;
            while (dz <= 2) : (dz += 1) {
                const nx = @as(i32, x) + dx;
                const ny = @as(i32, y) + dy;
                const nz = @as(i32, z) + dz;
                if (nx < 0 or nx >= c.WorldLength or ny < 0 or ny >= c.WorldHeight or nz < 0 or nz >= c.WorldDepth) continue;
                if (get_block(@intCast(nx), @intCast(ny), @intCast(nz)).id == .sponge) return true;
            }
        }
    }
    return false;
}

fn queue_block_change(x: u16, y: u16, z: u16, block: Block) void {
    assert(pending_count < MAX_PENDING_CHANGES);
    set_block(x, y, z, block);
    pending_changes[pending_count] = .{ .x = x, .y = y, .z = z, .block = block };
    pending_count += 1;
    enqueue_neighbors_of(x, y, z);
}

/// Grow a tree at sapling position (x, y, z). Trunk replaces the sapling
/// and extends upward for `height` blocks total. Leaves surround the top.
fn grow_tree(x: u16, y: u16, z: u16, height: u32) void {
    if (y == 0) return;
    const base_y: u32 = @as(u32, y) - 1;
    if (base_y + height + 2 >= c.WorldHeight) return;

    // Check space above sapling
    var check_y: u32 = @as(u32, y) + 1;
    while (check_y <= base_y + height + 2) : (check_y += 1) {
        if (check_y >= c.WorldHeight) return;
        if (get_block(x, @intCast(check_y), z).id != .air) return;
    }

    // Trunk
    for (0..height) |i| {
        const ty: u32 = base_y + 1 + @as(u32, @intCast(i));
        if (ty < c.WorldHeight) queue_block_change(x, @intCast(ty), z, .{ .id = .log });
    }

    grow_tree_leaves(x, base_y, z, height);
}

fn grow_tree_leaves(x: u16, base_y: u32, z: u16, height: u32) void {
    for (0..4) |layer| {
        const ly: u32 = base_y + height - 2 + @as(u32, @intCast(layer));
        if (ly >= c.WorldHeight) continue;
        const r: i32 = if (layer < 2) 2 else 1;
        var dx: i32 = -r;
        while (dx <= r) : (dx += 1) {
            var dz: i32 = -r;
            while (dz <= r) : (dz += 1) {
                if (dx == 0 and dz == 0 and layer < 2) continue;
                if (@abs(dx) == r and @abs(dz) == r) {
                    if (layer == 3 or rng.next_bounded(2) == 0) continue;
                }
                const lx = @as(i32, @intCast(x)) + dx;
                const lz = @as(i32, @intCast(z)) + dz;
                if (lx < 0 or lx >= c.WorldLength or lz < 0 or lz >= c.WorldDepth) continue;
                const ux: u16 = @intCast(lx);
                const uz: u16 = @intCast(lz);
                if (get_block(ux, @intCast(ly), uz).id == .air) {
                    queue_block_change(ux, @intCast(ly), uz, .{ .id = .leaves });
                }
            }
        }
    }
}
