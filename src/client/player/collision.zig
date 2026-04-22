/// AABB-to-voxel collision detection and resolution.
/// Pure functions -- no mutable state. Operates on the shared game World.
const std = @import("std");
const World = @import("game").World;
const c = @import("common").consts;
const Block = c.Block;
const BlockRegistry = @import("common").BlockRegistry;

// -- Player dimensions -------------------------------------------------------

pub const HALF_W: f32 = 0.3; // half-width on X and Z
pub const HEIGHT: f32 = 1.8; // feet to top of head
pub const EYE_HEIGHT: f32 = 1.59375; // 51/32, feet to camera
pub const STEP_HEIGHT: f32 = 0.5;

/// Used when converting open AABB maxima to inclusive voxel scan ranges.
const EPSILON: f32 = 0.0001;

/// Collision AABB top of a block, in world-space units.
pub fn block_height(id: Block) f32 {
    const h16 = BlockRegistry.global.collision_height_16[@intFromEnum(id.id)];
    return @as(f32, @floatFromInt(h16)) * (1.0 / 16.0);
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
    return switch (BlockRegistry.global.fluid_kind[@intFromEnum(block.id)]) {
        .water => .water,
        .lava => .lava,
        .none => null,
    };
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
/// Axes are clipped in Y, X, Z order (matching Classic Minecraft).
pub fn move_and_collide(
    px: f32,
    py: f32,
    pz: f32,
    dx: f32,
    dy: f32,
    dz: f32,
) MoveResult {
    var box = player_box(px, py, pz);
    const original_dx = dx;
    const original_dy = dy;
    const original_dz = dz;

    const move_y = clip_y(box, dy);
    box.offset_y(move_y);

    const move_x = clip_x(box, dx);
    box.offset_x(move_x);

    const move_z = clip_z(box, dz);
    box.offset_z(move_z);

    return MoveResult{
        .x = box.center_x(),
        .y = box.min_y,
        .z = box.center_z(),
        .on_ground = original_dy != move_y and original_dy < 0.0,
        .hit_y_above = original_dy != move_y and original_dy > 0.0,
        .hit_x = original_dx != move_x,
        .hit_z = original_dz != move_z,
    };
}

/// Check whether the player is resting on a solid surface.
pub fn on_ground(px: f32, py: f32, pz: f32) bool {
    if (py <= 0.0) return true;
    var box = player_box(px, py, pz);
    box.offset_y(-0.001);
    return overlaps_solid_box(box);
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
    const raised_y = py + STEP_HEIGHT;
    if (overlaps_solid(
        px - HALF_W,
        raised_y,
        pz - HALF_W,
        px + HALF_W,
        raised_y + HEIGHT,
        pz + HALF_W,
    )) return null;

    const moved = move_and_collide(px, raised_y, pz, dx, 0.0, dz);
    if (moved.x == px and moved.z == pz) return null;

    const landed_y = find_landing_y(moved.x, raised_y, moved.z, STEP_HEIGHT) orelse return null;

    if (landed_y < py) return null;

    return .{ .x = moved.x, .y = landed_y, .z = moved.z };
}

/// Try to snap the player down by up to `max_drop` blocks.
/// Returns the new Y (feet) or null if no surface found within range.
pub fn try_snap_down(px: f32, py: f32, pz: f32, max_drop: f32) ?f32 {
    const landed = find_landing_y(px, py, pz, max_drop) orelse return null;
    if (landed < py) return landed;
    return null;
}

// -- Internal helpers --------------------------------------------------------

const Aabb = struct {
    min_x: f32,
    min_y: f32,
    min_z: f32,
    max_x: f32,
    max_y: f32,
    max_z: f32,

    fn offset_x(self: *Aabb, x: f32) void {
        self.min_x += x;
        self.max_x += x;
    }

    fn offset_y(self: *Aabb, y: f32) void {
        self.min_y += y;
        self.max_y += y;
    }

    fn offset_z(self: *Aabb, z: f32) void {
        self.min_z += z;
        self.max_z += z;
    }

    fn center_x(self: Aabb) f32 {
        return (self.min_x + self.max_x) * 0.5;
    }

    fn center_z(self: Aabb) f32 {
        return (self.min_z + self.max_z) * 0.5;
    }
};

fn player_box(px: f32, py: f32, pz: f32) Aabb {
    return .{
        .min_x = px - HALF_W,
        .min_y = py,
        .min_z = pz - HALF_W,
        .max_x = px + HALF_W,
        .max_y = py + HEIGHT,
        .max_z = pz + HALF_W,
    };
}

fn block_box(bx: i32, by: i32, bz: i32, height: f32) Aabb {
    return .{
        .min_x = @floatFromInt(bx),
        .min_y = @floatFromInt(by),
        .min_z = @floatFromInt(bz),
        .max_x = @as(f32, @floatFromInt(bx)) + 1.0,
        .max_y = @as(f32, @floatFromInt(by)) + height,
        .max_z = @as(f32, @floatFromInt(bz)) + 1.0,
    };
}

fn clip_y(box: Aabb, dy: f32) f32 {
    if (dy == 0.0) return 0.0;

    var clipped = dy;
    if (dy < 0.0 and box.min_y + dy < 0.0) {
        clipped = @min(-box.min_y, 0.0);
    }
    if (clipped == 0.0) return 0.0;

    var sweep = box;
    if (clipped > 0.0) {
        sweep.max_y += clipped;
    } else {
        sweep.min_y += clipped;
    }

    const range = scan_range(sweep);
    var by = range.by0;
    while (by <= range.by1) : (by += 1) {
        if (by < 0 or by >= c.WorldHeight) continue;
        var bx = range.bx0;
        while (bx <= range.bx1) : (bx += 1) {
            var bz = range.bz0;
            while (bz <= range.bz1) : (bz += 1) {
                clipped = clip_y_block(box, clipped, bx, by, bz);
            }
        }
    }
    return clipped;
}

fn clip_x(box: Aabb, dx: f32) f32 {
    if (dx == 0.0) return 0.0;

    var clipped = clip_x_world(box, dx);
    if (clipped == 0.0) return 0.0;

    var sweep = box;
    if (clipped > 0.0) {
        sweep.max_x += clipped;
    } else {
        sweep.min_x += clipped;
    }

    const range = scan_range(sweep);
    var by = range.by0;
    while (by <= range.by1) : (by += 1) {
        if (by < 0 or by >= c.WorldHeight) continue;
        var bx = range.bx0;
        while (bx <= range.bx1) : (bx += 1) {
            var bz = range.bz0;
            while (bz <= range.bz1) : (bz += 1) {
                clipped = clip_x_block(box, clipped, bx, by, bz);
            }
        }
    }
    return clipped;
}

fn clip_z(box: Aabb, dz: f32) f32 {
    if (dz == 0.0) return 0.0;

    var clipped = clip_z_world(box, dz);
    if (clipped == 0.0) return 0.0;

    var sweep = box;
    if (clipped > 0.0) {
        sweep.max_z += clipped;
    } else {
        sweep.min_z += clipped;
    }

    const range = scan_range(sweep);
    var by = range.by0;
    while (by <= range.by1) : (by += 1) {
        if (by < 0 or by >= c.WorldHeight) continue;
        var bx = range.bx0;
        while (bx <= range.bx1) : (bx += 1) {
            var bz = range.bz0;
            while (bz <= range.bz1) : (bz += 1) {
                clipped = clip_z_block(box, clipped, bx, by, bz);
            }
        }
    }
    return clipped;
}

fn clip_x_world(box: Aabb, dx: f32) f32 {
    if (dx > 0.0) {
        const allowed = @as(f32, @floatFromInt(c.WorldLength)) - box.max_x;
        if (dx > allowed) return @max(0.0, allowed);
    } else {
        const allowed = -box.min_x;
        if (dx < allowed) return @min(0.0, allowed);
    }
    return dx;
}

fn clip_z_world(box: Aabb, dz: f32) f32 {
    if (dz > 0.0) {
        const allowed = @as(f32, @floatFromInt(c.WorldDepth)) - box.max_z;
        if (dz > allowed) return @max(0.0, allowed);
    } else {
        const allowed = -box.min_z;
        if (dz < allowed) return @min(0.0, allowed);
    }
    return dz;
}

fn clip_y_block(box: Aabb, dy: f32, bx: i32, by: i32, bz: i32) f32 {
    const height = solid_height_at(bx, by, bz);
    if (height == 0.0) return dy;
    const block = block_box(bx, by, bz, height);
    if (!overlaps_xz(box, block)) return dy;
    if (dy > 0.0 and block.min_y + EPSILON >= box.max_y) return @min(dy, @max(0.0, block.min_y - box.max_y));
    if (dy < 0.0 and block.max_y - EPSILON <= box.min_y) return @max(dy, @min(0.0, block.max_y - box.min_y));
    return dy;
}

fn clip_x_block(box: Aabb, dx: f32, bx: i32, by: i32, bz: i32) f32 {
    const height = solid_height_at(bx, by, bz);
    if (height == 0.0) return dx;
    const block = block_box(bx, by, bz, height);
    if (!overlaps_yz(box, block)) return dx;
    if (dx > 0.0 and block.min_x + EPSILON >= box.max_x) return @min(dx, @max(0.0, block.min_x - box.max_x));
    if (dx < 0.0 and block.max_x - EPSILON <= box.min_x) return @max(dx, @min(0.0, block.max_x - box.min_x));
    return dx;
}

fn clip_z_block(box: Aabb, dz: f32, bx: i32, by: i32, bz: i32) f32 {
    const height = solid_height_at(bx, by, bz);
    if (height == 0.0) return dz;
    const block = block_box(bx, by, bz, height);
    if (!overlaps_xy(box, block)) return dz;
    if (dz > 0.0 and block.min_z + EPSILON >= box.max_z) return @min(dz, @max(0.0, block.min_z - box.max_z));
    if (dz < 0.0 and block.max_z - EPSILON <= box.min_z) return @max(dz, @min(0.0, block.max_z - box.min_z));
    return dz;
}

/// Find the highest solid top crossed by a downward sweep.
fn find_landing_y(px: f32, start_y: f32, pz: f32, max_drop: f32) ?f32 {
    std.debug.assert(max_drop >= 0.0);

    const target_y = start_y - max_drop;
    const box = player_box(px, start_y, pz);
    var sweep = box;
    sweep.min_y = target_y;

    var landed: ?f32 = null;
    const range = scan_range(sweep);
    var by: i32 = range.by0;
    while (by <= range.by1) : (by += 1) {
        if (by < 0 or by >= c.WorldHeight) continue;
        var bx: i32 = range.bx0;
        while (bx <= range.bx1) : (bx += 1) {
            var bz: i32 = range.bz0;
            while (bz <= range.bz1) : (bz += 1) {
                const height = solid_height_at(bx, by, bz);
                if (height == 0.0) continue;
                const block = block_box(bx, by, bz, height);
                if (!overlaps_xz(box, block)) continue;
                const block_top = block.max_y;
                if (block_top < target_y or block_top > start_y) continue;
                if (landed == null or block_top > landed.?) {
                    landed = block_top;
                }
            }
        }
    }
    return landed;
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
    return overlaps_solid_box(.{
        .min_x = min_x,
        .min_y = min_y,
        .min_z = min_z,
        .max_x = max_x,
        .max_y = max_y,
        .max_z = max_z,
    });
}

fn overlaps_solid_box(box: Aabb) bool {
    if (box.min_y < 0.0) return true;
    if (box.min_x < 0.0 or box.max_x > @as(f32, @floatFromInt(c.WorldLength))) return true;
    if (box.min_z < 0.0 or box.max_z > @as(f32, @floatFromInt(c.WorldDepth))) return true;

    const range = scan_range(box);
    var by: i32 = range.by0;
    while (by <= range.by1) : (by += 1) {
        if (by < 0 or by >= c.WorldHeight) continue;
        var bx: i32 = range.bx0;
        while (bx <= range.bx1) : (bx += 1) {
            var bz: i32 = range.bz0;
            while (bz <= range.bz1) : (bz += 1) {
                const height = solid_height_at(bx, by, bz);
                if (height == 0.0) continue;
                const block = block_box(bx, by, bz, height);
                if (overlaps_xyz(box, block)) return true;
            }
        }
    }
    return false;
}

const ScanRange = struct {
    bx0: i32,
    bx1: i32,
    by0: i32,
    by1: i32,
    bz0: i32,
    bz1: i32,
};

fn scan_range(box: Aabb) ScanRange {
    return .{
        .bx0 = @max(0, world_coord(box.min_x)),
        .bx1 = @min(c.WorldLength - 1, world_coord(box.max_x - EPSILON)),
        .by0 = world_coord(box.min_y),
        .by1 = world_coord(box.max_y - EPSILON),
        .bz0 = @max(0, world_coord(box.min_z)),
        .bz1 = @min(c.WorldDepth - 1, world_coord(box.max_z - EPSILON)),
    };
}

fn solid_height_at(bx: i32, by: i32, bz: i32) f32 {
    if (bx < 0 or bx >= c.WorldLength) return 0.0;
    if (by < 0 or by >= c.WorldHeight) return 0.0;
    if (bz < 0 or bz >= c.WorldDepth) return 0.0;
    return block_height(World.get_block(@intCast(bx), @intCast(by), @intCast(bz)));
}

fn overlaps_xz(a: Aabb, b: Aabb) bool {
    return a.max_x > b.min_x + EPSILON and a.min_x + EPSILON < b.max_x and
        a.max_z > b.min_z + EPSILON and a.min_z + EPSILON < b.max_z;
}

fn overlaps_xy(a: Aabb, b: Aabb) bool {
    return a.max_x > b.min_x + EPSILON and a.min_x + EPSILON < b.max_x and
        a.max_y > b.min_y + EPSILON and a.min_y + EPSILON < b.max_y;
}

fn overlaps_yz(a: Aabb, b: Aabb) bool {
    return a.max_y > b.min_y + EPSILON and a.min_y + EPSILON < b.max_y and
        a.max_z > b.min_z + EPSILON and a.min_z + EPSILON < b.max_z;
}

fn overlaps_xyz(a: Aabb, b: Aabb) bool {
    return overlaps_xy(a, b) and a.max_z > b.min_z and a.min_z < b.max_z;
}

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
