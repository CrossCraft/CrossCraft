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

/// Used when converting open AABB maxima to inclusive voxel scan ranges.
const EPSILON: f32 = 0.0001;

/// Cap on sweep re-iterations after per-axis clip. Three passes is enough
/// to exhaust a 3-axis clip, one extra guards against float-precision
/// corner cases where the same voxel re-reports at t_enter ~ 0.
const MAX_SWEEP_ITERS: u32 = 4;

/// Pull the box out of the contact plane by this much after each hit so
/// the next iteration's t_enter math doesn't see a zero-gap overlap and
/// re-clip against the same voxel at t=0.
const CONTACT_SKIN: f32 = 1.0e-4;

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
    if (block == B.Flowing_Water or block == B.Still_Water) return .water;
    if (block == B.Flowing_Lava or block == B.Still_Lava) return .lava;
    return null;
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
/// Uses a swept-AABB routine so corner/column voxels clip correctly on the
/// first contact axis -- the old Y/X/Z sequential clip let the box slip
/// past a single-block obstacle when the perpendicular axis hadn't moved
/// yet, producing the "phase through one block at chunk borders" bug.
pub fn move_and_collide(
    px: f32,
    py: f32,
    pz: f32,
    dx: f32,
    dy: f32,
    dz: f32,
) MoveResult {
    const start = player_box(px, py, pz);
    const swept = sweep_move(start, dx, dy, dz);

    return MoveResult{
        .x = swept.box.center_x(),
        .y = swept.box.min_y,
        .z = swept.box.center_z(),
        .on_ground = swept.hits.y_neg and dy < 0.0,
        .hit_y_above = swept.hits.y_pos and dy > 0.0,
        .hit_x = swept.hits.x,
        .hit_z = swept.hits.z,
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

// -- Swept AABB --------------------------------------------------------------

const HitAxis = enum { none, x, y_neg, y_pos, z };

const HitFlags = struct {
    x: bool = false,
    y_neg: bool = false,
    y_pos: bool = false,
    z: bool = false,
};

const SweepResult = struct {
    box: Aabb,
    hits: HitFlags,
};

/// Sweep `box` through (dx, dy, dz), clipping against voxel walls and
/// world boundaries. All three axes move together -- a corner/column
/// voxel stops the motion on the axis that made first contact, and the
/// remaining motion retries on the other axes from the contact point.
fn sweep_move(start: Aabb, dx_in: f32, dy_in: f32, dz_in: f32) SweepResult {
    var box = start;
    var dx = dx_in;
    var dy = dy_in;
    var dz = dz_in;
    var hits: HitFlags = .{};

    // World boundary hard walls (x in [0, WorldLength], z in [0, WorldDepth],
    // y >= 0). Clamp once up front so the voxel loop never has to reason
    // about them.
    clip_world_x(&box, &dx, &hits);
    clip_world_z(&box, &dz, &hits);
    clip_world_y_floor(&box, &dy, &hits);

    var iter: u32 = 0;
    while (iter < MAX_SWEEP_ITERS) : (iter += 1) {
        if (dx == 0.0 and dy == 0.0 and dz == 0.0) break;

        const sweep = extend_box(box, dx, dy, dz);
        const range = scan_range(sweep);

        var t_min: f32 = 1.0;
        var axis: HitAxis = .none;

        var by: i32 = range.by0;
        while (by <= range.by1) : (by += 1) {
            if (by < 0 or by >= c.WorldHeight) continue;
            var bx: i32 = range.bx0;
            while (bx <= range.bx1) : (bx += 1) {
                var bz: i32 = range.bz0;
                while (bz <= range.bz1) : (bz += 1) {
                    const height = solid_height_at(bx, by, bz);
                    if (height == 0.0) continue;
                    const blk = block_box(bx, by, bz, height);
                    const hit = voxel_sweep(box, dx, dy, dz, blk);
                    if (hit.axis == .none) continue;
                    if (hit.t_enter < t_min) {
                        t_min = hit.t_enter;
                        axis = hit.axis;
                    }
                }
            }
        }

        if (axis == .none) {
            // Rest of the motion is unobstructed.
            box.offset_x(dx);
            box.offset_y(dy);
            box.offset_z(dz);
            break;
        }

        // Advance to just before the contact plane, zero the hit axis, and
        // loop to let the remaining motion clip on other voxels / axes.
        const safe_t = @max(0.0, t_min - CONTACT_SKIN);
        const move_x = dx * safe_t;
        const move_y = dy * safe_t;
        const move_z = dz * safe_t;
        box.offset_x(move_x);
        box.offset_y(move_y);
        box.offset_z(move_z);
        dx -= move_x;
        dy -= move_y;
        dz -= move_z;
        switch (axis) {
            .x => {
                dx = 0.0;
                hits.x = true;
            },
            .y_neg => {
                dy = 0.0;
                hits.y_neg = true;
            },
            .y_pos => {
                dy = 0.0;
                hits.y_pos = true;
            },
            .z => {
                dz = 0.0;
                hits.z = true;
            },
            .none => unreachable,
        }
    }

    return .{ .box = box, .hits = hits };
}

const VoxelHit = struct { t_enter: f32, axis: HitAxis };

// Q16.16 fixed-point helpers. Slab test runs in integer math because the
// PSP Allegrex FPU's `div.s` faults on inputs (denormals / near-zero
// divisors) that x86/ARM silently clamp.
const Q_FRAC_BITS: u5 = 16;
const Q_ONE: i32 = 1 << Q_FRAC_BITS;

/// Convert f32 to Q16.16, clamping to the i32 range so `@intFromFloat`
/// never sees an out-of-range value.
fn to_q(v: f32) i32 {
    const s = v * @as(f32, @floatFromInt(Q_ONE));
    const clamped = @max(-2147483520.0, @min(2147483520.0, s));
    return @intFromFloat(clamped);
}

/// Q16.16 division with i64 intermediate and i32 saturation. `den` must
/// be non-zero -- callers guard on that before entry.
fn q_div_sat(num: i32, den: i32) i32 {
    const widened: i64 = @as(i64, num) << Q_FRAC_BITS;
    const r: i64 = @divTrunc(widened, @as(i64, den));
    if (r > std.math.maxInt(i32)) return std.math.maxInt(i32);
    if (r < std.math.minInt(i32)) return std.math.minInt(i32);
    return @intCast(r);
}

/// Continuous-time AABB-vs-AABB sweep for one candidate voxel. Returns the
/// entry time (0..1) along the swept motion and which axis caused entry, or
/// `.axis = .none` if there's no hit within [0, 1).
fn voxel_sweep(box: Aabb, dx: f32, dy: f32, dz: f32, blk: Aabb) VoxelHit {
    const bx0 = to_q(box.min_x);
    const by0 = to_q(box.min_y);
    const bz0 = to_q(box.min_z);
    const bx1 = to_q(box.max_x);
    const by1 = to_q(box.max_y);
    const bz1 = to_q(box.max_z);
    const kx0 = to_q(blk.min_x);
    const ky0 = to_q(blk.min_y);
    const kz0 = to_q(blk.min_z);
    const kx1 = to_q(blk.max_x);
    const ky1 = to_q(blk.max_y);
    const kz1 = to_q(blk.max_z);
    const qdx = to_q(dx);
    const qdy = to_q(dy);
    const qdz = to_q(dz);

    var t_enter: i32 = std.math.minInt(i32);
    var t_exit: i32 = std.math.maxInt(i32);
    var enter_axis: HitAxis = .none;

    if (qdx != 0) {
        const te: i32 = if (qdx > 0) q_div_sat(kx0 - bx1, qdx) else q_div_sat(kx1 - bx0, qdx);
        const tx: i32 = if (qdx > 0) q_div_sat(kx1 - bx0, qdx) else q_div_sat(kx0 - bx1, qdx);
        if (te > t_enter) {
            t_enter = te;
            enter_axis = .x;
        }
        if (tx < t_exit) t_exit = tx;
    } else if (bx1 <= kx0 or bx0 >= kx1) {
        return .{ .t_enter = 1.0, .axis = .none };
    }

    if (qdy != 0) {
        const te: i32 = if (qdy > 0) q_div_sat(ky0 - by1, qdy) else q_div_sat(ky1 - by0, qdy);
        const tx: i32 = if (qdy > 0) q_div_sat(ky1 - by0, qdy) else q_div_sat(ky0 - by1, qdy);
        if (te > t_enter) {
            t_enter = te;
            enter_axis = if (qdy > 0) .y_pos else .y_neg;
        }
        if (tx < t_exit) t_exit = tx;
    } else if (by1 <= ky0 or by0 >= ky1) {
        return .{ .t_enter = 1.0, .axis = .none };
    }

    if (qdz != 0) {
        const te: i32 = if (qdz > 0) q_div_sat(kz0 - bz1, qdz) else q_div_sat(kz1 - bz0, qdz);
        const tx: i32 = if (qdz > 0) q_div_sat(kz1 - bz0, qdz) else q_div_sat(kz0 - bz1, qdz);
        if (te > t_enter) {
            t_enter = te;
            enter_axis = .z;
        }
        if (tx < t_exit) t_exit = tx;
    } else if (bz1 <= kz0 or bz0 >= kz1) {
        return .{ .t_enter = 1.0, .axis = .none };
    }

    // Must enter before exiting, and entry must be within this motion
    // window. `t_enter == 0` is a legitimate contact hit (box face flush
    // with block face, moving in); only strictly-negative t_enter means
    // one axis is already penetrated, which we can't resolve via sweep --
    // leave those to the skin-pulled next iteration.
    if (t_enter >= t_exit) return .{ .t_enter = 1.0, .axis = .none };
    if (t_enter < 0) return .{ .t_enter = 1.0, .axis = .none };
    if (t_enter >= Q_ONE) return .{ .t_enter = 1.0, .axis = .none };

    // Multiply by 2^-16 rather than dividing by 65536 -- exact in f32 and
    // avoids `div.s` entirely.
    const Q_ONE_INV: f32 = 1.0 / 65536.0;
    const t_f: f32 = @as(f32, @floatFromInt(t_enter)) * Q_ONE_INV;
    return .{ .t_enter = t_f, .axis = enter_axis };
}

fn extend_box(box: Aabb, dx: f32, dy: f32, dz: f32) Aabb {
    var out = box;
    if (dx > 0.0) out.max_x += dx else if (dx < 0.0) out.min_x += dx;
    if (dy > 0.0) out.max_y += dy else if (dy < 0.0) out.min_y += dy;
    if (dz > 0.0) out.max_z += dz else if (dz < 0.0) out.min_z += dz;
    return out;
}

fn clip_world_x(box: *Aabb, dx: *f32, hits: *HitFlags) void {
    if (dx.* > 0.0) {
        const allowed = @as(f32, @floatFromInt(c.WorldLength)) - box.max_x;
        if (dx.* > allowed) {
            dx.* = @max(0.0, allowed);
            hits.x = true;
        }
    } else if (dx.* < 0.0) {
        const allowed = -box.min_x;
        if (dx.* < allowed) {
            dx.* = @min(0.0, allowed);
            hits.x = true;
        }
    }
}

fn clip_world_z(box: *Aabb, dz: *f32, hits: *HitFlags) void {
    if (dz.* > 0.0) {
        const allowed = @as(f32, @floatFromInt(c.WorldDepth)) - box.max_z;
        if (dz.* > allowed) {
            dz.* = @max(0.0, allowed);
            hits.z = true;
        }
    } else if (dz.* < 0.0) {
        const allowed = -box.min_z;
        if (dz.* < allowed) {
            dz.* = @min(0.0, allowed);
            hits.z = true;
        }
    }
}

fn clip_world_y_floor(box: *Aabb, dy: *f32, hits: *HitFlags) void {
    if (dy.* < 0.0) {
        const allowed = -box.min_y;
        if (dy.* < allowed) {
            dy.* = @min(0.0, allowed);
            hits.y_neg = true;
        }
    }
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
                const blk = block_box(bx, by, bz, height);
                if (!overlaps_xz(box, blk)) continue;
                const block_top = blk.max_y;
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
                const blk = block_box(bx, by, bz, height);
                if (overlaps_xyz(box, blk)) return true;
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
    return a.max_x > b.min_x and a.min_x < b.max_x and
        a.max_z > b.min_z and a.min_z < b.max_z;
}

fn overlaps_xyz(a: Aabb, b: Aabb) bool {
    return a.max_x > b.min_x and a.min_x < b.max_x and
        a.max_y > b.min_y and a.min_y < b.max_y and
        a.max_z > b.min_z and a.min_z < b.max_z;
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
