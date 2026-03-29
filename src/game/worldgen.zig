//! Minecraft Classic Worldgen
//! Based on writeup: https://github.com/ClassiCube/ClassiCube/wiki/Minecraft-Classic-map-generation-algorithm
//!
//! Uses custom Fixed Point 16,16 format to enable similar precision at higher speed
//! Care was taken to minimize DIV instructions where possible with shifts
//! Heavy use of bit manipulation and bitmasks in order to minimize data storage of metadata
//!
//! Current PSP worldgen time on 256x64x256 world: 9856ms
//! ```
//! info(worldgen): Raising: 3037ms
//! info(worldgen): Erosion: 2354ms
//! info(worldgen): Strata: 1924ms
//! info(worldgen): Caves: 645ms
//! info(worldgen): Ores: 63ms
//! info(worldgen): Merge: 357ms
//! info(worldgen): Water: 24ms
//! info(worldgen): Lava: 53ms
//! info(worldgen): Surface: 1248ms
//! info(worldgen): Plants: 105ms
//! ```
//!
//! Historical CrossCraft-Classic (accurate) generation time was > 30s, usually in the mid 40s
//!
//! Various Notes:
//! * We use Y-first ordering in the world block array (YZX), so our generator prefers this order too for cache maximization
//!

const std = @import("std");
const assert = std.debug.assert;
const log = std.log.scoped(.worldgen);
const common = @import("common");
const c = common.consts;
const FP16 = common.fp.FP(32, 16, true);
const Xorshift64 = common.xorshift64.Xorshift64;
const noise = common.noise;
const OctaveNoise = noise.OctaveNoise;
const CombinedNoise = noise.CombinedNoise;
const sin_fp16 = noise.sin_fp16;
const cos_fp16 = noise.cos_fp16;

const B = c.Block;
const W: u32 = c.WorldLength;
const H: u32 = c.WorldHeight;
const D: u32 = c.WorldDepth;
const WATER: i32 = c.Water_Level;
const MAP_AREA: u32 = W * D;
const MAP_VOL: u32 = W * H * D;

// FP16 constants (value = round(x * 65536))
const FP_ONE = noise.FP_ONE;

// Floats in this format are read as 1.3, 0.8, 0.2 etc.
// These constants are taken from the documentation and computed
const FP_1_3: FP16 = .{ .value = 85197 };
const FP_0_8: FP16 = .{ .value = 52429 };
const FP_0_2: FP16 = .{ .value = 13107 };
const FP_0_9: FP16 = .{ .value = 58982 };
const FP_0_75: FP16 = .{ .value = 49152 };
const FP_0_25: FP16 = .{ .value = 16384 };

// RCP means ReCiProcal (1/5, 1/6, 1/8)
const RCP_5: FP16 = .{ .value = 13107 };
const RCP_6: FP16 = .{ .value = 10923 };
const RCP_8: FP16 = .{ .value = 8192 }; // Crazy how that works out huh? /s

// -- Raising constants (Step 1: heightmap) --------------------------------
const HEIGHT_LOW_OFFSET = FP16.from(4); // heightLow = noise1/6 - 4
const HEIGHT_HIGH_OFFSET = FP16.from(6); // heightHigh = noise2/5 + 6

// -- Erosion constants (Step 2) -------------------------------------------
const EROSION_THRESHOLD: i32 = 2 * 0x10000; // a > 2

// -- Strata constants (Step 3) --------------------------------------------
const DIRT_NOISE_DIVISOR: i32 = 24; // dirtThickness = noise/24 - 4
const DIRT_THICKNESS_OFFSET: i32 = 4;

// -- Cave constants (Step 4) ----------------------------------------------
const CAVE_COUNT_DIVISOR: u32 = 8192; // total caves = volume / 8192
const CAVE_LENGTH_MULT: u32 = 200; // caveLength = rand*rand * 200
const CAVE_RADIUS_MULT = FP16.from(3); // caveRadius = rand*rand * 3 + 1
const ORE_RADIUS_OFFSET: FP16 = .{ .value = 32768 }; // oreRadius = rand*rand + 0.5
const WALKER_JITTER_RANGE: u32 = 4; // jitter in [-2, 1] blocks
const WALKER_JITTER_CENTER: i32 = 2;

// -- Ore constants (Step 5) -----------------------------------------------
// Vein count = volume * abundance / 16384
// We multiply abundance*10 and divide by 16384*10=163840 to stay integer
const ORE_VEIN_DIVISOR: u32 = 163840; // = 16384 * 10
const COAL_ABUNDANCE_X10: u32 = 9; // abundance 0.9
const IRON_ABUNDANCE_X10: u32 = 7; // abundance 0.7
const GOLD_ABUNDANCE_X10: u32 = 5; // abundance 0.5

// -- Walker radius constants ----------------------------------------------
const WALKER_HEIGHT_SCALE: i64 = 3; // height_factor = (H - cy)/H * 3 + 1
const WALKER_HEIGHT_CLAMP: i32 = 4 * 0x10000; // max height factor in FP16
const ORE_RADIUS_SHRINK: i32 = 2; // ore veins half the cave radius

// -- Flood constants (Steps 7-8) ------------------------------------------
const WATER_SOURCE_DIVISOR: u32 = 8000; // underground water = area / 8000
const WATER_SOURCE_DEPTH: u32 = 2; // sources at waterLevel-1 or waterLevel-2
const LAVA_SOURCE_DIVISOR: u32 = 20000; // lava sources = volume / 20000
const LAVA_DEPTH_OFFSET: i32 = 3; // y = (waterLevel - 3) * rand * rand

// -- Surface constants (Step 9) -------------------------------------------
const SAND_NOISE_THRESHOLD: i32 = 8 * 0x10000; // sandChance = noise > 8
const GRAVEL_NOISE_THRESHOLD: i32 = 12 * 0x10000; // gravelChance = noise > 12

// -- Plant constants (Step 10) --------------------------------------------
const TREE_PATCH_DIVISOR: u32 = 4000; // tree patches = area / 4000
const TREE_ATTEMPTS_OUTER: u32 = 20; // placement iterations per patch
const TREE_ATTEMPTS_INNER: u32 = 20;
const TREE_MIN_HEIGHT: u32 = 4; // tree height = rand(3) + 4
const TREE_HEIGHT_VARIANCE: u32 = 3;
const TREE_MIN_HEADROOM: i32 = 8; // need at least 8 blocks above ground
const PLANT_WANDER_RANGE: u32 = 6; // random walk step for plant placement
const FLOWER_PATCH_DIVISOR: u32 = 3000; // flower patches = area / 3000
const FLOWER_GROUPS: u32 = 10; // groups per patch
const FLOWER_ATTEMPTS: u32 = 5; // attempts per group
const MUSHROOM_DIVISOR: u32 = 2000; // mushroom patches = volume / 2000
const MUSHROOM_GROUPS: u32 = 10;
const MUSHROOM_ATTEMPTS: u32 = 5;

// -- Index / bitmask helpers ---------------------------------------------

fn blockIdx(x: u32, y: u32, z: u32) u32 {
    assert(x < W and y < H and z < D);
    return (y * D + z) * W + x;
}

fn hmIdx(x: u32, z: u32) u32 {
    return x * D + z;
}

fn setCaveBit(mask: []u8, idx: u32) void {
    const b: u3 = @intCast(idx & 7);
    mask[idx >> 3] |= @as(u8, 1) << b;
}

fn getCaveBit(mask: []const u8, idx: u32) bool {
    const b: u3 = @intCast(idx & 7);
    return (mask[idx >> 3] >> b) & 1 != 0;
}

fn setOreBits(mask: []u8, idx: u32, ore: u2) void {
    const off: u3 = @intCast((idx & 3) * 2);
    mask[idx >> 2] = (mask[idx >> 2] & ~(@as(u8, 3) << off)) | (@as(u8, ore) << off);
}

fn getOreBits(mask: []const u8, idx: u32) u2 {
    const off: u3 = @intCast((idx & 3) * 2);
    return @intCast((mask[idx >> 2] >> off) & 3);
}

// -- Oblate spheroid carving ---------------------------------------------

const MaskMode = enum { cave, coal, iron, gold };

/// This function is a critical part of Minecraft-esque world generation
/// The oblate spheroid is either subtracted or added to the world and results in the shape of caves and ore veins
/// In our use we take a mode parameter which is useful for different types of masks we'd like to be carving in
fn carveSpheroid(mask: []u8, cx: i32, cy: i32, cz: i32, r: i32, mode: MaskMode) void {
    if (r <= 0) return;
    const r2 = r * r;
    var dy: i32 = -r;
    while (dy <= r) : (dy += 1) {
        const y = cy + dy;
        if (y < 1 or y >= H) continue;
        const slice_r2 = r2 - 2 * dy * dy;
        if (slice_r2 <= 0) continue;
        var dx: i32 = -r;
        while (dx <= r) : (dx += 1) {
            if (dx * dx > slice_r2) continue;
            var dz: i32 = -r;
            while (dz <= r) : (dz += 1) {
                if (dx * dx + dz * dz > slice_r2) continue;
                const bx = cx + dx;
                const bz = cz + dz;
                if (bx < 0 or bx >= W or bz < 0 or bz >= D) continue;
                const idx = blockIdx(@intCast(bx), @intCast(y), @intCast(bz));
                switch (mode) {
                    .cave => setCaveBit(mask, idx),
                    .coal => setOreBits(mask, idx, 1),
                    .iron => setOreBits(mask, idx, 2),
                    .gold => setOreBits(mask, idx, 3),
                }
            }
        }
    }
}

// -- Cave/ore walker -----------------------------------------------------

// Walkers are essentially what may be described as "perlin worms" (which is a bit inaccurate because we don't use perlin noise for this, but rather random noise here which is similarly deterministic but CHEAP)
// These are used for any generation that needs this shape, which is why mask mode is accepted here.
// This function manages the initialization and step loop of the walker
fn runWalker(mask: []u8, mode: MaskMode, rng: *Xorshift64) void {
    var pos_x = FP16.from(@as(i32, @intCast(rng.next_bounded(W))));
    var pos_y = FP16.from(@as(i32, @intCast(rng.next_bounded(H))));
    var pos_z = FP16.from(@as(i32, @intCast(rng.next_bounded(D))));

    var theta: FP16 = .{ .value = @intCast(rng.next() % @as(u64, @intCast(noise.TWO_PI))) };
    var phi: FP16 = .{ .value = @divTrunc(@as(i32, @intCast(rng.next() & 0xFFFF)) - 0x8000, 4) };
    var d_theta: FP16 = .{ .value = 0 };
    var d_phi: FP16 = .{ .value = 0 };

    const cave_radius: FP16 = switch (mode) {
        .cave => rng.next_float().mul(rng.next_float()).mul(CAVE_RADIUS_MULT).add(FP_ONE),
        else => rng.next_float().mul(rng.next_float()).add(ORE_RADIUS_OFFSET),
    };

    const len_fp = rng.next_float().mul(rng.next_float());
    const cave_len: u32 = @max(1, @as(u32, @intCast(len_fp.value)) * CAVE_LENGTH_MULT / 65536);

    var step: u32 = 0;
    while (step < cave_len) : (step += 1) {
        walkerStep(&pos_x, &pos_y, &pos_z, &theta, &phi, &d_theta, &d_phi, rng);
        if (rng.next_float().value < FP_0_25.value) continue;

        const jx = @as(i32, @intCast(rng.next_bounded(WALKER_JITTER_RANGE))) - WALKER_JITTER_CENTER;
        const jy = @as(i32, @intCast(rng.next_bounded(WALKER_JITTER_RANGE))) - WALKER_JITTER_CENTER;
        const jz = @as(i32, @intCast(rng.next_bounded(WALKER_JITTER_RANGE))) - WALKER_JITTER_CENTER;
        const cx = pos_x.add(.{ .value = jx * FP_0_2.value });
        const cy = pos_y.add(.{ .value = jy * FP_0_2.value });
        const cz = pos_z.add(.{ .value = jz * FP_0_2.value });

        const r = walkerRadius(cy, cave_radius, step, cave_len, mode);
        if (r > 0) carveSpheroid(mask, cx.int(), cy.int(), cz.int(), r, mode);
    }
}

/// This is the per-phase walker step which moves the head of the walker to a new position and modifies the angle by random
fn walkerStep(
    px: *FP16,
    py: *FP16,
    pz: *FP16,
    theta: *FP16,
    phi: *FP16,
    d_theta: *FP16,
    d_phi: *FP16,
    rng: *Xorshift64,
) void {
    px.* = px.add(sin_fp16(theta.*).mul(cos_fp16(phi.*)));
    py.* = py.add(cos_fp16(theta.*));
    pz.* = pz.add(sin_fp16(phi.*));
    theta.* = theta.add(d_theta.mul(FP_0_2));
    d_theta.* = d_theta.mul(FP_0_9).add(rng.next_float()).sub(rng.next_float());
    phi.* = .{ .value = @divTrunc(phi.value, 2) + @divTrunc(d_phi.value, 4) };
    d_phi.* = d_phi.mul(FP_0_75).add(rng.next_float()).sub(rng.next_float());
}

/// Changes the radius of the walker
fn walkerRadius(cy: FP16, base: FP16, step: u32, length: u32, mode: MaskMode) i32 {
    const ht_fp = FP16.from(@as(i32, H));
    const diff = ht_fp.sub(cy);
    // height_factor = (H - cy) / H,  scaled by *3+1
    const hf_raw: i64 = @divTrunc(@as(i64, diff.value) * WALKER_HEIGHT_SCALE, @as(i64, H)) + 0x10000;
    const height_factor: FP16 = .{ .value = @intCast(std.math.clamp(hf_raw, 0, WALKER_HEIGHT_CLAMP)) };
    // sin envelope over walk length
    const angle: i32 = @intCast(@divTrunc(@as(i64, step) * @as(i64, noise.PI), @as(i64, length)));
    const envelope = sin_fp16(.{ .value = angle });
    var r = base.mul(height_factor).mul(envelope);
    // Ore veins are smaller
    if (mode != .cave) r = .{ .value = @divTrunc(r.value, ORE_RADIUS_SHRINK) };
    return @max(0, r.int());
}

// -- Step 1: Raising (heightmap) -----------------------------------------

fn stepRaising(heightmap: []i16, rng: *Xorshift64) void {
    assert(heightmap.len == MAP_AREA);
    const cn1 = CombinedNoise.init(rng, 8, 8);
    const cn2 = CombinedNoise.init(rng, 8, 8);
    const on = OctaveNoise.init(rng, 6);

    for (0..W) |xi| {
        for (0..D) |zi| {
            const xfp = FP16.from(@as(i32, @intCast(xi)));
            const zfp = FP16.from(@as(i32, @intCast(zi)));
            const sx = xfp.mul(FP_1_3);
            const sz = zfp.mul(FP_1_3);

            const low = cn1.compute(sx, sz).mul(RCP_6).sub(HEIGHT_LOW_OFFSET);
            const high = cn2.compute(sx, sz).mul(RCP_5).add(HEIGHT_HIGH_OFFSET);
            const sel = on.compute(xfp, zfp).mul(RCP_8);

            var result: FP16 = if (sel.value > 0) low else if (low.value > high.value) low else high;
            result = .{ .value = result.value >> 1 };
            if (result.value < 0) result = result.mul(FP_0_8);

            const h: i32 = result.int() + WATER;
            heightmap[hmIdx(@intCast(xi), @intCast(zi))] = @intCast(std.math.clamp(h, 1, @as(i32, H) - 2));
        }
    }
}

// -- Step 2: Erosion -----------------------------------------------------

fn stepErosion(heightmap: []i16, rng: *Xorshift64) void {
    assert(heightmap.len == MAP_AREA);
    const en1 = CombinedNoise.init(rng, 8, 8);
    const en2 = CombinedNoise.init(rng, 8, 8);

    for (0..W) |xi| {
        for (0..D) |zi| {
            const xfp = FP16.from(@as(i32, @intCast(xi)) * 2);
            const zfp = FP16.from(@as(i32, @intCast(zi)) * 2);
            const a = en1.compute(xfp, zfp).mul(RCP_8);
            const b: i16 = if (en2.compute(xfp, zfp).value > 0) 1 else 0;
            if (a.value > EROSION_THRESHOLD) {
                const idx = hmIdx(@intCast(xi), @intCast(zi));
                const h = heightmap[idx];
                heightmap[idx] = @divTrunc(h - b, 2) * 2 + b;
            }
        }
    }
}

// -- Step 3: Strata ------------------------------------------------------

fn stepStrata(blocks: []u8, heightmap: []const i16, rng: *Xorshift64) void {
    const soil = OctaveNoise.init(rng, 8);

    for (0..W) |xi| {
        for (0..D) |zi| {
            const x: u32 = @intCast(xi);
            const z: u32 = @intCast(zi);
            const xfp = FP16.from(@as(i32, @intCast(xi)));
            const zfp = FP16.from(@as(i32, @intCast(zi)));

            // Classic 0.30: negative thickness = dirt layer above stone.
            const noise_int: i32 = soil.compute(xfp, zfp).int();
            const dirt_thickness: i32 = @divTrunc(noise_int, DIRT_NOISE_DIVISOR) - DIRT_THICKNESS_OFFSET;
            const h: i32 = heightmap[hmIdx(x, z)];
            const stone_top: i32 = @max(0, h + dirt_thickness);

            for (0..H) |yi| {
                const y: i32 = @intCast(yi);
                const blk: u8 = if (y == 0) B.Bedrock else if (y <= stone_top) B.Stone else if (y <= h) B.Dirt else B.Air;
                blocks[blockIdx(x, @intCast(yi), z)] = blk;
            }
        }
    }
}

// -- Step 4-5: Caves & Ores ----------------------------------------------

fn stepCaves(cave_mask: []u8, rng: *Xorshift64) void {
    const count: u32 = MAP_VOL / CAVE_COUNT_DIVISOR;
    for (0..count) |_| {
        runWalker(cave_mask, .cave, rng);
    }
}

fn stepOres(ore_mask: []u8, rng: *Xorshift64) void {
    const coal_n: u32 = MAP_VOL * COAL_ABUNDANCE_X10 / ORE_VEIN_DIVISOR;
    const iron_n: u32 = MAP_VOL * IRON_ABUNDANCE_X10 / ORE_VEIN_DIVISOR;
    const gold_n: u32 = MAP_VOL * GOLD_ABUNDANCE_X10 / ORE_VEIN_DIVISOR;
    for (0..coal_n) |_| runWalker(ore_mask, .coal, rng);
    for (0..iron_n) |_| runWalker(ore_mask, .iron, rng);
    for (0..gold_n) |_| runWalker(ore_mask, .gold, rng);
}

// -- Step 6: Merge -------------------------------------------------------

fn stepMerge(blocks: []u8, cave_mask: []const u8, ore_mask: []const u8) void {
    for (0..H) |yi| {
        for (0..D) |zi| {
            for (0..W) |xi| {
                const x: u32 = @intCast(xi);
                const y: u32 = @intCast(yi);
                const z: u32 = @intCast(zi);
                const idx = blockIdx(x, y, z);
                if (getCaveBit(cave_mask, idx) and y > 0) {
                    blocks[idx] = B.Air;
                } else if (blocks[idx] == B.Stone) {
                    const ore = getOreBits(ore_mask, idx);
                    if (ore != 0) {
                        blocks[idx] = switch (ore) {
                            1 => B.Coal_Ore,
                            2 => B.Iron_Ore,
                            3 => B.Gold_Ore,
                            0 => unreachable,
                        };
                    }
                }
            }
        }
    }
}

// -- Step 7-8: Flood fill ------------------------------------------------

fn packCoord(x: u32, y: u32, z: u32) u32 {
    return (x << 18) | (y << 9) | z;
}

fn bfsFloodDown(blocks: []u8, queue: []u32, sx: u32, sy: u32, sz: u32, fluid: u8) void {
    const start_idx = blockIdx(sx, sy, sz);
    if (blocks[start_idx] != B.Air) return;
    blocks[start_idx] = fluid;
    const cap: u32 = @intCast(queue.len);
    var head: u32 = 0;
    var tail: u32 = 1;
    queue[0] = packCoord(sx, sy, sz);

    while (head != tail) {
        const coord = queue[head];
        head = (head + 1) % cap;
        const bx: i32 = @intCast(coord >> 18);
        const by: i32 = @intCast((coord >> 9) & 0x1FF);
        const bz: i32 = @intCast(coord & 0x1FF);

        const dirs = [_][3]i32{
            .{ -1, 0, 0 }, .{ 1, 0, 0 }, .{ 0, -1, 0 },
            .{ 0, 0, -1 }, .{ 0, 0, 1 },
        };
        for (&dirs) |d| {
            const nx = bx + d[0];
            const ny = by + d[1];
            const nz = bz + d[2];
            if (nx < 0 or nx >= W or ny < 1 or ny >= H or nz < 0 or nz >= D) continue;
            const nidx = blockIdx(@intCast(nx), @intCast(ny), @intCast(nz));
            if (blocks[nidx] != B.Air) continue;
            blocks[nidx] = fluid;
            const next_tail = (tail + 1) % cap;
            if (next_tail == head) return;
            queue[tail] = packCoord(@intCast(nx), @intCast(ny), @intCast(nz));
            tail = next_tail;
        }
    }
}

fn stepFloodWater(blocks: []u8, heightmap: []const i16, rng: *Xorshift64, flood_queue: []u32) void {
    // Ocean: column fill from heightmap+1 to water level
    for (0..W) |xi| {
        for (0..D) |zi| {
            const x: u32 = @intCast(xi);
            const z: u32 = @intCast(zi);
            const h: u32 = @intCast(heightmap[hmIdx(x, z)]);
            var y: u32 = h + 1;
            while (y < @as(u32, @intCast(WATER)) and y < H) : (y += 1) {
                const idx = blockIdx(x, y, z);
                if (blocks[idx] == B.Air) blocks[idx] = B.Still_Water;
            }
        }
    }
    // Underground water sources
    const sources: u32 = MAP_AREA / WATER_SOURCE_DIVISOR;
    for (0..sources) |_| {
        const sx = rng.next_bounded(W);
        const sy: u32 = @intCast(WATER - 1 - @as(i32, @intCast(rng.next_bounded(WATER_SOURCE_DEPTH))));
        const sz = rng.next_bounded(D);
        bfsFloodDown(blocks, flood_queue, sx, sy, sz, B.Still_Water);
    }
}

fn stepFloodLava(blocks: []u8, rng: *Xorshift64, flood_queue: []u32) void {
    const sources: u32 = MAP_VOL / LAVA_SOURCE_DIVISOR;
    for (0..sources) |_| {
        const sx = rng.next_bounded(W);
        const r1 = rng.next_float();
        const r2 = rng.next_float();
        const sy_fp = r1.mul(r2).mul(FP16.from(WATER - LAVA_DEPTH_OFFSET));
        const sy: u32 = @intCast(@max(1, sy_fp.int()));
        const sz = rng.next_bounded(D);
        bfsFloodDown(blocks, flood_queue, sx, sy, sz, B.Still_Lava);
    }
}

// -- Step 9: Surface -----------------------------------------------------

fn stepSurface(blocks: []u8, heightmap: []const i16, rng: *Xorshift64) void {
    const sand_noise = OctaveNoise.init(rng, 8);
    const gravel_noise = OctaveNoise.init(rng, 8);

    for (0..W) |xi| {
        for (0..D) |zi| {
            const x: u32 = @intCast(xi);
            const z: u32 = @intCast(zi);
            const xfp = FP16.from(@as(i32, @intCast(xi)));
            const zfp = FP16.from(@as(i32, @intCast(zi)));

            const is_sand = sand_noise.compute(xfp, zfp).value > SAND_NOISE_THRESHOLD;
            const is_gravel = gravel_noise.compute(xfp, zfp).value > GRAVEL_NOISE_THRESHOLD;

            const h: i32 = heightmap[hmIdx(x, z)];
            if (h < 1 or h >= @as(i32, H) - 1) continue;
            const y: u32 = @intCast(h);
            const above = blocks[blockIdx(x, y + 1, z)];

            if (above == B.Still_Water and is_gravel) {
                blocks[blockIdx(x, y, z)] = B.Gravel;
            } else if (above == B.Air) {
                if (h <= WATER and is_sand) {
                    blocks[blockIdx(x, y, z)] = B.Sand;
                } else {
                    blocks[blockIdx(x, y, z)] = B.Grass;
                }
            }
        }
    }
}

// -- Step 10: Plants -----------------------------------------------------

pub fn placeTree(blocks: []u8, tx: u32, base_y: u32, tz: u32, height: u32, rng: *Xorshift64) void {
    // Check space
    var check_y: u32 = base_y + 1;
    while (check_y <= base_y + height + 2 and check_y < H) : (check_y += 1) {
        if (blocks[blockIdx(tx, check_y, tz)] != B.Air) return;
    }
    if (base_y + height + 2 >= H) return;

    // Trunk
    for (0..height) |i| {
        const y: u32 = base_y + 1 + @as(u32, @intCast(i));
        if (y < H) blocks[blockIdx(tx, y, tz)] = B.Log;
    }
    // Leaves: 4 layers
    for (0..4) |layer| {
        const y: u32 = base_y + height - 2 + @as(u32, @intCast(layer));
        if (y >= H) continue;
        const r: i32 = if (layer < 2) 2 else 1;
        var dx: i32 = -r;
        while (dx <= r) : (dx += 1) {
            var dz: i32 = -r;
            while (dz <= r) : (dz += 1) {
                if (dx == 0 and dz == 0 and layer < 2) continue;
                // Bottom 2 layers (5x5): corners have 50% chance
                // Top layer 2 (3x3): corners have 50% chance
                // Top layer 3 (3x3): only plus shape, no corners
                if (@abs(dx) == r and @abs(dz) == r) {
                    if (layer == 3 or rng.next_bounded(2) == 0) continue;
                }
                const lx = @as(i32, @intCast(tx)) + dx;
                const lz = @as(i32, @intCast(tz)) + dz;
                if (lx < 0 or lx >= W or lz < 0 or lz >= D) continue;
                const idx = blockIdx(@intCast(lx), y, @intCast(lz));
                if (blocks[idx] == B.Air) blocks[idx] = B.Leaves;
            }
        }
    }
}

fn stepPlants(blocks: []u8, heightmap: []const i16, rng: *Xorshift64) void {
    // Trees
    const tree_patches: u32 = MAP_AREA / TREE_PATCH_DIVISOR;
    for (0..tree_patches) |_| {
        var px: i32 = @intCast(rng.next_bounded(W));
        var pz: i32 = @intCast(rng.next_bounded(D));
        for (0..TREE_ATTEMPTS_OUTER) |_| {
            for (0..TREE_ATTEMPTS_INNER) |_| {
                px += @as(i32, @intCast(rng.next_bounded(PLANT_WANDER_RANGE))) - @as(i32, @intCast(rng.next_bounded(PLANT_WANDER_RANGE)));
                pz += @as(i32, @intCast(rng.next_bounded(PLANT_WANDER_RANGE))) - @as(i32, @intCast(rng.next_bounded(PLANT_WANDER_RANGE)));
                if (px < 0 or px >= W or pz < 0 or pz >= D) continue;
                if (rng.next_float().value > FP_0_25.value) continue;
                const ux: u32 = @intCast(px);
                const uz: u32 = @intCast(pz);
                const h: i32 = heightmap[hmIdx(ux, uz)];
                if (h < WATER or h >= @as(i32, H) - TREE_MIN_HEADROOM) continue;
                const uy: u32 = @intCast(h);
                if (blocks[blockIdx(ux, uy, uz)] != B.Grass) continue;
                const th: u32 = rng.next_bounded(TREE_HEIGHT_VARIANCE) + TREE_MIN_HEIGHT;
                placeTree(blocks, ux, uy, uz, th, rng);
            }
        }
    }
    // Flowers
    placePatches(blocks, heightmap, rng, B.Flower1, MAP_AREA / FLOWER_PATCH_DIVISOR);
    placePatches(blocks, heightmap, rng, B.Flower2, MAP_AREA / FLOWER_PATCH_DIVISOR);
    // Mushrooms (underground)
    placeMushrooms(blocks, heightmap, rng);
}

fn placePatches(blocks: []u8, heightmap: []const i16, rng: *Xorshift64, flower: u8, count: u32) void {
    for (0..count) |_| {
        var px: i32 = @intCast(rng.next_bounded(W));
        var pz: i32 = @intCast(rng.next_bounded(D));
        for (0..FLOWER_GROUPS) |_| {
            for (0..FLOWER_ATTEMPTS) |_| {
                px += @as(i32, @intCast(rng.next_bounded(PLANT_WANDER_RANGE))) - @as(i32, @intCast(rng.next_bounded(PLANT_WANDER_RANGE)));
                pz += @as(i32, @intCast(rng.next_bounded(PLANT_WANDER_RANGE))) - @as(i32, @intCast(rng.next_bounded(PLANT_WANDER_RANGE)));
                if (px < 0 or px >= W or pz < 0 or pz >= D) continue;
                const ux: u32 = @intCast(px);
                const uz: u32 = @intCast(pz);
                const h: i32 = heightmap[hmIdx(ux, uz)];
                if (h < 1 or h >= @as(i32, H) - 1) continue;
                const uy: u32 = @intCast(h + 1);
                if (blocks[blockIdx(ux, uy, uz)] != B.Air) continue;
                if (blocks[blockIdx(ux, @intCast(h), uz)] != B.Grass) continue;
                blocks[blockIdx(ux, uy, uz)] = flower;
            }
        }
    }
}

fn placeMushrooms(blocks: []u8, heightmap: []const i16, rng: *Xorshift64) void {
    const count: u32 = MAP_VOL / MUSHROOM_DIVISOR;
    for (0..count) |_| {
        var px: i32 = @intCast(rng.next_bounded(W));
        var py: i32 = @intCast(rng.next_bounded(H));
        var pz: i32 = @intCast(rng.next_bounded(D));
        const mtype: u8 = if (rng.next_bounded(2) == 0) B.Mushroom1 else B.Mushroom2;
        for (0..MUSHROOM_GROUPS) |_| {
            for (0..MUSHROOM_ATTEMPTS) |_| {
                px += @as(i32, @intCast(rng.next_bounded(PLANT_WANDER_RANGE))) - @as(i32, @intCast(rng.next_bounded(PLANT_WANDER_RANGE)));
                py += @as(i32, @intCast(rng.next_bounded(2))) - @as(i32, @intCast(rng.next_bounded(2)));
                pz += @as(i32, @intCast(rng.next_bounded(PLANT_WANDER_RANGE))) - @as(i32, @intCast(rng.next_bounded(PLANT_WANDER_RANGE)));
                if (px < 0 or px >= W or py < 1 or py >= H or pz < 0 or pz >= D) continue;
                const ux: u32 = @intCast(px);
                const uy: u32 = @intCast(py);
                const uz: u32 = @intCast(pz);
                if (uy >= @as(u32, @intCast(heightmap[hmIdx(ux, uz)]))) continue;
                if (blocks[blockIdx(ux, uy, uz)] != B.Air) continue;
                if (uy < 1) continue;
                if (blocks[blockIdx(ux, uy - 1, uz)] != B.Stone) continue;
                blocks[blockIdx(ux, uy, uz)] = mtype;
            }
        }
    }
}

// -- Public entry point --------------------------------------------------

pub fn generate(scratch: std.mem.Allocator, blocks: []u8, seed: u64, io: std.Io) !void {
    assert(blocks.len == MAP_VOL);
    var rng = Xorshift64.init(seed);

    const heightmap = try scratch.alloc(i16, MAP_AREA);
    defer scratch.free(heightmap);
    const cave_mask = try scratch.alloc(u8, MAP_VOL / 8);
    defer scratch.free(cave_mask);
    const ore_mask = try scratch.alloc(u8, MAP_VOL / 4);
    defer scratch.free(ore_mask);
    const flood_queue = try scratch.alloc(u32, MAP_AREA);
    defer scratch.free(flood_queue);

    var t = std.Io.Clock.Timestamp.now(io, .boot);

    stepRaising(heightmap, &rng);
    t = logStep(io, t, "Raising");

    stepErosion(heightmap, &rng);
    t = logStep(io, t, "Erosion");

    stepStrata(blocks, heightmap, &rng);
    t = logStep(io, t, "Strata");

    @memset(cave_mask, 0);
    @memset(ore_mask, 0);
    stepCaves(cave_mask, &rng);
    t = logStep(io, t, "Caves");

    stepOres(ore_mask, &rng);
    t = logStep(io, t, "Ores");

    stepMerge(blocks, cave_mask, ore_mask);
    t = logStep(io, t, "Merge");

    stepFloodWater(blocks, heightmap, &rng, flood_queue);
    t = logStep(io, t, "Water");

    stepFloodLava(blocks, &rng, flood_queue);
    t = logStep(io, t, "Lava");

    stepSurface(blocks, heightmap, &rng);
    t = logStep(io, t, "Surface");

    stepPlants(blocks, heightmap, &rng);
    _ = logStep(io, t, "Plants");
}

fn logStep(io: std.Io, prev: std.Io.Clock.Timestamp, name: []const u8) std.Io.Clock.Timestamp {
    const now = std.Io.Clock.Timestamp.now(io, .boot);
    const elapsed_ns: i96 = now.raw.nanoseconds - prev.raw.nanoseconds;
    const elapsed_ms = @divTrunc(elapsed_ns, std.time.ns_per_ms);
    log.info("{s}: {d}ms", .{ name, elapsed_ms });
    return now;
}
