const std = @import("std");
const core = @import("core");
const World = core.World;
const physics = core.physics;
const Block = core.blocks.Block;

pub const HalfW: f32 = 0.3;
pub const Height: f32 = 1.8;
pub const EyeHeight: f32 = 1.59375;
pub const StepHeight: f32 = 0.5;

pub const Liquid = enum { water, lava };

pub fn liquid_at_point(px: f32, py: f32, pz: f32) ?Liquid {
    const fx = @floor(px);
    const fy = @floor(py);
    const fz = @floor(pz);
    const dims = World.data.dims;
    // Reject NaN/extreme coordinates before @intFromFloat.
    if (fx < 0.0 or fx >= @as(f32, @floatFromInt(dims.length))) return null;
    if (fy < 0.0 or fy >= @as(f32, @floatFromInt(dims.height))) return null;
    if (fz < 0.0 or fz >= @as(f32, @floatFromInt(dims.depth))) return null;
    const bx: i32 = @intFromFloat(fx);
    const by: i32 = @intFromFloat(fy);
    const bz: i32 = @intFromFloat(fz);
    const block = World.data.get_block(@intCast(bx), @intCast(by), @intCast(bz));
    return classify_liquid(block);
}

/// Feet zone: the single block-row at floor(py).
pub fn liquid_feet(px: f32, py: f32, pz: f32) ?Liquid {
    const fy = @floor(py);
    if (!safe_for_i32(fy)) return null;
    const by: i32 = @intFromFloat(fy);
    return zone_liquid(px, pz, by, by);
}

/// Body/head zone: from floor(py + 1) up to floor(py + Height).
pub fn liquid_body(px: f32, py: f32, pz: f32) ?Liquid {
    const fy0 = @floor(py + 1.0);
    const fy1 = @floor(py + Height);
    if (!safe_for_i32(fy0) or !safe_for_i32(fy1)) return null;
    const by0: i32 = @intFromFloat(fy0);
    const by1: i32 = @intFromFloat(fy1);
    return zone_liquid(px, pz, by0, by1);
}

fn zone_liquid(px: f32, pz: f32, by0: i32, by1: i32) ?Liquid {
    const min_bx = world_coord(px - HalfW);
    const max_bx = world_coord(px + HalfW);
    const min_bz = world_coord(pz - HalfW);
    const max_bz = world_coord(pz + HalfW);
    const dims = World.data.dims;
    const height: i32 = @intCast(dims.height);
    const length: i32 = @intCast(dims.length);
    const depth: i32 = @intCast(dims.depth);

    var by: i32 = by0;
    while (by <= by1) : (by += 1) {
        if (by < 0 or by >= height) continue;
        var bx: i32 = min_bx;
        while (bx <= max_bx) : (bx += 1) {
            if (bx < 0 or bx >= length) continue;
            var bz: i32 = min_bz;
            while (bz <= max_bz) : (bz += 1) {
                if (bz < 0 or bz >= depth) continue;
                const block = World.data.get_block(@intCast(bx), @intCast(by), @intCast(bz));
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
        &World.data,
        .{ px, py, pz },
        .{ dx, dy, dz },
        HalfW,
        Height,
        StepHeight,
        was_on_ground,
    );
}

/// For checks outside the physics tick; movement returns its own on_ground state.
pub fn on_ground(px: f32, py: f32, pz: f32) bool {
    return physics.is_on_ground(&World.data, .{ px, py, pz }, HalfW, Height);
}

/// Allows airborne step-ups when leaving water; grounded movement handles its own.
pub fn try_step_up(
    px: f32,
    py: f32,
    pz: f32,
    dx: f32,
    dz: f32,
) ?struct { x: f32, y: f32, z: f32 } {
    const p = physics.try_step_up(&World.data, .{ px, py, pz }, dx, dz, HalfW, Height, StepHeight) orelse return null;
    return .{ .x = p[0], .y = p[1], .z = p[2] };
}

fn safe_for_i32(v: f32) bool {
    return v >= -2147483648.0 and v <= 2147483647.0;
}

fn world_coord(v: f32) i32 {
    const f = @floor(v);
    if (!safe_for_i32(f)) return if (f < 0.0) std.math.minInt(i32) else std.math.maxInt(i32);
    return @intFromFloat(f);
}
