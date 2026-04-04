/// AABB-to-voxel collision detection and resolution.
/// Pure functions -- no mutable state. Operates on the shared game World.
const std = @import("std");
const World = @import("game").World;
const c = @import("common").consts;
const B = c.Block;

// -- Player dimensions -------------------------------------------------------

pub const HALF_W: f32 = 0.3; // half-width on X and Z
pub const HEIGHT: f32 = 1.8; // feet to top of head
pub const EYE_HEIGHT: f32 = 1.59375; // 51/32, feet to camera
pub const STEP_HEIGHT: f32 = 0.5;

/// Inset applied to the XZ footprint during Y resolution so that wall
/// blocks at the player's horizontal edge are not mistaken for floors/ceilings.
const SKIN: f32 = 0.05;

// -- Collision solidity table (comptime) -------------------------------------

/// True for block IDs the player cannot pass through.
const collision_solid = blk: {
    var table: [256]bool = @splat(false);
    // All defined blocks (1-49) default solid, then carve out passable ones.
    for (1..50) |i| table[i] = true;
    table[B.Sapling] = false;
    table[B.Flowing_Water] = false;
    table[B.Still_Water] = false;
    table[B.Flowing_Lava] = false;
    table[B.Still_Lava] = false;
    table[B.Flower1] = false;
    table[B.Flower2] = false;
    table[B.Mushroom1] = false;
    table[B.Mushroom2] = false;
    break :blk table;
};

/// Collision height of a block: 0.0 (passable), 0.5 (slab), or 1.0 (full).
pub fn block_height(id: u8) f32 {
    if (!collision_solid[id]) return 0.0;
    if (id == B.Slab) return 0.5;
    return 1.0;
}

// -- Liquid detection --------------------------------------------------------

pub const Liquid = enum { water, lava };

/// Feet zone: the single block-row at floor(py).
pub fn liquid_feet(px: f32, py: f32, pz: f32) ?Liquid {
    const by: i32 = @intFromFloat(@floor(py));
    return zone_liquid(px, pz, by, by);
}

/// Body/head zone: from floor(py + 1) up to floor(py + HEIGHT).
pub fn liquid_body(px: f32, py: f32, pz: f32) ?Liquid {
    const by0: i32 = @intFromFloat(@floor(py + 1.0));
    const by1: i32 = @intFromFloat(@floor(py + HEIGHT));
    return zone_liquid(px, pz, by0, by1);
}

/// Scan block rows [by0..by1] across the player XZ footprint for liquid.
fn zone_liquid(px: f32, pz: f32, by0: i32, by1: i32) ?Liquid {
    const min_bx = world_coord(px - HALF_W);
    const max_bx = world_coord(px + HALF_W);
    const min_bz = world_coord(pz - HALF_W);
    const max_bz = world_coord(pz + HALF_W);

    var by: i32 = by0;
    while (by <= by1) : (by += 1) {
        if (by < 0 or by >= c.WorldHeight) continue;
        var bx: i32 = min_bx;
        while (bx <= max_bx) : (bx += 1) {
            if (bx < 0 or bx >= c.WorldLength) continue;
            var bz: i32 = min_bz;
            while (bz <= max_bz) : (bz += 1) {
                if (bz < 0 or bz >= c.WorldDepth) continue;
                const block = World.get_block(@intCast(bx), @intCast(by), @intCast(bz));
                if (block == B.Flowing_Water or block == B.Still_Water) return .water;
                if (block == B.Flowing_Lava or block == B.Still_Lava) return .lava;
            }
        }
    }
    return null;
}

// -- Result types ------------------------------------------------------------

pub const MoveResult = struct {
    x: f32,
    y: f32,
    z: f32,
    on_ground: bool,
    hit_y_above: bool,
    hit_x: bool,
    hit_z: bool,
};

// -- Core collision ----------------------------------------------------------

/// Resolve a proposed movement against the voxel world.
/// Axes are resolved in Y, X, Z order (matching Classic Minecraft).
pub fn move_and_collide(
    px: f32,
    py: f32,
    pz: f32,
    dx: f32,
    dy: f32,
    dz: f32,
) MoveResult {
    var result = MoveResult{
        .x = px,
        .y = py,
        .z = pz,
        .on_ground = false,
        .hit_y_above = false,
        .hit_x = false,
        .hit_z = false,
    };

    // --- Y axis ---
    result.y = py + dy;
    resolve_y(&result, dy, py);

    // --- X axis ---
    result.x = px + dx;
    if (overlaps_solid(result.x - HALF_W, result.y, result.z - HALF_W, result.x + HALF_W, result.y + HEIGHT, result.z + HALF_W)) {
        if (dx > 0) {
            result.x = snap_lo(result.x + HALF_W) - HALF_W;
        } else {
            result.x = snap_hi(result.x - HALF_W) + HALF_W;
        }
        result.hit_x = true;
    }

    // --- Z axis ---
    result.z = pz + dz;
    if (overlaps_solid(result.x - HALF_W, result.y, result.z - HALF_W, result.x + HALF_W, result.y + HEIGHT, result.z + HALF_W)) {
        if (dz > 0) {
            result.z = snap_lo(result.z + HALF_W) - HALF_W;
        } else {
            result.z = snap_hi(result.z - HALF_W) + HALF_W;
        }
        result.hit_z = true;
    }

    // Clamp to world boundaries
    result.x = @max(HALF_W, @min(255.0 + 1.0 - HALF_W, result.x));
    result.z = @max(HALF_W, @min(255.0 + 1.0 - HALF_W, result.z));
    if (result.y < 0) {
        result.y = 0;
        result.on_ground = true;
    }

    return result;
}

/// Check whether the player is resting on a solid surface.
pub fn on_ground(px: f32, py: f32, pz: f32) bool {
    const epsilon: f32 = 0.001;
    const test_y = py - epsilon;
    if (test_y < 0) return true;

    const min_bx = world_coord(px - HALF_W);
    const max_bx = world_coord(px + HALF_W);
    const min_bz = world_coord(pz - HALF_W);
    const max_bz = world_coord(pz + HALF_W);
    const by_raw: i32 = @intFromFloat(@floor(test_y));

    if (by_raw < 0) return true;
    if (by_raw >= c.WorldHeight) return false;
    const by: u16 = @intCast(by_raw);

    var bx_i: i32 = min_bx;
    while (bx_i <= max_bx) : (bx_i += 1) {
        var bz_i: i32 = min_bz;
        while (bz_i <= max_bz) : (bz_i += 1) {
            if (bx_i < 0 or bx_i >= c.WorldLength or bz_i < 0 or bz_i >= c.WorldDepth) continue;
            const block = World.get_block(@intCast(bx_i), by, @intCast(bz_i));
            const bh = block_height(block);
            if (bh == 0.0) continue;
            // Block top surface
            const block_top = @as(f32, @floatFromInt(by)) + bh;
            // Player feet are within epsilon of block top
            if (@abs(py - block_top) < epsilon + 0.01) return true;
        }
    }
    return false;
}

/// Attempt to step up over an obstacle.
/// Returns the stepped position or null if step-up is not possible.
pub fn try_step_up(
    px: f32,
    py: f32,
    pz: f32,
    dx: f32,
    dz: f32,
) ?struct { x: f32, y: f32, z: f32 } {
    // Raise the player up by STEP_HEIGHT
    const raised_y = py + STEP_HEIGHT;

    // Check we have headroom to raise
    if (overlaps_solid(
        px - HALF_W,
        raised_y,
        pz - HALF_W,
        px + HALF_W,
        raised_y + HEIGHT,
        pz + HALF_W,
    )) return null;

    // Try horizontal movement at raised height
    var test_x = px + dx;
    var test_z = pz + dz;

    // Resolve X
    if (overlaps_solid(test_x - HALF_W, raised_y, pz - HALF_W, test_x + HALF_W, raised_y + HEIGHT, pz + HALF_W)) {
        test_x = px; // horizontal blocked even when raised -- abort
    }

    // Resolve Z
    if (overlaps_solid(test_x - HALF_W, raised_y, test_z - HALF_W, test_x + HALF_W, raised_y + HEIGHT, test_z + HALF_W)) {
        test_z = pz;
    }

    // If we didn't move horizontally at all, step-up is pointless
    if (test_x == px and test_z == pz) return null;

    // Lower back down -- find the highest solid surface under the player
    const landed_y = sweep_down(test_x, raised_y, test_z, STEP_HEIGHT);

    // Only accept if we actually ended up higher than where we started
    if (landed_y < py) return null;

    return .{ .x = test_x, .y = landed_y, .z = test_z };
}

/// Try to snap the player down by up to `max_drop` blocks.
/// Returns the new Y (feet) or null if no surface found within range.
pub fn try_snap_down(px: f32, py: f32, pz: f32, max_drop: f32) ?f32 {
    const target_y = py - max_drop;
    if (overlaps_solid(px - HALF_W, target_y, pz - HALF_W, px + HALF_W, target_y + HEIGHT, pz + HALF_W)) {
        // There is solid ground within max_drop -- find exact landing
        const landed = sweep_down(px, py, pz, max_drop);
        if (landed < py) return landed;
    }
    return null;
}

// -- Internal helpers --------------------------------------------------------

/// Resolve the Y component of movement, handling both floor and ceiling.
/// `origin_y` is the player feet Y before this tick's movement.
fn resolve_y(result: *MoveResult, dy: f32, origin_y: f32) void {
    const min_x = result.x - HALF_W + SKIN;
    const max_x = result.x + HALF_W - SKIN;
    const min_z = result.z - HALF_W + SKIN;
    const max_z = result.z + HALF_W - SKIN;

    if (!overlaps_solid(min_x, result.y, min_z, max_x, result.y + HEIGHT, max_z)) return;

    if (dy < 0) {
        // Falling -- snap to highest block top at or below where we started
        result.y = find_floor(min_x, result.y, min_z, max_x, max_z, origin_y);
        result.on_ground = true;
    } else {
        // Rising -- snap below the lowest ceiling block
        result.y = find_ceiling(min_x, result.y, min_z, max_x, result.y + HEIGHT, max_z);
        // Never push below our starting position (wall-block false positive)
        result.y = @max(result.y, origin_y);
        result.hit_y_above = true;
    }
}

/// Find the highest solid surface the player can land on.
/// Only accepts surfaces between `proposed_y` and `ceiling_y` (inclusive).
/// `ceiling_y` is typically the player's pre-movement Y so wall-tops above
/// the player are not mistaken for floors.
fn find_floor(
    min_x: f32,
    proposed_y: f32,
    min_z: f32,
    max_x: f32,
    max_z: f32,
    ceiling_y: f32,
) f32 {
    var best_y = proposed_y;
    const bx0 = world_coord(min_x);
    const bx1 = world_coord(max_x);
    const bz0 = world_coord(min_z);
    const bz1 = world_coord(max_z);
    const by0: i32 = @intFromFloat(@floor(proposed_y));
    const by1: i32 = @intFromFloat(@floor(ceiling_y));

    var by: i32 = by0;
    while (by <= by1) : (by += 1) {
        if (by < 0 or by >= c.WorldHeight) continue;
        var bx: i32 = bx0;
        while (bx <= bx1) : (bx += 1) {
            if (bx < 0 or bx >= c.WorldLength) continue;
            var bz: i32 = bz0;
            while (bz <= bz1) : (bz += 1) {
                if (bz < 0 or bz >= c.WorldDepth) continue;
                const block = World.get_block(@intCast(bx), @intCast(by), @intCast(bz));
                const bh = block_height(block);
                if (bh == 0.0) continue;
                const block_top = @as(f32, @floatFromInt(by)) + bh;
                if (block_top > best_y and block_top <= ceiling_y) {
                    best_y = block_top;
                }
            }
        }
    }
    return best_y;
}

/// Find the lowest ceiling that blocks upward movement.
fn find_ceiling(
    min_x: f32,
    proposed_y: f32,
    min_z: f32,
    max_x: f32,
    head_y: f32,
    max_z: f32,
) f32 {
    var best_y = proposed_y;
    const bx0 = world_coord(min_x);
    const bx1 = world_coord(max_x);
    const bz0 = world_coord(min_z);
    const bz1 = world_coord(max_z);
    const by0: i32 = @intFromFloat(@floor(proposed_y));
    const by1: i32 = @intFromFloat(@floor(head_y));

    var by: i32 = by1;
    while (by >= by0) : (by -= 1) {
        if (by < 0 or by >= c.WorldHeight) continue;
        var bx: i32 = bx0;
        while (bx <= bx1) : (bx += 1) {
            if (bx < 0 or bx >= c.WorldLength) continue;
            var bz: i32 = bz0;
            while (bz <= bz1) : (bz += 1) {
                if (bz < 0 or bz >= c.WorldDepth) continue;
                const block = World.get_block(@intCast(bx), @intCast(by), @intCast(bz));
                const bh = block_height(block);
                if (bh == 0.0) continue;
                const block_bottom: f32 = @floatFromInt(by);
                // Player head is inside this block
                if (head_y > block_bottom and proposed_y < block_bottom + bh) {
                    const clamped = block_bottom - HEIGHT;
                    if (clamped < best_y) best_y = clamped;
                }
            }
        }
    }
    return best_y;
}

/// Sweep the player AABB downward from `start_y` by up to `max_drop`.
/// Returns the Y where the player rests (or start_y - max_drop if nothing hit).
fn sweep_down(px: f32, start_y: f32, pz: f32, max_drop: f32) f32 {
    const target_y = start_y - max_drop;
    const min_x = px - HALF_W;
    const max_x = px + HALF_W;
    const min_z = pz - HALF_W;
    const max_z = pz + HALF_W;

    var best_y = target_y;

    const bx0 = world_coord(min_x);
    const bx1 = world_coord(max_x);
    const bz0 = world_coord(min_z);
    const bz1 = world_coord(max_z);
    const by0: i32 = @intFromFloat(@floor(target_y));
    const by1: i32 = @intFromFloat(@floor(start_y));

    var by: i32 = by0;
    while (by <= by1) : (by += 1) {
        if (by < 0 or by >= c.WorldHeight) continue;
        var bx: i32 = bx0;
        while (bx <= bx1) : (bx += 1) {
            if (bx < 0 or bx >= c.WorldLength) continue;
            var bz: i32 = bz0;
            while (bz <= bz1) : (bz += 1) {
                if (bz < 0 or bz >= c.WorldDepth) continue;
                const block = World.get_block(@intCast(bx), @intCast(by), @intCast(bz));
                const bh = block_height(block);
                if (bh == 0.0) continue;
                const block_top = @as(f32, @floatFromInt(by)) + bh;
                if (block_top > best_y and block_top <= start_y) {
                    best_y = block_top;
                }
            }
        }
    }
    return best_y;
}

/// Test whether any solid block overlaps the given AABB.
fn overlaps_solid(
    min_x: f32,
    min_y: f32,
    min_z: f32,
    max_x: f32,
    max_y: f32,
    max_z: f32,
) bool {
    const bx0 = world_coord(min_x);
    const bx1 = world_coord(max_x - 0.001);
    const bz0 = world_coord(min_z);
    const bz1 = world_coord(max_z - 0.001);
    const by0_raw: i32 = @intFromFloat(@floor(min_y));
    const by1_raw: i32 = @intFromFloat(@floor(max_y - 0.001));

    // Below world floor counts as solid
    if (by0_raw < 0) return true;

    var by: i32 = by0_raw;
    while (by <= by1_raw) : (by += 1) {
        if (by < 0 or by >= c.WorldHeight) continue;
        var bx: i32 = bx0;
        while (bx <= bx1) : (bx += 1) {
            if (bx < 0 or bx >= c.WorldLength) continue;
            var bz: i32 = bz0;
            while (bz <= bz1) : (bz += 1) {
                if (bz < 0 or bz >= c.WorldDepth) continue;
                const block = World.get_block(@intCast(bx), @intCast(by), @intCast(bz));
                const bh = block_height(block);
                if (bh == 0.0) continue;
                // Block AABB: [bx, by, bz] to [bx+1, by+bh, bz+1]
                const block_top = @as(f32, @floatFromInt(by)) + bh;
                const block_y: f32 = @floatFromInt(by);
                if (max_y > block_y and min_y < block_top) return true;
            }
        }
    }
    return false;
}

/// Snap an edge back to the block boundary below it (moving in -dir).
fn snap_lo(edge: f32) f32 {
    return @floor(edge);
}

/// Snap an edge forward to the block boundary above it (moving in +dir).
fn snap_hi(edge: f32) f32 {
    return @floor(edge) + 1.0;
}

/// Convert a world coordinate to a block coordinate (handles negatives).
fn world_coord(v: f32) i32 {
    return @intFromFloat(@floor(v));
}
