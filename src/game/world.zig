const std = @import("std");
const c = @import("common").consts;
const Xorshift64 = @import("common").xorshift64.Xorshift64;
const assert = std.debug.assert;

const Server = @import("server.zig");
const log = std.log.scoped(.world);

const B = c.Block;
const Location = c.Location;

/// Comptime lookup: true means sunlight passes through this block.
const light_passes = blk: {
    var table: [50]bool = @splat(false);
    table[B.Air] = true;
    table[B.Sapling] = true;
    table[B.Leaves] = true;
    table[B.Glass] = true;
    table[B.Flower1] = true;
    table[B.Flower2] = true;
    table[B.Mushroom1] = true;
    table[B.Mushroom2] = true;
    break :blk table;
};

pub const BlockChange = struct {
    x: u16,
    y: u16,
    z: u16,
    block: u8,
};

const MAX_PENDING_CHANGES: u32 = 512;
pub var pending_changes: [MAX_PENDING_CHANGES]BlockChange = undefined;
pub var pending_count: u32 = 0;

// -- Timer wheel -----------------------------------------------------------
// 1024 buckets (one per tick modulo WHEEL_SIZE). Each bucket is a singly-
// linked list threaded through a pool of fixed-size nodes. Entries land in
// bucket[ready_tick % WHEEL_SIZE] so only the current tick's bucket is
// drained each tick — no dequeue-decrement-reenqueue of deferred entries.
const WHEEL_SIZE: u32 = 1024;
const WHEEL_MASK: u32 = WHEEL_SIZE - 1;
const POOL_CAPACITY: u32 = 1 << 18; // 262144 nodes

const SENTINEL: u32 = std.math.maxInt(u32);

const WheelNode = packed struct(u64) {
    loc: Location,
    next: u32, // index into node pool, SENTINEL = end-of-list
};

var wheel_buckets: [WHEEL_SIZE]u32 = @splat(SENTINEL); // head index per bucket
var node_pool: []WheelNode = undefined;
var free_head: u32 = 0; // head of the free list
var pool_used: u32 = 0; // high-water count for diagnostics
var rng: Xorshift64 = .{ .state = 1 };

// -- Deduplication bitmap (1 bit per block = 512 KiB) ----------------------
const BLOCK_COUNT: u32 = c.WorldLength * c.WorldHeight * c.WorldDepth;
var enqueued_bitmap: []u8 = undefined;

pub var backing_allocator: std.mem.Allocator = undefined;
pub var raw_blocks: []u8 = undefined;
pub var blocks: []u8 = undefined;
pub var world_size: [3]u16 = undefined;
pub var seed: u64 = undefined;
pub var tick_count: u64 = 0;
pub var io: std.Io = undefined;
var save_counter: u32 = 0;

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
    const tick_arr = [1]u64{tick_count};
    try writer.interface.writeSliceEndian(u64, &tick_arr, .little);
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
    var saved_tick: [1]u64 = undefined;
    reader.interface.readSliceEndian(u64, &saved_tick, .little) catch return false;
    reader.interface.readSliceAll(raw_blocks) catch return false;

    world_size = dims;
    seed = saved_seed[0];
    tick_count = saved_tick[0];
    log.info("Loaded world from world.dat", .{});
    return true;
}

pub fn init(allocator: std.mem.Allocator, scratch: std.mem.Allocator, _io: std.Io, new_seed: u64) !void {
    backing_allocator = allocator;
    io = _io;

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
    @memset(&wheel_buckets, SENTINEL);
    enqueued_bitmap = try allocator.alloc(u8, BLOCK_COUNT / 8);
    @memset(enqueued_bitmap, 0);

    raw_blocks = try allocator.alloc(u8, c.WorldDepth * c.WorldHeight * c.WorldLength + 4);
    blocks = raw_blocks[4..];

    world_size = .{ c.WorldLength, c.WorldHeight, c.WorldDepth };
    @memset(raw_blocks, 0x00);

    const size: u32 = c.WorldDepth * c.WorldHeight * c.WorldLength;
    std.mem.writeInt(u32, raw_blocks[0..4], size, .big);

    rng = Xorshift64.init(new_seed);

    if (!load()) {
        seed = new_seed;
        const worldgen = @import("worldgen.zig");
        const start = std.Io.Clock.Timestamp.now(io, .boot);
        try worldgen.generate(scratch, blocks, seed, io);
        const end = std.Io.Clock.Timestamp.now(io, .boot);
        const elapsed_ns: i64 = @truncate(end.raw.nanoseconds - start.raw.nanoseconds);
        const elapsed_ms = @divTrunc(elapsed_ns, std.time.ns_per_ms);
        log.info("World generation took {d}ms", .{elapsed_ms});
    }
    log.info("World seed: {d}", .{seed});
}

pub fn deinit() void {
    save() catch {};

    backing_allocator.free(raw_blocks);
    backing_allocator.free(node_pool);
    backing_allocator.free(enqueued_bitmap);
    raw_blocks = undefined;
    node_pool = undefined;
    enqueued_bitmap = undefined;
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
    const spawn_seed: u64 = @truncate(@as(u96, @bitCast(std.Io.Clock.Timestamp.now(io, .boot).raw.nanoseconds)));
    var spawn_rng = Xorshift64.init(spawn_seed);
    for (0..10) |attempt| {
        const bx: u16 = @intCast(spawn_rng.next_bounded(c.WorldLength));
        const bz: u16 = @intCast(spawn_rng.next_bounded(c.WorldDepth));
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
    save_counter += 1;
    if (save_counter >= 6000) {
        save_counter = 0;
        save() catch {};
    }
}

fn process_block_update(loc: Location) void {
    bitmap_clear(loc.to_index());
    const x: u16 = loc.x;
    const y: u16 = loc.y;
    const z: u16 = loc.z;
    const block = get_block(x, y, z);

    if ((block == B.Sand or block == B.Gravel) and y > 0) {
        const below = get_block(x, y - 1, z);
        if (below == B.Air or below == B.Flowing_Water or below == B.Still_Water or
            below == B.Flowing_Lava or below == B.Still_Lava)
        {
            queue_block_change(x, y, z, B.Air);
            queue_block_change(x, y - 1, z, block);
        }
    } else if (block == B.Dirt and has_direct_sunlight(x, y, z)) {
        queue_block_change(x, y, z, B.Grass);
    } else if (block == B.Grass and !has_direct_sunlight(x, y, z)) {
        queue_block_change(x, y, z, B.Dirt);
    } else if (block == B.Sapling and has_direct_sunlight(x, y, z)) {
        const height: u32 = rng.next_bounded(3) + 4;
        grow_tree(x, y, z, height);
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

/// Comptime lookup: true means this block type has update behavior.
const has_behavior = blk: {
    var table: [50]bool = @splat(false);
    table[B.Dirt] = true;
    table[B.Grass] = true;
    table[B.Sapling] = true;
    table[B.Sand] = true;
    table[B.Gravel] = true;
    table[B.Flowing_Water] = true;
    table[B.Still_Water] = true;
    table[B.Flowing_Lava] = true;
    table[B.Still_Lava] = true;
    break :blk table;
};

/// Tick delay per block type: fluids and gravity use 4 ticks, vegetation is random.
fn tick_delay(block: u8) u32 {
    if (block == B.Sand or block == B.Gravel or is_water(block) or is_lava(block)) return 4;
    return rng.next_bounded(900) + 100;
}

fn try_enqueue(x: u16, y: u16, z: u16) void {
    const block = get_block(x, y, z);
    if (block >= has_behavior.len or !has_behavior[block]) return;
    const idx = get_index(x, y, z);
    if (bitmap_test(idx)) return;
    if (free_head == SENTINEL) return; // pool exhausted, drop update
    bitmap_set(idx);
    const loc: Location = .{ .x = @intCast(x), .z = @intCast(z), .y = @intCast(y) };
    wheel_insert(loc, tick_delay(block));
}

fn bitmap_test(idx: u32) bool {
    return (enqueued_bitmap[idx / 8] & (@as(u8, 1) << @as(u3, @intCast(idx % 8)))) != 0;
}

fn bitmap_set(idx: u32) void {
    enqueued_bitmap[idx / 8] |= @as(u8, 1) << @as(u3, @intCast(idx % 8));
}

fn bitmap_clear(idx: u32) void {
    enqueued_bitmap[idx / 8] &= ~(@as(u8, 1) << @as(u3, @intCast(idx % 8)));
}

fn has_direct_sunlight(x: u16, y: u16, z: u16) bool {
    var check_y: u16 = y + 1;
    while (check_y < c.WorldHeight) : (check_y += 1) {
        const blk = get_block(x, check_y, z);
        if (blk >= light_passes.len or !light_passes[blk]) return false;
    }
    return true;
}

// -- Fluid physics ---------------------------------------------------------

fn is_water(block: u8) bool {
    return block == B.Flowing_Water or block == B.Still_Water;
}

fn is_lava(block: u8) bool {
    return block == B.Flowing_Lava or block == B.Still_Lava;
}

fn process_fluid(x: u16, y: u16, z: u16, block: u8) void {
    const water = is_water(block);
    const flow: u8 = if (water) B.Flowing_Water else B.Flowing_Lava;

    // Water converts adjacent lava to stone; lava adjacent to water becomes stone
    if (check_lava_water(x, y, z, water)) return;

    // Flowing blocks without a fluid neighbor vanish
    if ((block == B.Flowing_Water or block == B.Flowing_Lava) and
        !has_fluid_neighbor(x, y, z, water))
    {
        queue_block_change(x, y, z, B.Air);
        return;
    }

    // Spread down
    if (y > 0 and get_block(x, y - 1, z) == B.Air) {
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
        if (x > 0 and is_lava(get_block(x - 1, y, z))) queue_block_change(x - 1, y, z, B.Stone);
        if (x + 1 < c.WorldLength and is_lava(get_block(x + 1, y, z))) queue_block_change(x + 1, y, z, B.Stone);
        if (y > 0 and is_lava(get_block(x, y - 1, z))) queue_block_change(x, y - 1, z, B.Stone);
        if (y + 1 < c.WorldHeight and is_lava(get_block(x, y + 1, z))) queue_block_change(x, y + 1, z, B.Stone);
        if (z > 0 and is_lava(get_block(x, y, z - 1))) queue_block_change(x, y, z - 1, B.Stone);
        if (z + 1 < c.WorldDepth and is_lava(get_block(x, y, z + 1))) queue_block_change(x, y, z + 1, B.Stone);
        return false;
    } else {
        if ((x > 0 and is_water(get_block(x - 1, y, z))) or
            (x + 1 < c.WorldLength and is_water(get_block(x + 1, y, z))) or
            (y > 0 and is_water(get_block(x, y - 1, z))) or
            (y + 1 < c.WorldHeight and is_water(get_block(x, y + 1, z))) or
            (z > 0 and is_water(get_block(x, y, z - 1))) or
            (z + 1 < c.WorldDepth and is_water(get_block(x, y, z + 1))))
        {
            queue_block_change(x, y, z, B.Stone);
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

fn is_same_fluid(block: u8, water: bool) bool {
    return if (water) is_water(block) else is_lava(block);
}

fn spread_horizontal(x: u16, y: u16, z: u16, flow: u8, water: bool) void {
    if (x > 0 and get_block(x - 1, y, z) == B.Air and (!water or !is_near_sponge(x - 1, y, z)))
        queue_block_change(x - 1, y, z, flow);
    if (x + 1 < c.WorldLength and get_block(x + 1, y, z) == B.Air and (!water or !is_near_sponge(x + 1, y, z)))
        queue_block_change(x + 1, y, z, flow);
    if (z > 0 and get_block(x, y, z - 1) == B.Air and (!water or !is_near_sponge(x, y, z - 1)))
        queue_block_change(x, y, z - 1, flow);
    if (z + 1 < c.WorldDepth and get_block(x, y, z + 1) == B.Air and (!water or !is_near_sponge(x, y, z + 1)))
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
                if (blk == B.Flowing_Water or blk == B.Still_Water) {
                    set_block(ux, uy, uz, B.Air);
                    Server.broadcast_block_change(ux, uy, uz, B.Air);
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
                if (get_block(@intCast(nx), @intCast(ny), @intCast(nz)) == B.Sponge) return true;
            }
        }
    }
    return false;
}

fn queue_block_change(x: u16, y: u16, z: u16, block: u8) void {
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
        if (get_block(x, @intCast(check_y), z) != B.Air) return;
    }

    // Trunk
    for (0..height) |i| {
        const ty: u32 = base_y + 1 + @as(u32, @intCast(i));
        if (ty < c.WorldHeight) queue_block_change(x, @intCast(ty), z, B.Log);
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
                if (get_block(ux, @intCast(ly), uz) == B.Air) {
                    queue_block_change(ux, @intCast(ly), uz, B.Leaves);
                }
            }
        }
    }
}
