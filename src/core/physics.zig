// Portions adapted from ClassiCube (https://github.com/ClassiCube/ClassiCube) by UnknownShadow200.
// - Swept-AABB resolution (Collisions_MoveAndWallSlide) and per-candidate
//   DidSlide step-up: cross-referenced from src/Physics.c and
//   src/EntityComponents.c.
// See THIRD_PARTY_NOTICES.md for the full BSD 3-Clause license text.
//
// Ported to Zig for CrossCraft (GPLv2; uses separate Aether-Engine).
// Modifications Copyright (c) 2026 CrossCraft

//! Swept-AABB entity/world collision.
//!
//! One tick of motion resolves as:
//!   1. Build the entity AABB and the swept extent (AABB + velocity).
//!   2. Broadphase: gather every solid block intersecting the extent,
//!      tagging each with tSquared = tx^2 + ty^2 + tz^2 (per-axis slab time).
//!   3. Sort candidates ascending by tSquared so closer colliders resolve
//!      first -- no true 3-D sweep time is computed; ordering plus the face
//!      classifier below recover the right clip.
//!   4. For each candidate, recompute per-axis t against the (possibly
//!      clipped) entity, project to contact, pick one face, and clip.
//!      Horizontal clips try step-up first when the entity was grounded.
//!
//! The module lives in `core` and is generic over a caller-provided world
//! type (`anytype`) exposing `get_block(u16, u16, u16) Block`. Block AABBs
//! come from `blocks.global.bounds`.
const std = @import("std");
const consts = @import("consts.zig");
const blocks = @import("blocks.zig");
const Block = blocks.Block;

/// Separation epsilon. Absorbs floating-point slop in face classification
/// and leaves a small gap after each clip so re-intersection is stable.
pub const EPSILON: f32 = 0.001;

/// Sentinel returned by `axis_time` when velocity on that axis is zero.
const MATH_LARGE: f32 = 1.0e9;

/// Hard ceiling on candidate blocks gathered in one tick. 256 * 32 B = 8 KB
/// on stack. See comment on `MAX_TICK_VEL` for the broadphase footprint
/// envelope this is sized against.
const MAX_CANDIDATES: u32 = 256;

/// Per-axis velocity clamp applied before broadphase. Caps the worst-case
/// extent box at ~(2*half_w + 2*MAX_TICK_VEL)^3 cells and keeps the
/// candidate buffer bounded. 5.0 blocks/tick (100 blocks/sec at 20 TPS) is
/// well above terminal velocity (~4.0 under Classic drag/gravity) and any
/// realistic input-driven motion; anything larger indicates a bug upstream.
const MAX_TICK_VEL: f32 = 5.0;

/// Result of `move_and_wall_slide`. `x`/`y`/`z` are the new feet-centred
/// position. Flags record which faces clipped this tick.
pub const MoveResult = struct {
    x: f32,
    y: f32,
    z: f32,
    on_ground: bool,
    hit_y_above: bool,
    hit_x: bool,
    hit_z: bool,
};

const Aabb = struct {
    min_x: f32,
    min_y: f32,
    min_z: f32,
    max_x: f32,
    max_y: f32,
    max_z: f32,
};

const Candidate = struct {
    bounds: Aabb,
    t_squared: f32,
};

const Face = enum { none, y_max, y_min, x_max, x_min, z_max, z_min };

const ResolveState = struct {
    entity: Aabb,
    vel: [3]f32,
    half_w: f32,
    step_size: f32,
    was_on_ground: bool,
    on_ground: bool,
    hit_y_above: bool,
    hit_x: bool,
    hit_z: bool,
};

// --- Public API ---

/// Resolve a proposed tick's worth of movement against the voxel world.
/// `pos` is feet-centred (X/Z = centre, Y = base). `vel` is per-tick
/// displacement (blocks/tick). `half_w` and `height` define the entity AABB.
/// `step_size` > 0 enables in-loop step-up when `was_on_ground` is true;
/// pass 0 to disable.
pub fn move_and_wall_slide(
    comptime WorldT: type,
    pos: [3]f32,
    vel: [3]f32,
    half_w: f32,
    height: f32,
    step_size: f32,
    was_on_ground: bool,
) MoveResult {
    // Degenerate input: no motion -> no clip work; return position verbatim
    // with all flags cleared.
    if (vel[0] == 0.0 and vel[1] == 0.0 and vel[2] == 0.0) {
        return .{
            .x = pos[0],
            .y = pos[1],
            .z = pos[2],
            .on_ground = false,
            .hit_y_above = false,
            .hit_x = false,
            .hit_z = false,
        };
    }

    const v_clamped = [3]f32{
        std.math.clamp(vel[0], -MAX_TICK_VEL, MAX_TICK_VEL),
        std.math.clamp(vel[1], -MAX_TICK_VEL, MAX_TICK_VEL),
        std.math.clamp(vel[2], -MAX_TICK_VEL, MAX_TICK_VEL),
    };

    var state: ResolveState = .{
        .entity = entity_aabb(pos[0], pos[1], pos[2], half_w, height),
        .vel = v_clamped,
        .half_w = half_w,
        .step_size = step_size,
        .was_on_ground = was_on_ground,
        .on_ground = false,
        .hit_y_above = false,
        .hit_x = false,
        .hit_z = false,
    };

    var buf: [MAX_CANDIDATES]Candidate = undefined;
    var count: u32 = 0;
    broadphase(WorldT, state.entity, state.vel, buf[0..], &count);
    insertion_sort(buf[0..count]);

    var i: u32 = 0;
    while (i < count) : (i += 1) {
        resolve_candidate(WorldT, &state, buf[i]);
    }

    // Integrate remaining velocity. Axes that collided are zero (the clip
    // already snapped the entity flush to the face); non-colliding axes
    // retain their original velocity and advance here. Matches CrossCraft's
    // pre-existing move_and_collide contract (returns the post-integration
    // position) rather than a "caller adds velocity" convention.
    state.entity.min_x += state.vel[0];
    state.entity.max_x += state.vel[0];
    state.entity.min_y += state.vel[1];
    state.entity.max_y += state.vel[1];
    state.entity.min_z += state.vel[2];
    state.entity.max_z += state.vel[2];

    return .{
        .x = (state.entity.min_x + state.entity.max_x) * 0.5,
        .y = state.entity.min_y,
        .z = (state.entity.min_z + state.entity.max_z) * 0.5,
        .on_ground = state.on_ground,
        .hit_y_above = state.hit_y_above,
        .hit_x = state.hit_x,
        .hit_z = state.hit_z,
    };
}

/// One-shot step-up probe. Raises feet by `step_size`, slides horizontally
/// by `(dx, dz)` at the raised height, then finds the highest block top
/// crossed by a downward sweep within `step_size`. Returns the landed
/// position or null if the raised box is obstructed or no surface was
/// crossed. Used by callers that want to opt in to a step-up outside the
/// normal grounded-DidSlide path (e.g. water-to-land exit).
pub fn try_step_up(
    comptime WorldT: type,
    pos: [3]f32,
    dx: f32,
    dz: f32,
    half_w: f32,
    height: f32,
    step_size: f32,
) ?[3]f32 {
    std.debug.assert(step_size > 0.0);
    const raised_y = pos[1] + step_size;

    // Clearance at raised height, before horizontal motion.
    const raised = entity_aabb(pos[0], raised_y, pos[2], half_w, height);
    if (overlaps_any_solid(WorldT, raised)) return null;

    // Horizontal slide at raised height. Disable further step-up here
    // (step_size = 0) so probes don't recurse.
    const moved = move_and_wall_slide(WorldT, .{ pos[0], raised_y, pos[2] }, .{ dx, 0.0, dz }, half_w, height, 0.0, false);
    if (moved.x == pos[0] and moved.z == pos[2]) return null;

    // Drop-down to find the surface under the stepped-to position.
    const landed_y = find_landing_y(WorldT, moved.x, raised_y, moved.z, half_w, height, step_size) orelse return null;
    if (landed_y < pos[1]) return null;

    return .{ moved.x, landed_y, moved.z };
}

/// Single-point "is feet flush with a surface" probe. Offsets the entity
/// AABB down by EPSILON and tests for any solid overlap. Used for
/// grounded-state refresh outside the main move (rare -- prefer
/// MoveResult.on_ground).
pub fn is_on_ground(
    comptime WorldT: type,
    pos: [3]f32,
    half_w: f32,
    height: f32,
) bool {
    if (pos[1] <= 0.0) return true;
    var box = entity_aabb(pos[0], pos[1], pos[2], half_w, height);
    box.min_y -= EPSILON;
    box.max_y -= EPSILON;
    return overlaps_any_solid(WorldT, box);
}

// --- Broadphase ---

fn entity_aabb(px: f32, py: f32, pz: f32, half_w: f32, height: f32) Aabb {
    return .{
        .min_x = px - half_w,
        .min_y = py,
        .min_z = pz - half_w,
        .max_x = px + half_w,
        .max_y = py + height,
        .max_z = pz + half_w,
    };
}

fn extent_of(entity: Aabb, vel: [3]f32) Aabb {
    return .{
        .min_x = entity.min_x + @min(vel[0], 0.0),
        .min_y = entity.min_y + @min(vel[1], 0.0),
        .min_z = entity.min_z + @min(vel[2], 0.0),
        .max_x = entity.max_x + @max(vel[0], 0.0),
        .max_y = entity.max_y + @max(vel[1], 0.0),
        .max_z = entity.max_z + @max(vel[2], 0.0),
    };
}

fn broadphase(
    comptime WorldT: type,
    entity: Aabb,
    vel: [3]f32,
    out: []Candidate,
    count: *u32,
) void {
    const extent = extent_of(entity, vel);

    const bx_min: i32 = floor_i32(extent.min_x);
    const by_min: i32 = floor_i32(extent.min_y);
    const bz_min: i32 = floor_i32(extent.min_z);
    const bx_max: i32 = floor_i32(extent.max_x);
    const by_max: i32 = floor_i32(extent.max_y);
    const bz_max: i32 = floor_i32(extent.max_z);

    // YZX order matches the world storage layout; not critical for the few
    // cells this typically visits, but cheap to follow.
    var by: i32 = by_min;
    while (by <= by_max) : (by += 1) {
        var bz: i32 = bz_min;
        while (bz <= bz_max) : (bz += 1) {
            var bx: i32 = bx_min;
            while (bx <= bx_max) : (bx += 1) {
                const bb = solid_block_aabb(WorldT, bx, by, bz) orelse continue;
                // Non-full block bounds may not touch the extent even if
                // the unit cell did; guard the intersection explicitly.
                if (!intersects(extent, bb)) continue;

                const t = calc_time(entity, bb, vel);
                if (t[0] > 1.0 or t[1] > 1.0 or t[2] > 1.0) continue;

                std.debug.assert(count.* < MAX_CANDIDATES);
                if (count.* >= MAX_CANDIDATES) return;
                out[count.*] = .{
                    .bounds = bb,
                    .t_squared = t[0] * t[0] + t[1] * t[1] + t[2] * t[2],
                };
                count.* += 1;
            }
        }
    }
}

/// World-space AABB of a solid block at integer cell (bx, by, bz), or null
/// if the cell is passable. Out-of-bounds treatment:
///
///   y < 0            -> full solid cube (bedrock floor / world bottom).
///   y >= WorldHeight -> passable (no ceiling; entities can jump above).
///   x/z OOB          -> full solid cube (world-edge walls).
///
/// In-bounds cells consult the shared block registry for both solidity
/// (`sim_props.solid`) and geometry (`bounds`), so slabs, flowers, and any
/// future partial shapes automatically get the right AABB.
fn solid_block_aabb(comptime WorldT: type, bx: i32, by: i32, bz: i32) ?Aabb {
    if (by < 0) return full_cube(bx, by, bz);
    if (by >= consts.WorldHeight) return null;
    if (bx < 0 or bx >= consts.WorldLength) return full_cube(bx, by, bz);
    if (bz < 0 or bz >= consts.WorldDepth) return full_cube(bx, by, bz);

    const block = WorldT.get_block(
        @as(u16, @intCast(bx)),
        @as(u16, @intCast(by)),
        @as(u16, @intCast(bz)),
    );
    if (!block.is_solid()) return null;

    const b = block.bounds();
    const fx: f32 = @floatFromInt(bx);
    const fy: f32 = @floatFromInt(by);
    const fz: f32 = @floatFromInt(bz);
    const inv16: f32 = 1.0 / 16.0;
    return .{
        .min_x = fx + @as(f32, @floatFromInt(b.min_x)) * inv16,
        .min_y = fy + @as(f32, @floatFromInt(b.min_y)) * inv16,
        .min_z = fz + @as(f32, @floatFromInt(b.min_z)) * inv16,
        .max_x = fx + @as(f32, @floatFromInt(b.max_x)) * inv16,
        .max_y = fy + @as(f32, @floatFromInt(b.max_y)) * inv16,
        .max_z = fz + @as(f32, @floatFromInt(b.max_z)) * inv16,
    };
}

fn full_cube(bx: i32, by: i32, bz: i32) Aabb {
    const fx: f32 = @floatFromInt(bx);
    const fy: f32 = @floatFromInt(by);
    const fz: f32 = @floatFromInt(bz);
    return .{
        .min_x = fx,
        .min_y = fy,
        .min_z = fz,
        .max_x = fx + 1.0,
        .max_y = fy + 1.0,
        .max_z = fz + 1.0,
    };
}

// --- Narrowphase: per-axis slab time ---

fn calc_time(entity: Aabb, block: Aabb, vel: [3]f32) [3]f32 {
    return .{
        axis_time(entity.min_x, entity.max_x, block.min_x, block.max_x, vel[0]),
        axis_time(entity.min_y, entity.max_y, block.min_y, block.max_y, vel[1]),
        axis_time(entity.min_z, entity.max_z, block.min_z, block.max_z, vel[2]),
    };
}

fn axis_time(e_min: f32, e_max: f32, b_min: f32, b_max: f32, v: f32) f32 {
    // Already overlapping on this axis -> time is 0 so face classification
    // falls on one of the still-moving axes.
    if (e_max >= b_min and e_min <= b_max) return 0.0;
    if (v == 0.0) return MATH_LARGE;
    const d = if (v > 0.0) b_min - e_max else e_min - b_max;
    return @abs(d / v);
}

// --- Sorting ---

fn insertion_sort(buf: []Candidate) void {
    if (buf.len < 2) return;
    var i: usize = 1;
    while (i < buf.len) : (i += 1) {
        const key = buf[i];
        var j: usize = i;
        while (j > 0 and buf[j - 1].t_squared > key.t_squared) : (j -= 1) {
            buf[j] = buf[j - 1];
        }
        buf[j] = key;
    }
}

// --- Resolution ---

fn resolve_candidate(
    comptime WorldT: type,
    state: *ResolveState,
    cand: Candidate,
) void {
    // Earlier clips may have shrunk extent on some axes; re-check overlap
    // before spending effort on this candidate.
    const ext = extent_of(state.entity, state.vel);
    if (!intersects(ext, cand.bounds)) return;

    const t = calc_time(state.entity, cand.bounds, state.vel);
    const final = Aabb{
        .min_x = state.entity.min_x + state.vel[0] * t[0],
        .min_y = state.entity.min_y + state.vel[1] * t[1],
        .min_z = state.entity.min_z + state.vel[2] * t[2],
        .max_x = state.entity.max_x + state.vel[0] * t[0],
        .max_y = state.entity.max_y + state.vel[1] * t[1],
        .max_z = state.entity.max_z + state.vel[2] * t[2],
    };

    const face = classify_face(final, cand.bounds, state.hit_y_above);
    switch (face) {
        .none => {},
        .y_max => clip_y_max(state, cand.bounds),
        .y_min => clip_y_min(state, cand.bounds),
        .x_min => if (!try_step(WorldT, state, final, cand.bounds)) clip_x_min(state, cand.bounds),
        .x_max => if (!try_step(WorldT, state, final, cand.bounds)) clip_x_max(state, cand.bounds),
        .z_min => if (!try_step(WorldT, state, final, cand.bounds)) clip_z_min(state, cand.bounds),
        .z_max => if (!try_step(WorldT, state, final, cand.bounds)) clip_z_max(state, cand.bounds),
    }
}

fn classify_face(final: Aabb, block: Aabb, ceiling_hit: bool) Face {
    if (!ceiling_hit) {
        if (final.min_y + EPSILON >= block.max_y) return .y_max;
        if (final.max_y - EPSILON <= block.min_y) return .y_min;
        if (final.min_x + EPSILON >= block.max_x) return .x_max;
        if (final.max_x - EPSILON <= block.min_x) return .x_min;
        if (final.min_z + EPSILON >= block.max_z) return .z_max;
        if (final.max_z - EPSILON <= block.min_z) return .z_min;
    } else {
        if (final.min_x + EPSILON >= block.max_x) return .x_max;
        if (final.max_x - EPSILON <= block.min_x) return .x_min;
        if (final.min_z + EPSILON >= block.max_z) return .z_max;
        if (final.max_z - EPSILON <= block.min_z) return .z_min;
        if (final.min_y + EPSILON >= block.max_y) return .y_max;
        if (final.max_y - EPSILON <= block.min_y) return .y_min;
    }
    return .none;
}

// --- Clip primitives ---
// Each clip snaps the entity flush to the collided face with a small
// EPSILON gap, zeroes the velocity component on that axis, and sets the
// corresponding hit flag. No helper factoring -- the six are small enough
// that inlining each keeps the code easy to trace against the spec.

fn clip_y_max(state: *ResolveState, block: Aabb) void {
    const height = state.entity.max_y - state.entity.min_y;
    const new_y = block.max_y + EPSILON;
    state.entity.min_y = new_y;
    state.entity.max_y = new_y + height;
    state.vel[1] = 0;
    state.on_ground = true;
}

fn clip_y_min(state: *ResolveState, block: Aabb) void {
    const height = state.entity.max_y - state.entity.min_y;
    const new_y = block.min_y - height - EPSILON;
    state.entity.min_y = new_y;
    state.entity.max_y = new_y + height;
    state.vel[1] = 0;
    state.hit_y_above = true;
}

fn clip_x_max(state: *ResolveState, block: Aabb) void {
    const width = state.entity.max_x - state.entity.min_x;
    const new_min = block.max_x + EPSILON;
    state.entity.min_x = new_min;
    state.entity.max_x = new_min + width;
    state.vel[0] = 0;
    state.hit_x = true;
}

fn clip_x_min(state: *ResolveState, block: Aabb) void {
    const width = state.entity.max_x - state.entity.min_x;
    const new_max = block.min_x - EPSILON;
    state.entity.max_x = new_max;
    state.entity.min_x = new_max - width;
    state.vel[0] = 0;
    state.hit_x = true;
}

fn clip_z_max(state: *ResolveState, block: Aabb) void {
    const depth = state.entity.max_z - state.entity.min_z;
    const new_min = block.max_z + EPSILON;
    state.entity.min_z = new_min;
    state.entity.max_z = new_min + depth;
    state.vel[2] = 0;
    state.hit_z = true;
}

fn clip_z_min(state: *ResolveState, block: Aabb) void {
    const depth = state.entity.max_z - state.entity.min_z;
    const new_max = block.min_z - EPSILON;
    state.entity.max_z = new_max;
    state.entity.min_z = new_max - depth;
    state.vel[2] = 0;
    state.hit_z = true;
}

// --- DidSlide (in-loop step-up) ---

/// In-loop step-up. Gated on `was_on_ground` and `step_size > 0`; computes
/// the raise height from the block top, verifies clearance with a
/// shrunk-footprint box, then raises the entity and zeroes vertical
/// velocity. Returns true if the step succeeded, so the caller can skip
/// the horizontal clip for this candidate.
fn try_step(
    comptime WorldT: type,
    state: *ResolveState,
    final: Aabb,
    block: Aabb,
) bool {
    if (state.step_size <= 0.0) return false;
    if (!state.was_on_ground) return false;

    const y_dist = block.max_y - state.entity.min_y;
    if (y_dist <= 0.0 or y_dist > state.step_size + 0.01) return false;

    const height = state.entity.max_y - state.entity.min_y;
    const new_y = block.max_y + EPSILON;

    const adj = Aabb{
        .min_x = @min(final.min_x, block.min_x + EPSILON),
        .min_y = new_y,
        .min_z = @min(final.min_z, block.min_z + EPSILON),
        .max_x = @max(final.max_x, block.max_x - EPSILON),
        .max_y = new_y + height,
        .max_z = @max(final.max_z, block.max_z - EPSILON),
    };
    if (overlaps_any_solid(WorldT, adj)) return false;

    state.entity.min_y = new_y;
    state.entity.max_y = new_y + height;
    state.vel[1] = 0;
    state.on_ground = true;
    return true;
}

// --- Overlap / landing helpers ---

fn overlaps_any_solid(comptime WorldT: type, box: Aabb) bool {
    const bx_min: i32 = floor_i32(box.min_x);
    const by_min: i32 = floor_i32(box.min_y);
    const bz_min: i32 = floor_i32(box.min_z);
    const bx_max: i32 = floor_i32(box.max_x - EPSILON);
    const by_max: i32 = floor_i32(box.max_y - EPSILON);
    const bz_max: i32 = floor_i32(box.max_z - EPSILON);

    var by: i32 = by_min;
    while (by <= by_max) : (by += 1) {
        var bz: i32 = bz_min;
        while (bz <= bz_max) : (bz += 1) {
            var bx: i32 = bx_min;
            while (bx <= bx_max) : (bx += 1) {
                const bb = solid_block_aabb(WorldT, bx, by, bz) orelse continue;
                if (intersects(box, bb)) return true;
            }
        }
    }
    return false;
}

/// Downward sweep from `start_y` within `max_drop`, returning the highest
/// block top under the entity's XZ footprint. Used by `try_step_up` to
/// settle the feet onto a surface after a raised horizontal move.
fn find_landing_y(
    comptime WorldT: type,
    px: f32,
    start_y: f32,
    pz: f32,
    half_w: f32,
    height: f32,
    max_drop: f32,
) ?f32 {
    std.debug.assert(max_drop >= 0.0);
    const target_y = start_y - max_drop;
    const box = entity_aabb(px, start_y, pz, half_w, height);

    const bx_min: i32 = floor_i32(box.min_x);
    const bx_max: i32 = floor_i32(box.max_x - EPSILON);
    const bz_min: i32 = floor_i32(box.min_z);
    const bz_max: i32 = floor_i32(box.max_z - EPSILON);
    const by_min: i32 = floor_i32(target_y);
    const by_max: i32 = floor_i32(start_y);

    var landed: ?f32 = null;
    var by: i32 = by_min;
    while (by <= by_max) : (by += 1) {
        var bz: i32 = bz_min;
        while (bz <= bz_max) : (bz += 1) {
            var bx: i32 = bx_min;
            while (bx <= bx_max) : (bx += 1) {
                const bb = solid_block_aabb(WorldT, bx, by, bz) orelse continue;
                if (!overlaps_xz(box, bb)) continue;
                if (bb.max_y < target_y or bb.max_y > start_y) continue;
                if (landed == null or bb.max_y > landed.?) landed = bb.max_y;
            }
        }
    }
    return landed;
}

fn intersects(a: Aabb, b: Aabb) bool {
    return a.min_x <= b.max_x and a.max_x >= b.min_x and
        a.min_y <= b.max_y and a.max_y >= b.min_y and
        a.min_z <= b.max_z and a.max_z >= b.min_z;
}

fn overlaps_xz(a: Aabb, b: Aabb) bool {
    return a.max_x > b.min_x + EPSILON and a.min_x + EPSILON < b.max_x and
        a.max_z > b.min_z + EPSILON and a.min_z + EPSILON < b.max_z;
}

/// Floor-to-i32 with NaN / out-of-range clamping so the broadphase never
/// panics on @intFromFloat for pathological inputs. Values outside the
/// i32 range get clamped; the solid_block_aabb OOB check then treats those
/// cells as walls.
fn floor_i32(v: f32) i32 {
    const f = @floor(v);
    if (!(f >= -2147483648.0)) return std.math.minInt(i32);
    if (!(f <= 2147483647.0)) return std.math.maxInt(i32);
    return @intFromFloat(f);
}
