// --- WorldSimulation ---
//
// Block physics, fluid spread, vegetation growth, gravity. Owns the timer-
// wheel scheduler, the dedup set, the RNG used for stochastic timing, and
// a streaming change sink for server-visible updates.
//
// Mutates WorldData via `apply_block` from `set_block` / `queue_block_change`.
// `set_block` is the runtime mutation entry point: it does the data write
// AND clears the enqueue dedup so a freshly placed block can re-enqueue at
// the right tick delay. Bulk loaders (worldgen, save load) bypass the
// scheduler and call `WorldData.apply_block` directly.

const std = @import("std");
const common = @import("common");
const c = common.consts;
const assert = std.debug.assert;

const WorldData = @import("WorldData.zig");

const Block = c.Block;
const Location = c.Location;

const log = std.log.scoped(.world);

pub const BlockChange = struct {
    x: u16,
    y: u16,
    z: u16,
    block: Block,
};

/// A non-allocating destination for simulation-driven block changes. The
/// simulation owns world mutation; the sink mirrors that mutation to clients
/// or records it in tests. It must not retain `change` beyond the call.
pub const BlockChangeSink = struct {
    ctx: ?*anyopaque = null,
    emit_fn: *const fn (ctx: ?*anyopaque, change: BlockChange) void,

    pub inline fn emit(self: BlockChangeSink, change: BlockChange) void {
        self.emit_fn(self.ctx, change);
    }
};

/// Bound both client packet bursts and simulation work identically on every
/// target. This is a throughput budget, not storage: changes are streamed to
/// the sink as soon as they are committed.
pub const MAX_BLOCK_CHANGES_PER_TICK: u32 = 2048;
pub const MAX_DUE_UPDATES_PER_TICK: u32 = 2048;

// --- Timer wheel ---
// 1024 buckets (one per tick modulo WHEEL_SIZE). Each bucket is a circular
// singly-linked list threaded through a pool of fixed-size nodes; its table
// entry stores the tail index. Circular lists let a due bucket be appended to
// the carry-over queue in O(1) when a tick hits its work budget.
pub const WHEEL_SIZE: u32 = 1024;
pub const WHEEL_MASK: u32 = WHEEL_SIZE - 1;
pub const POOL_CAPACITY: u32 = 1 << 13; // 8192 nodes

pub const SENTINEL: u32 = std.math.maxInt(u32);

pub const WheelNode = packed struct(u64) {
    loc: Location,
    next: u32, // pool index; free nodes use SENTINEL-terminated chains
};

const WorldSimulation = @This();

wheel_buckets: [WHEEL_SIZE]u32,
/// Tail of due work deferred from a prior tick. Uses the same circular-list
/// representation as wheel_buckets, so no second node pool is needed.
ready_tail: u32,
node_pool: []WheelNode,
free_head: u32,
pool_used: u32,
pool_used_peak: u32,
rng: std.Random.DefaultPrng,

// --- Enqueue dedup (fixed-capacity flat set, linear scan) ---
// At POOL_CAPACITY=8192 entries, a flat u32 array is 32 KiB and every op
// fits in a single SIMD-friendly scan - faster and ~40x smaller than a
// hashmap once the index table and load-factor padding are counted.
// Pre-reserved at init; runtime ops never grow.
enqueued: std.ArrayListUnmanaged(u32),

tick_count: u64,

pub fn init(allocator: std.mem.Allocator, seed: u64) !WorldSimulation {
    var self: WorldSimulation = undefined;
    self.node_pool = try allocator.alloc(WheelNode, POOL_CAPACITY);
    errdefer allocator.free(self.node_pool);
    for (0..POOL_CAPACITY) |i| {
        self.node_pool[i] = .{
            .loc = .{ .x = 0, .z = 0, .y = 0 },
            .next = if (i + 1 < POOL_CAPACITY) @intCast(i + 1) else SENTINEL,
        };
    }
    self.free_head = 0;
    self.pool_used = 0;
    self.pool_used_peak = 0;
    @memset(&self.wheel_buckets, SENTINEL);
    self.ready_tail = SENTINEL;
    self.enqueued = .empty;
    try self.enqueued.ensureTotalCapacityPrecise(allocator, POOL_CAPACITY);
    self.rng = .init(seed);
    self.tick_count = 0;
    return self;
}

pub fn deinit(self: *WorldSimulation, allocator: std.mem.Allocator) void {
    log.info("world update wheel peak: {d}/{d}", .{ self.pool_used_peak, POOL_CAPACITY });
    allocator.free(self.node_pool);
    self.enqueued.deinit(allocator);
    self.* = undefined;
}

/// Reset the scheduler state without freeing. Used after load or after a
/// fresh world is generated, to clear stale state from `init` before
/// real ticks begin.
pub fn reset_scheduler(self: *WorldSimulation) void {
    @memset(&self.wheel_buckets, SENTINEL);
    for (0..POOL_CAPACITY) |i| {
        self.node_pool[i] = .{
            .loc = .{ .x = 0, .z = 0, .y = 0 },
            .next = if (i + 1 < POOL_CAPACITY) @intCast(i + 1) else SENTINEL,
        };
    }
    self.free_head = 0;
    self.pool_used = 0;
    self.ready_tail = SENTINEL;
    self.enqueued.clearRetainingCapacity();
}

/// Process due work within the fixed packet/work budget and return the number
/// of changes emitted. Entries that do not fit remain in ready_tail for the
/// next tick; their dedup membership is kept intact until they execute.
pub fn tick(self: *WorldSimulation, data: *WorldData, sink: BlockChangeSink) u32 {
    var emitted: u32 = 0;
    var processed: u32 = 0;
    const slot = @as(u32, @intCast(self.tick_count & WHEEL_MASK));
    const due_tail = self.wheel_buckets[slot];
    self.wheel_buckets[slot] = SENTINEL;
    self.circular_append(&self.ready_tail, due_tail);

    while (self.ready_tail != SENTINEL and processed < MAX_DUE_UPDATES_PER_TICK) {
        const node_idx = self.circular_peek_head(self.ready_tail);
        const node = self.node_pool[node_idx];
        const change_bound = block_update_change_bound(data, node.loc);
        if (change_bound > MAX_BLOCK_CHANGES_PER_TICK - emitted) break;

        _ = self.circular_pop_head(&self.ready_tail);
        self.release_node(node_idx);

        const emitted_before = emitted;
        self.process_block_update(data, sink, &emitted, node.loc);
        assert(emitted - emitted_before <= change_bound);
        processed += 1;
    }

    self.tick_count +%= 1;
    data.tick_count = self.tick_count;
    return emitted;
}

/// Runtime block mutation entry point: data write + clear scheduler dedup.
pub fn set_block(self: *WorldSimulation, data: *WorldData, x: u16, y: u16, z: u16, block: Block) void {
    data.apply_block(x, y, z, block);
    // The enqueue dedup set is keyed by location, not block type. If the
    // block at this loc was previously something with a slow tick (e.g.
    // dirt/grass at 100-999 ticks) and is now something fast (water/lava
    // at 4 ticks), a stale entry would prevent try_enqueue from scheduling
    // the new block at its faster delay until the slow timer eventually
    // fires (5-50s later). Clearing here lets the next neighbor pass insert
    // at the correct delay; any orphan wheel entry just no-ops when it
    // finally fires because process_block_update re-reads the block.
    self.enqueued_remove(data.get_index(x, y, z));
}

fn process_block_update(
    self: *WorldSimulation,
    data: *WorldData,
    sink: BlockChangeSink,
    emitted: *u32,
    loc: Location,
) void {
    self.enqueued_remove(loc.to_index());
    const x: u16 = loc.x;
    const y: u16 = loc.y;
    const z: u16 = loc.z;
    const block = data.get_block(x, y, z);

    if ((block.id == .sand or block.id == .gravel) and y > 0) {
        const below = data.get_block(x, y - 1, z);
        if (below.is_air() or below.is_fluid()) {
            self.queue_block_change(data, sink, emitted, x, y, z, .{ .id = .air });
            self.queue_block_change(data, sink, emitted, x, y - 1, z, block);
        }
    } else if (block.id == .dirt and data.has_direct_sunlight(x, y, z)) {
        self.queue_block_change(data, sink, emitted, x, y, z, .{ .id = .grass });
    } else if (block.id == .grass and !data.has_direct_sunlight(x, y, z)) {
        self.queue_block_change(data, sink, emitted, x, y, z, .{ .id = .dirt });
    } else if (block.id == .sapling and data.has_direct_sunlight(x, y, z)) {
        const height: u32 = @intCast(self.rng.next() % 3 + 4);
        self.grow_tree(data, sink, emitted, x, y, z, height);
    } else if ((block.id == .sapling or block.id == .flower_1 or block.id == .flower_2) and
        !data.has_direct_sunlight(x, y, z))
    {
        self.queue_block_change(data, sink, emitted, x, y, z, .{ .id = .air });
    } else if ((block.id == .mushroom_1 or block.id == .mushroom_2) and
        data.has_direct_sunlight(x, y, z))
    {
        self.queue_block_change(data, sink, emitted, x, y, z, .{ .id = .air });
    } else if (block.is_fluid()) {
        self.process_fluid(data, sink, emitted, x, y, z, block);
    }
}

// --- Timer wheel operations ---

/// Push at the head of a circular list while retaining its tail index. This
/// preserves the old wheel's newest-first order within a deadline bucket.
fn circular_push_head(self: *WorldSimulation, tail: *u32, node_idx: u32) void {
    if (tail.* == SENTINEL) {
        self.node_pool[node_idx].next = node_idx;
        tail.* = node_idx;
        return;
    }

    self.node_pool[node_idx].next = self.node_pool[tail.*].next;
    self.node_pool[tail.*].next = node_idx;
}

/// Append src after dst in FIFO order. Both values are tails of circular
/// lists; no node allocation or traversal is required.
fn circular_append(self: *WorldSimulation, dst_tail: *u32, src_tail: u32) void {
    if (src_tail == SENTINEL) return;
    if (dst_tail.* == SENTINEL) {
        dst_tail.* = src_tail;
        return;
    }

    const dst_head = self.node_pool[dst_tail.*].next;
    const src_head = self.node_pool[src_tail].next;
    self.node_pool[dst_tail.*].next = src_head;
    self.node_pool[src_tail].next = dst_head;
    dst_tail.* = src_tail;
}

fn circular_peek_head(self: *const WorldSimulation, tail: u32) u32 {
    assert(tail != SENTINEL);
    return self.node_pool[tail].next;
}

fn circular_pop_head(self: *WorldSimulation, tail: *u32) u32 {
    assert(tail.* != SENTINEL);
    const tail_idx = tail.*;
    const head_idx = self.node_pool[tail_idx].next;
    if (head_idx == tail_idx) {
        tail.* = SENTINEL;
    } else {
        self.node_pool[tail_idx].next = self.node_pool[head_idx].next;
    }
    return head_idx;
}

fn release_node(self: *WorldSimulation, node_idx: u32) void {
    self.node_pool[node_idx].next = self.free_head;
    self.free_head = node_idx;
    self.pool_used -= 1;
}

fn wheel_insert(self: *WorldSimulation, loc: Location, delay: u32) void {
    assert(delay < WHEEL_SIZE);
    assert(self.free_head != SENTINEL);
    const node_idx = self.free_head;
    self.free_head = self.node_pool[node_idx].next;
    self.pool_used += 1;
    if (self.pool_used > self.pool_used_peak) self.pool_used_peak = self.pool_used;

    const slot = @as(u32, @intCast((self.tick_count +% delay) & WHEEL_MASK));
    self.node_pool[node_idx].loc = loc;
    self.circular_push_head(&self.wheel_buckets[slot], node_idx);
}

/// Enqueue a block and its 6 face neighbors for deferred update.
pub fn enqueue_neighbors_of(self: *WorldSimulation, data: *const WorldData, x: u16, y: u16, z: u16) void {
    self.try_enqueue(data, x, y, z);
    if (x > 0) self.try_enqueue(data, x - 1, y, z);
    if (x + 1 < c.WorldLength) self.try_enqueue(data, x + 1, y, z);
    if (y > 0) self.try_enqueue(data, x, y - 1, z);
    if (y + 1 < c.WorldHeight) self.try_enqueue(data, x, y + 1, z);
    if (z > 0) self.try_enqueue(data, x, y, z - 1);
    if (z + 1 < c.WorldDepth) self.try_enqueue(data, x, y, z + 1);
}

/// Tick delay per block type: fluids and gravity use 4 ticks, vegetation is random.
fn tick_delay(self: *WorldSimulation, block: Block) u32 {
    if (block.fast_tick()) return 4;
    return @intCast(self.rng.next() % 900 + 100);
}

fn try_enqueue(self: *WorldSimulation, data: *const WorldData, x: u16, y: u16, z: u16) void {
    const block = data.get_block(x, y, z);
    if (!block.ticks()) return;
    const idx = data.get_index(x, y, z);
    if (std.mem.indexOfScalar(u32, self.enqueued.items, idx) != null) return;
    if (self.free_head == SENTINEL or self.enqueued.items.len >= POOL_CAPACITY) {
        log.warn("world update dropped: wheel full (pool_used={d})", .{self.pool_used});
        return;
    }
    self.enqueued.appendAssumeCapacity(idx);
    const loc: Location = .{ .x = @intCast(x), .z = @intCast(z), .y = @intCast(y) };
    self.wheel_insert(loc, self.tick_delay(block));
}

fn enqueued_remove(self: *WorldSimulation, idx: u32) void {
    if (std.mem.indexOfScalar(u32, self.enqueued.items, idx)) |i| {
        _ = self.enqueued.swapRemove(i);
    }
}

/// Maximum client-visible changes this update can commit from its current
/// state. The scheduler admits an update only when this many budget slots are
/// available, so queue_block_change can stay allocation-free and atomic at
/// the update level. Fast fluid cases are counted precisely where cheap so a
/// large falling-water batch can use the full 2048-change budget.
fn block_update_change_bound(data: *const WorldData, loc: Location) u32 {
    const x: u16 = loc.x;
    const y: u16 = loc.y;
    const z: u16 = loc.z;
    const block = data.get_block(x, y, z);

    return switch (block.id) {
        .sand, .gravel => if (y > 0 and (data.get_block(x, y - 1, z).is_air() or data.get_block(x, y - 1, z).is_fluid())) 2 else 0,
        .dirt => if (data.has_direct_sunlight(x, y, z)) 1 else 0,
        .grass => if (!data.has_direct_sunlight(x, y, z)) 1 else 0,
        .sapling => if (data.has_direct_sunlight(x, y, z)) MAX_TREE_CHANGES else 1,
        .flower_1, .flower_2 => if (!data.has_direct_sunlight(x, y, z)) 1 else 0,
        .mushroom_1, .mushroom_2 => if (data.has_direct_sunlight(x, y, z)) 1 else 0,
        .flowing_water, .still_water => water_change_bound(data, x, y, z, block),
        .flowing_lava, .still_lava => lava_change_bound(data, x, y, z, block),
        else => 0,
    };
}

/// Six trunk blocks plus at most 61 leaves under the current tree shape.
const MAX_TREE_CHANGES: u32 = 67;

comptime {
    if (MAX_TREE_CHANGES > MAX_BLOCK_CHANGES_PER_TICK)
        @compileError("the per-tick change budget must fit one complete tree update");
}

fn water_change_bound(data: *const WorldData, x: u16, y: u16, z: u16, block: Block) u32 {
    const lava_neighbors = count_lava_neighbors(data, x, y, z);
    if (block.id == .flowing_water and !has_fluid_neighbor(data, x, y, z, true)) return lava_neighbors + 1;
    if (y > 0 and data.get_block(x, y - 1, z).is_air() and !is_near_sponge(data, x, y - 1, z)) return lava_neighbors + 1;
    return lava_neighbors + count_horizontal_air_neighbors(data, x, y, z);
}

fn lava_change_bound(data: *const WorldData, x: u16, y: u16, z: u16, block: Block) u32 {
    if (has_fluid_neighbor(data, x, y, z, true)) return 1;
    if (block.id == .flowing_lava and !has_fluid_neighbor(data, x, y, z, false)) return 1;
    if (y > 0 and data.get_block(x, y - 1, z).is_air()) return 1;
    return count_horizontal_air_neighbors(data, x, y, z);
}

fn count_lava_neighbors(data: *const WorldData, x: u16, y: u16, z: u16) u32 {
    var count: u32 = 0;
    if (x > 0 and data.get_block(x - 1, y, z).is_lava()) count += 1;
    if (x + 1 < c.WorldLength and data.get_block(x + 1, y, z).is_lava()) count += 1;
    if (y > 0 and data.get_block(x, y - 1, z).is_lava()) count += 1;
    if (y + 1 < c.WorldHeight and data.get_block(x, y + 1, z).is_lava()) count += 1;
    if (z > 0 and data.get_block(x, y, z - 1).is_lava()) count += 1;
    if (z + 1 < c.WorldDepth and data.get_block(x, y, z + 1).is_lava()) count += 1;
    return count;
}

fn count_horizontal_air_neighbors(data: *const WorldData, x: u16, y: u16, z: u16) u32 {
    var count: u32 = 0;
    if (x > 0 and data.get_block(x - 1, y, z).is_air()) count += 1;
    if (x + 1 < c.WorldLength and data.get_block(x + 1, y, z).is_air()) count += 1;
    if (z > 0 and data.get_block(x, y, z - 1).is_air()) count += 1;
    if (z + 1 < c.WorldDepth and data.get_block(x, y, z + 1).is_air()) count += 1;
    return count;
}

// --- Fluid physics ---

fn process_fluid(
    self: *WorldSimulation,
    data: *WorldData,
    sink: BlockChangeSink,
    emitted: *u32,
    x: u16,
    y: u16,
    z: u16,
    block: Block,
) void {
    const water = block.is_water();
    const flow: Block = if (water) .{ .id = .flowing_water } else .{ .id = .flowing_lava };

    if (self.check_lava_water(data, sink, emitted, x, y, z, water)) return;

    if ((block.id == .flowing_water or block.id == .flowing_lava) and
        !has_fluid_neighbor(data, x, y, z, water))
    {
        self.queue_block_change(data, sink, emitted, x, y, z, .{ .id = .air });
        return;
    }

    if (y > 0 and data.get_block(x, y - 1, z).is_air()) {
        if (!water or !is_near_sponge(data, x, y - 1, z)) {
            self.queue_block_change(data, sink, emitted, x, y - 1, z, flow);
            return;
        }
    }

    self.spread_horizontal(data, sink, emitted, x, y, z, flow, water);
}

/// Returns true if the current block was consumed (lava turned to stone).
fn check_lava_water(
    self: *WorldSimulation,
    data: *WorldData,
    sink: BlockChangeSink,
    emitted: *u32,
    x: u16,
    y: u16,
    z: u16,
    water: bool,
) bool {
    if (water) {
        if (x > 0 and data.get_block(x - 1, y, z).is_lava()) self.queue_block_change(data, sink, emitted, x - 1, y, z, .{ .id = .stone });
        if (x + 1 < c.WorldLength and data.get_block(x + 1, y, z).is_lava()) self.queue_block_change(data, sink, emitted, x + 1, y, z, .{ .id = .stone });
        if (y > 0 and data.get_block(x, y - 1, z).is_lava()) self.queue_block_change(data, sink, emitted, x, y - 1, z, .{ .id = .stone });
        if (y + 1 < c.WorldHeight and data.get_block(x, y + 1, z).is_lava()) self.queue_block_change(data, sink, emitted, x, y + 1, z, .{ .id = .stone });
        if (z > 0 and data.get_block(x, y, z - 1).is_lava()) self.queue_block_change(data, sink, emitted, x, y, z - 1, .{ .id = .stone });
        if (z + 1 < c.WorldDepth and data.get_block(x, y, z + 1).is_lava()) self.queue_block_change(data, sink, emitted, x, y, z + 1, .{ .id = .stone });
        return false;
    } else {
        if ((x > 0 and data.get_block(x - 1, y, z).is_water()) or
            (x + 1 < c.WorldLength and data.get_block(x + 1, y, z).is_water()) or
            (y > 0 and data.get_block(x, y - 1, z).is_water()) or
            (y + 1 < c.WorldHeight and data.get_block(x, y + 1, z).is_water()) or
            (z > 0 and data.get_block(x, y, z - 1).is_water()) or
            (z + 1 < c.WorldDepth and data.get_block(x, y, z + 1).is_water()))
        {
            self.queue_block_change(data, sink, emitted, x, y, z, .{ .id = .stone });
            return true;
        }
        return false;
    }
}

fn has_fluid_neighbor(data: *const WorldData, x: u16, y: u16, z: u16, water: bool) bool {
    if (x > 0 and is_same_fluid(data.get_block(x - 1, y, z), water)) return true;
    if (x + 1 < c.WorldLength and is_same_fluid(data.get_block(x + 1, y, z), water)) return true;
    if (y > 0 and is_same_fluid(data.get_block(x, y - 1, z), water)) return true;
    if (y + 1 < c.WorldHeight and is_same_fluid(data.get_block(x, y + 1, z), water)) return true;
    if (z > 0 and is_same_fluid(data.get_block(x, y, z - 1), water)) return true;
    if (z + 1 < c.WorldDepth and is_same_fluid(data.get_block(x, y, z + 1), water)) return true;
    return false;
}

fn is_same_fluid(block: Block, water: bool) bool {
    return if (water) block.is_water() else block.is_lava();
}

fn spread_horizontal(
    self: *WorldSimulation,
    data: *WorldData,
    sink: BlockChangeSink,
    emitted: *u32,
    x: u16,
    y: u16,
    z: u16,
    flow: Block,
    water: bool,
) void {
    if (x > 0 and data.get_block(x - 1, y, z).is_air() and (!water or !is_near_sponge(data, x - 1, y, z)))
        self.queue_block_change(data, sink, emitted, x - 1, y, z, flow);
    if (x + 1 < c.WorldLength and data.get_block(x + 1, y, z).is_air() and (!water or !is_near_sponge(data, x + 1, y, z)))
        self.queue_block_change(data, sink, emitted, x + 1, y, z, flow);
    if (z > 0 and data.get_block(x, y, z - 1).is_air() and (!water or !is_near_sponge(data, x, y, z - 1)))
        self.queue_block_change(data, sink, emitted, x, y, z - 1, flow);
    if (z + 1 < c.WorldDepth and data.get_block(x, y, z + 1).is_air() and (!water or !is_near_sponge(data, x, y, z + 1)))
        self.queue_block_change(data, sink, emitted, x, y, z + 1, flow);
}

const SPONGE_RADIUS: i32 = 2;

/// Called when a sponge is placed: absorb all water in a 5x5x5 cube and
/// stream every removal through the caller-provided sink.
pub fn sponge_absorb(self: *WorldSimulation, data: *WorldData, sink: BlockChangeSink, cx: u16, cy: u16, cz: u16) void {
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
                const ux: u16 = @intCast(nx);
                const uy: u16 = @intCast(ny);
                const uz: u16 = @intCast(nz);
                const blk = data.get_block(ux, uy, uz);
                if (blk.is_water()) {
                    self.set_block(data, ux, uy, uz, .{ .id = .air });
                    sink.emit(.{ .x = ux, .y = uy, .z = uz, .block = .{ .id = .air } });
                    self.enqueue_neighbors_of(data, ux, uy, uz);
                }
            }
        }
    }
}

/// Called when a sponge is destroyed: enqueue neighbors in a radius to
/// re-evaluate water flow.
pub fn sponge_release(self: *WorldSimulation, data: *const WorldData, cx: u16, cy: u16, cz: u16) void {
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
                self.enqueue_neighbors_of(data, @intCast(nx), @intCast(ny), @intCast(nz));
            }
        }
    }
}

fn is_near_sponge(data: *const WorldData, x: u16, y: u16, z: u16) bool {
    var dx: i32 = -SPONGE_RADIUS;
    while (dx <= SPONGE_RADIUS) : (dx += 1) {
        var dy: i32 = -SPONGE_RADIUS;
        while (dy <= SPONGE_RADIUS) : (dy += 1) {
            var dz: i32 = -SPONGE_RADIUS;
            while (dz <= SPONGE_RADIUS) : (dz += 1) {
                const nx = @as(i32, x) + dx;
                const ny = @as(i32, y) + dy;
                const nz = @as(i32, z) + dz;
                if (nx < 0 or nx >= c.WorldLength or ny < 0 or ny >= c.WorldHeight or nz < 0 or nz >= c.WorldDepth) continue;
                if (data.get_block(@intCast(nx), @intCast(ny), @intCast(nz)).id == .sponge) return true;
            }
        }
    }
    return false;
}

fn queue_block_change(
    self: *WorldSimulation,
    data: *WorldData,
    sink: BlockChangeSink,
    emitted: *u32,
    x: u16,
    y: u16,
    z: u16,
    block: Block,
) void {
    assert(emitted.* < MAX_BLOCK_CHANGES_PER_TICK);
    self.set_block(data, x, y, z, block);
    sink.emit(.{ .x = x, .y = y, .z = z, .block = block });
    emitted.* += 1;
    self.enqueue_neighbors_of(data, x, y, z);
}

/// Grow a tree at sapling position (x, y, z). Trunk replaces the sapling
/// and extends upward for `height` blocks total. Leaves surround the top.
fn grow_tree(
    self: *WorldSimulation,
    data: *WorldData,
    sink: BlockChangeSink,
    emitted: *u32,
    x: u16,
    y: u16,
    z: u16,
    height: u32,
) void {
    if (y == 0) return;
    const base_y: u32 = @as(u32, y) - 1;
    if (base_y + height + 2 >= c.WorldHeight) return;

    var check_y: u32 = @as(u32, y) + 1;
    while (check_y <= base_y + height + 2) : (check_y += 1) {
        if (check_y >= c.WorldHeight) return;
        if (!data.get_block(x, @intCast(check_y), z).is_air()) return;
    }

    for (0..height) |i| {
        const ty: u32 = base_y + 1 + @as(u32, @intCast(i));
        if (ty < c.WorldHeight) self.queue_block_change(data, sink, emitted, x, @intCast(ty), z, .{ .id = .log });
    }

    self.grow_tree_leaves(data, sink, emitted, x, base_y, z, height);
}

fn grow_tree_leaves(
    self: *WorldSimulation,
    data: *WorldData,
    sink: BlockChangeSink,
    emitted: *u32,
    x: u16,
    base_y: u32,
    z: u16,
    height: u32,
) void {
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
                    if (layer == 3 or self.rng.next() % 2 == 0) continue;
                }
                const lx = @as(i32, @intCast(x)) + dx;
                const lz = @as(i32, @intCast(z)) + dz;
                if (lx < 0 or lx >= c.WorldLength or lz < 0 or lz >= c.WorldDepth) continue;
                const ux: u16 = @intCast(lx);
                const uz: u16 = @intCast(lz);
                if (data.get_block(ux, @intCast(ly), uz).is_air()) {
                    self.queue_block_change(data, sink, emitted, ux, @intCast(ly), uz, .{ .id = .leaves });
                }
            }
        }
    }
}

const TestChangeRecorder = struct {
    count: u32 = 0,
    first: ?BlockChange = null,

    fn emit(ctx: ?*anyopaque, change: BlockChange) void {
        const self: *TestChangeRecorder = @ptrCast(@alignCast(ctx.?));
        if (self.count == 0) self.first = change;
        self.count += 1;
    }
};

test "tick defers an overflow-sized fluid batch without buffering or dropping" {
    common.BlockRegistry.init();

    var data: WorldData = undefined;
    try data.init_in_place(std.testing.allocator, 0x1234);
    defer data.deinit();
    data.compute_chunk_counts();

    var sim = try WorldSimulation.init(std.testing.allocator, 0x5678);
    defer sim.deinit(std.testing.allocator);

    var recorder = TestChangeRecorder{};
    const sink: BlockChangeSink = .{ .ctx = &recorder, .emit_fn = TestChangeRecorder.emit };
    const source_count = MAX_BLOCK_CHANGES_PER_TICK + 1;

    var i: u32 = 0;
    while (i < source_count) : (i += 1) {
        const x: u16 = @intCast(i % c.WorldLength);
        const z: u16 = @intCast(i / c.WorldLength);
        data.apply_block(x, 1, z, .{ .id = .still_water });
        sim.try_enqueue(&data, x, 1, z);
    }

    // Fast-tick entries are due at tick four, so slots zero through three
    // must remain quiet.
    for (0..4) |_| {
        try std.testing.expectEqual(@as(u32, 0), sim.tick(&data, sink));
    }

    try std.testing.expectEqual(MAX_BLOCK_CHANGES_PER_TICK, sim.tick(&data, sink));
    try std.testing.expectEqual(MAX_BLOCK_CHANGES_PER_TICK, recorder.count);
    try std.testing.expect(sim.ready_tail != SENTINEL);

    // The one carry-over source executes next tick. The recorder sees a
    // committed block, proving the sink is post-mutation rather than a stale
    // buffered record.
    try std.testing.expectEqual(@as(u32, 1), sim.tick(&data, sink));
    try std.testing.expectEqual(source_count, recorder.count);
    try std.testing.expectEqual(SENTINEL, sim.ready_tail);
    const first = recorder.first orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(first.block.id, data.get_block(first.x, first.y, first.z).id);

    sim.reset_scheduler();
    try std.testing.expectEqual(@as(u32, 0), sim.pool_used);
    try std.testing.expectEqual(@as(usize, 0), sim.enqueued.items.len);
    try std.testing.expectEqual(SENTINEL, sim.ready_tail);
    for (sim.wheel_buckets) |tail| try std.testing.expectEqual(SENTINEL, tail);
}

test "tick defers a multi-change update rather than partially committing it" {
    common.BlockRegistry.init();

    var data: WorldData = undefined;
    try data.init_in_place(std.testing.allocator, 0x1234);
    defer data.deinit();
    data.compute_chunk_counts();

    var sim = try WorldSimulation.init(std.testing.allocator, 0x5678);
    defer sim.deinit(std.testing.allocator);

    var recorder = TestChangeRecorder{};
    const sink: BlockChangeSink = .{ .ctx = &recorder, .emit_fn = TestChangeRecorder.emit };
    const tree_x: u16 = 128;
    const tree_y: u16 = 1;
    const tree_z: u16 = 128;
    data.apply_block(tree_x, tree_y, tree_z, .{ .id = .sapling });

    // Put the tree at the tail of the same due bucket. The water entries are
    // exact one-change updates, leaving 66 slots -- one less than a full tree
    // can emit -- when the tree reaches the head.
    const tree_idx = data.get_index(tree_x, tree_y, tree_z);
    sim.enqueued.appendAssumeCapacity(tree_idx);
    sim.wheel_insert(.{ .x = @intCast(tree_x), .z = @intCast(tree_z), .y = @intCast(tree_y) }, 4);

    const water_count = MAX_BLOCK_CHANGES_PER_TICK - MAX_TREE_CHANGES + 1;
    var i: u32 = 0;
    while (i < water_count) : (i += 1) {
        const x: u16 = @intCast(i % c.WorldLength);
        const z: u16 = @intCast(i / c.WorldLength);
        data.apply_block(x, 1, z, .{ .id = .still_water });
        sim.try_enqueue(&data, x, 1, z);
    }

    for (0..4) |_| {
        try std.testing.expectEqual(@as(u32, 0), sim.tick(&data, sink));
    }

    try std.testing.expectEqual(water_count, sim.tick(&data, sink));
    try std.testing.expectEqual(@as(c.Block.Type, .sapling), data.get_block(tree_x, tree_y, tree_z).id);
    try std.testing.expect(sim.ready_tail != SENTINEL);

    const tree_changes = sim.tick(&data, sink);
    try std.testing.expect(tree_changes > 0);
    try std.testing.expect(tree_changes <= MAX_TREE_CHANGES);
    try std.testing.expectEqual(@as(c.Block.Type, .log), data.get_block(tree_x, tree_y, tree_z).id);
}
