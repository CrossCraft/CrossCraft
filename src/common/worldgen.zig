const std = @import("std");
const assert = std.debug.assert;
const log = std.log.scoped(.worldgen);
const c = @import("consts.zig");
const FP16 = @import("fp.zig").FP(32, 16, true);
const Xorshift64 = @import("xorshift64.zig").Xorshift64;
const noise = @import("noise.zig");
const OctaveNoise = noise.OctaveNoise;
const CombinedNoise = noise.CombinedNoise;
const sinFP16 = noise.sinFP16;
const cosFP16 = noise.cosFP16;

const B = c.Block;
const W: u32 = c.WorldLength;
const H: u32 = c.WorldHeight;
const D: u32 = c.WorldDepth;
const WATER: i32 = c.Water_Level;
const MAP_AREA: u32 = W * D;
const MAP_VOL: u32 = W * H * D;

// FP16 constants (value = round(x * 65536))
const FP_ONE = noise.FP_ONE;
const FP_1_3: FP16 = .{ .value = 85197 };
const FP_0_8: FP16 = .{ .value = 52429 };
const FP_0_2: FP16 = .{ .value = 13107 };
const FP_0_9: FP16 = .{ .value = 58982 };
const FP_0_75: FP16 = .{ .value = 49152 };
const FP_0_25: FP16 = .{ .value = 16384 };
const RCP_5: FP16 = .{ .value = 13107 };
const RCP_6: FP16 = .{ .value = 10923 };
const RCP_8: FP16 = .{ .value = 8192 };

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

fn runWalker(mask: []u8, mode: MaskMode, rng: *Xorshift64) void {
    var pos_x = FP16.from(@as(i32, @intCast(rng.nextBounded(W))));
    var pos_y = FP16.from(@as(i32, @intCast(rng.nextBounded(H))));
    var pos_z = FP16.from(@as(i32, @intCast(rng.nextBounded(D))));

    var theta: FP16 = .{ .value = @intCast(rng.next() % @as(u64, @intCast(noise.TWO_PI))) };
    var phi: FP16 = .{ .value = @divTrunc(@as(i32, @intCast(rng.next() & 0xFFFF)) - 0x8000, 4) };
    var d_theta: FP16 = .{ .value = 0 };
    var d_phi: FP16 = .{ .value = 0 };

    const cave_radius: FP16 = switch (mode) {
        .cave => rng.nextFloat().mul(rng.nextFloat()).mul(FP16.from(3)).add(FP_ONE),
        else => rng.nextFloat().mul(rng.nextFloat()).add(.{ .value = 32768 }),
    };

    const len_fp = rng.nextFloat().mul(rng.nextFloat());
    const cave_len: u32 = @max(1, @as(u32, @intCast(len_fp.value)) * 200 / 65536);

    var step: u32 = 0;
    while (step < cave_len) : (step += 1) {
        walkerStep(&pos_x, &pos_y, &pos_z, &theta, &phi, &d_theta, &d_phi, rng);
        if (rng.nextFloat().value < FP_0_25.value) continue;

        const jx = @as(i32, @intCast(rng.nextBounded(4))) - 2;
        const jy = @as(i32, @intCast(rng.nextBounded(4))) - 2;
        const jz = @as(i32, @intCast(rng.nextBounded(4))) - 2;
        const cx = pos_x.add(.{ .value = jx * 13107 });
        const cy = pos_y.add(.{ .value = jy * 13107 });
        const cz = pos_z.add(.{ .value = jz * 13107 });

        const r = walkerRadius(cy, cave_radius, step, cave_len, mode);
        if (r > 0) carveSpheroid(mask, cx.int(), cy.int(), cz.int(), r, mode);
    }
}

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
    px.* = px.add(sinFP16(theta.*).mul(cosFP16(phi.*)));
    py.* = py.add(cosFP16(theta.*));
    pz.* = pz.add(sinFP16(phi.*));
    theta.* = theta.add(d_theta.mul(FP_0_2));
    d_theta.* = d_theta.mul(FP_0_9).add(rng.nextFloat()).sub(rng.nextFloat());
    phi.* = .{ .value = @divTrunc(phi.value, 2) + @divTrunc(d_phi.value, 4) };
    d_phi.* = d_phi.mul(FP_0_75).add(rng.nextFloat()).sub(rng.nextFloat());
}

fn walkerRadius(cy: FP16, base: FP16, step: u32, length: u32, mode: MaskMode) i32 {
    const ht_fp = FP16.from(@as(i32, H));
    const diff = ht_fp.sub(cy);
    // height_factor = (H - cy) / H,  scaled by *3+1
    const hf_raw: i64 = @divTrunc(@as(i64, diff.value) * 3, @as(i64, H)) + 0x10000;
    const height_factor: FP16 = .{ .value = @intCast(std.math.clamp(hf_raw, 0, 4 * 0x10000)) };
    // sin envelope over walk length
    const angle: i32 = @intCast(@divTrunc(@as(i64, step) * @as(i64, noise.PI), @as(i64, length)));
    const envelope = sinFP16(.{ .value = angle });
    var r = base.mul(height_factor).mul(envelope);
    // Ore veins are smaller
    if (mode != .cave) r = .{ .value = @divTrunc(r.value, 2) };
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

            const low = cn1.compute(sx, sz).mul(RCP_6).sub(FP16.from(4));
            const high = cn2.compute(sx, sz).mul(RCP_5).add(FP16.from(6));
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
            if (a.value > 2 * 0x10000) {
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
            const dirt_thickness: i32 = @divTrunc(noise_int, 24) - 4;
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
    const count: u32 = MAP_VOL / 8192;
    for (0..count) |_| {
        runWalker(cave_mask, .cave, rng);
    }
}

fn stepOres(ore_mask: []u8, rng: *Xorshift64) void {
    const coal_n: u32 = MAP_VOL * 9 / 163840;
    const iron_n: u32 = MAP_VOL * 7 / 163840;
    const gold_n: u32 = MAP_VOL * 5 / 163840;
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
    const sources: u32 = MAP_AREA / 8000;
    for (0..sources) |_| {
        const sx = rng.nextBounded(W);
        const sy: u32 = @intCast(WATER - 1 - @as(i32, @intCast(rng.nextBounded(2))));
        const sz = rng.nextBounded(D);
        bfsFloodDown(blocks, flood_queue, sx, sy, sz, B.Still_Water);
    }
}

fn stepFloodLava(blocks: []u8, rng: *Xorshift64, flood_queue: []u32) void {
    const sources: u32 = MAP_VOL / 20000;
    for (0..sources) |_| {
        const sx = rng.nextBounded(W);
        const r1 = rng.nextFloat();
        const r2 = rng.nextFloat();
        const sy_fp = r1.mul(r2).mul(FP16.from(WATER - 3));
        const sy: u32 = @intCast(@max(1, sy_fp.int()));
        const sz = rng.nextBounded(D);
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

            const is_sand = sand_noise.compute(xfp, zfp).value > 8 * 0x10000;
            const is_gravel = gravel_noise.compute(xfp, zfp).value > 12 * 0x10000;

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
        const y: u32 = base_y + height - 1 + @as(u32, @intCast(layer));
        if (y >= H) continue;
        const r: i32 = if (layer < 2) 2 else 1;
        var dx: i32 = -r;
        while (dx <= r) : (dx += 1) {
            var dz: i32 = -r;
            while (dz <= r) : (dz += 1) {
                if (dx == 0 and dz == 0 and layer < 2) continue;
                if (@abs(dx) == r and @abs(dz) == r and rng.nextBounded(2) == 0) continue;
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
    const tree_patches: u32 = MAP_AREA / 4000;
    for (0..tree_patches) |_| {
        var px: i32 = @intCast(rng.nextBounded(W));
        var pz: i32 = @intCast(rng.nextBounded(D));
        for (0..20) |_| {
            for (0..20) |_| {
                px += @as(i32, @intCast(rng.nextBounded(6))) - @as(i32, @intCast(rng.nextBounded(6)));
                pz += @as(i32, @intCast(rng.nextBounded(6))) - @as(i32, @intCast(rng.nextBounded(6)));
                if (px < 0 or px >= W or pz < 0 or pz >= D) continue;
                if (rng.nextFloat().value > FP_0_25.value) continue;
                const ux: u32 = @intCast(px);
                const uz: u32 = @intCast(pz);
                const h: i32 = heightmap[hmIdx(ux, uz)];
                if (h < WATER or h >= @as(i32, H) - 8) continue;
                const uy: u32 = @intCast(h);
                if (blocks[blockIdx(ux, uy, uz)] != B.Grass) continue;
                const th: u32 = rng.nextBounded(3) + 4;
                placeTree(blocks, ux, uy, uz, th, rng);
            }
        }
    }
    // Flowers
    placePatches(blocks, heightmap, rng, B.Flower1, MAP_AREA / 3000);
    placePatches(blocks, heightmap, rng, B.Flower2, MAP_AREA / 3000);
    // Mushrooms (underground)
    placeMushrooms(blocks, heightmap, rng);
}

fn placePatches(blocks: []u8, heightmap: []const i16, rng: *Xorshift64, flower: u8, count: u32) void {
    for (0..count) |_| {
        var px: i32 = @intCast(rng.nextBounded(W));
        var pz: i32 = @intCast(rng.nextBounded(D));
        for (0..10) |_| {
            for (0..5) |_| {
                px += @as(i32, @intCast(rng.nextBounded(6))) - @as(i32, @intCast(rng.nextBounded(6)));
                pz += @as(i32, @intCast(rng.nextBounded(6))) - @as(i32, @intCast(rng.nextBounded(6)));
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
    const count: u32 = MAP_VOL / 2000;
    for (0..count) |_| {
        var px: i32 = @intCast(rng.nextBounded(W));
        var py: i32 = @intCast(rng.nextBounded(H));
        var pz: i32 = @intCast(rng.nextBounded(D));
        const mtype: u8 = if (rng.nextBounded(2) == 0) B.Mushroom1 else B.Mushroom2;
        for (0..10) |_| {
            for (0..5) |_| {
                px += @as(i32, @intCast(rng.nextBounded(6))) - @as(i32, @intCast(rng.nextBounded(6)));
                py += @as(i32, @intCast(rng.nextBounded(2))) - @as(i32, @intCast(rng.nextBounded(2)));
                pz += @as(i32, @intCast(rng.nextBounded(6))) - @as(i32, @intCast(rng.nextBounded(6)));
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
