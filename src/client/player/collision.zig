/// Player-facing collision facade. Delegates the swept-AABB core to
/// `common.physics` (generic over the world) and keeps the things that
/// are player-specific: body dimensions, liquid classification, and the
/// small `on_ground` spot probe used outside the main tick path.
const std = @import("std");
const World = @import("game").World;
const common = @import("common");
const physics = common.physics;
const c = common.consts;
const Block = c.Block;

// -- Player dimensions -------------------------------------------------------

pub const HALF_W: f32 = 0.3; // half-width on X and Z
pub const HEIGHT: f32 = 1.8; // feet to top of head
pub const EYE_HEIGHT: f32 = 1.59375; // 51/32, feet to camera
pub const STEP_HEIGHT: f32 = 0.5;

/// Collision AABB top of a block, in world-space units. Retained for callers
/// that reason about a single block's height (pending-block virtual-surface
/// clamp, particle ground tests). Full collision uses the richer per-block
/// AABB inside `common.physics`.
pub fn block_height(id: Block) f32 {
    return id.collision_height();
}

// -- Liquid detection --------------------------------------------------------

pub const Liquid = enum { water, lava };

/// Single-point liquid test at the given world coordinate.
/// Used to detect whether the camera is submerged.
pub fn liquid_at_point(px: f32, py: f32, pz: f32) ?Liquid {
    const fx = @floor(px);
    const fy = @floor(py);
    const fz = @floor(pz);
    // Bounds-check as floats first so NaN / extreme values never reach
    // @intFromFloat (which would panic on un-representable values).
    if (fx < 0.0 or fx >= @as(f32, @floatFromInt(c.WorldLength))) return null;
    if (fy < 0.0 or fy >= @as(f32, @floatFromInt(c.WorldHeight))) return null;
    if (fz < 0.0 or fz >= @as(f32, @floatFromInt(c.WorldDepth))) return null;
    const bx: i32 = @intFromFloat(fx);
    const by: i32 = @intFromFloat(fy);
    const bz: i32 = @intFromFloat(fz);
    const block = World.get_block(@intCast(bx), @intCast(by), @intCast(bz));
    return classify_liquid(block);
}

/// Feet zone: the single block-row at floor(py).
pub fn liquid_feet(px: f32, py: f32, pz: f32) ?Liquid {
    const fy = @floor(py);
    if (!safe_for_i32(fy)) return null;
    const by: i32 = @intFromFloat(fy);
    return zone_liquid(px, pz, by, by);
}

/// Body/head zone: from floor(py + 1) up to floor(py + HEIGHT).
pub fn liquid_body(px: f32, py: f32, pz: f32) ?Liquid {
    const fy0 = @floor(py + 1.0);
    const fy1 = @floor(py + HEIGHT);
    if (!safe_for_i32(fy0) or !safe_for_i32(fy1)) return null;
    const by0: i32 = @intFromFloat(fy0);
    const by1: i32 = @intFromFloat(fy1);
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
                if (classify_liquid(block)) |liq| return liq;
            }
        }
    }
    return null;
}

fn classify_liquid(block: Block) ?Liquid {
    return switch (block.fluid_kind()) {
        .water => .water,
        .lava => .lava,
        .none => null,
    };
}

// -- Core collision ----------------------------------------------------------

pub const MoveResult = physics.MoveResult;

/// Resolve a proposed tick of player movement against the world. In-loop
/// step-up is enabled when `was_on_ground` is true; otherwise the player
/// only slides along walls.
pub fn move_and_collide(
    px: f32,
    py: f32,
    pz: f32,
    dx: f32,
    dy: f32,
    dz: f32,
    was_on_ground: bool,
) MoveResult {
    return physics.move_and_wall_slide(
        World,
        .{ px, py, pz },
        .{ dx, dy, dz },
        HALF_W,
        HEIGHT,
        STEP_HEIGHT,
        was_on_ground,
    );
}

/// Check whether the player is resting on a solid surface. Used by a few
/// spot-check paths (e.g. pending-block invariants); the main tick path
/// consumes `MoveResult.on_ground` instead.
pub fn on_ground(px: f32, py: f32, pz: f32) bool {
    return physics.is_on_ground(World, .{ px, py, pz }, HALF_W, HEIGHT);
}

/// Attempt a one-shot step-up at the given horizontal velocity. Independent
/// of the grounded-DidSlide path used by `move_and_collide`; callers invoke
/// this for step-ups that should fire even when airborne (water-to-land
/// exit, where `was_on_ground` is false).
pub fn try_step_up(
    px: f32,
    py: f32,
    pz: f32,
    dx: f32,
    dz: f32,
) ?struct { x: f32, y: f32, z: f32 } {
    const p = physics.try_step_up(World, .{ px, py, pz }, dx, dz, HALF_W, HEIGHT, STEP_HEIGHT) orelse return null;
    return .{ .x = p[0], .y = p[1], .z = p[2] };
}

// -- Internal helpers --------------------------------------------------------

/// True when a floored f32 can be losslessly cast to i32.
fn safe_for_i32(v: f32) bool {
    return v >= -2147483648.0 and v <= 2147483647.0;
}

/// Convert a world coordinate to a block coordinate (handles negatives).
fn world_coord(v: f32) i32 {
    const f = @floor(v);
    if (!safe_for_i32(f)) return if (f < 0.0) std.math.minInt(i32) else std.math.maxInt(i32);
    return @intFromFloat(f);
}
