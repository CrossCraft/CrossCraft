// Portions adapted from ClassiCube (https://github.com/ClassiCube/ClassiCube) by UnknownShadow200.
// - Swept-AABB resolution (Collisions_MoveAndWallSlide) and per-candidate
//   DidSlide step-up: cross-referenced from src/Physics.c and
//   src/EntityComponents.c.
// See THIRD_PARTY_NOTICES.md for the full BSD 3-Clause license text.
//
// Ported to Zig for CrossCraft (GPLv2; uses separate Aether-Engine).
// Modifications Copyright (c) 2026 CrossCraft

//! Swept-AABB collisions resolved nearest-first, with grounded step-up.
const std = @import("std");
const assert = std.debug.assert;
const WorldData = @import("world/WorldData.zig");

/// Gap left after clipping to keep repeated collision checks stable.
pub const EPSILON: f32 = 0.001;

const MATH_LARGE: f32 = 1.0e9;

/// A 0.6 x 1.8 player swept at `MAX_TICK_VEL` spans at most 7 x 8 x 7 cells.
const MAX_CANDIDATES = 7 * 8 * 7;

/// Limit the broadphase extent while allowing Classic terminal velocity.
const MAX_TICK_VEL: f32 = 5.0;

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

/// `pos` is feet-centred; `vel` is displacement in blocks per tick.
/// Positive `step_size` enables grounded step-up. Returns the final position.
pub fn move_and_wall_slide(
    data: *const WorldData,
    pos: [3]f32,
    vel: [3]f32,
    half_w: f32,
    height: f32,
    step_size: f32,
    was_on_ground: bool,
) MoveResult {
    assert(std.math.isFinite(vel[0]) and std.math.isFinite(vel[1]) and std.math.isFinite(vel[2]));
    assert(std.math.isFinite(step_size) and step_size >= 0.0);
    // The fixed broadphase capacity assumes at most a 1x2x1 entity.
    assert(half_w > 0.0 and half_w <= 0.5);
    assert(height > 0.0 and height <= 2.0);
    assert(std.math.isFinite(pos[0]) and std.math.isFinite(pos[1]) and std.math.isFinite(pos[2]));
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
    var count: usize = 0;
    broadphase(data, state.entity, state.vel, buf[0..], &count);
    insertion_sort(buf[0..count]);

    for (buf[0..count]) |candidate| resolve_candidate(data, &state, candidate);

    // Clipped axes have already moved and have zero remaining velocity.
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

/// Raise, slide horizontally, and land within `step_size` for water-to-land exits.
/// Returns null when obstructed or no surface above the original feet is reached.
pub fn try_step_up(
    data: *const WorldData,
    pos: [3]f32,
    dx: f32,
    dz: f32,
    half_w: f32,
    height: f32,
    step_size: f32,
) ?[3]f32 {
    assert(step_size > 0.0);
    const raised_y = pos[1] + step_size;

    const raised = entity_aabb(pos[0], raised_y, pos[2], half_w, height);
    if (overlaps_any_solid(data, raised)) return null;

    const moved = move_and_wall_slide(data, .{ pos[0], raised_y, pos[2] }, .{ dx, 0.0, dz }, half_w, height, 0.0, false);
    if (moved.x == pos[0] and moved.z == pos[2]) return null;

    const landed_y = find_landing_y(data, moved.x, raised_y, moved.z, half_w, height, step_size) orelse return null;
    if (landed_y < pos[1]) return null;

    return .{ moved.x, landed_y, moved.z };
}

/// Probe just below the feet when no movement result is available.
pub fn is_on_ground(
    data: *const WorldData,
    pos: [3]f32,
    half_w: f32,
    height: f32,
) bool {
    if (pos[1] <= 0.0) return true;
    var box = entity_aabb(pos[0], pos[1], pos[2], half_w, height);
    box.min_y -= EPSILON;
    box.max_y -= EPSILON;
    return overlaps_any_solid(data, box);
}

fn entity_aabb(px: f32, py: f32, pz: f32, half_w: f32, height: f32) Aabb {
    assert(std.math.isFinite(px) and std.math.isFinite(py) and std.math.isFinite(pz));
    assert(std.math.isFinite(half_w) and half_w > 0.0);
    assert(std.math.isFinite(height) and height > 0.0);
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
    data: *const WorldData,
    entity: Aabb,
    vel: [3]f32,
    out: []Candidate,
    count: *usize,
) void {
    const extent = extent_of(entity, vel);
    assert(count.* == 0);

    const bx_min: i32 = floor_i32(extent.min_x);
    const by_min: i32 = floor_i32(extent.min_y);
    const bz_min: i32 = floor_i32(extent.min_z);
    const bx_max: i32 = floor_i32(extent.max_x);
    const by_max: i32 = floor_i32(extent.max_y);
    const bz_max: i32 = floor_i32(extent.max_z);

    var by: i32 = by_min;
    while (by <= by_max) : (by += 1) {
        var bz: i32 = bz_min;
        while (bz <= bz_max) : (bz += 1) {
            var bx: i32 = bx_min;
            while (bx <= bx_max) : (bx += 1) {
                const bb = solid_block_aabb(data, bx, by, bz) orelse continue;
                if (!intersects(extent, bb)) continue;

                const t = calc_time(entity, bb, vel);
                if (t[0] > 1.0 or t[1] > 1.0 or t[2] > 1.0) continue;

                // Truncating this list would silently miss collisions.
                assert(count.* < out.len);
                out[count.*] = .{
                    .bounds = bb,
                    .t_squared = t[0] * t[0] + t[1] * t[1] + t[2] * t[2],
                };
                count.* += 1;
            }
        }
    }
}

/// World edges have solid floors and walls, but no ceiling.
fn solid_block_aabb(data: *const WorldData, bx: i32, by: i32, bz: i32) ?Aabb {
    if (by < 0) return full_cube(bx, by, bz);
    if (by >= data.dims.height) return null;
    if (bx < 0 or bx >= data.dims.length) return full_cube(bx, by, bz);
    if (bz < 0 or bz >= data.dims.depth) return full_cube(bx, by, bz);

    const block = data.get_block(
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

fn calc_time(entity: Aabb, block: Aabb, vel: [3]f32) [3]f32 {
    return .{
        axis_time(entity.min_x, entity.max_x, block.min_x, block.max_x, vel[0]),
        axis_time(entity.min_y, entity.max_y, block.min_y, block.max_y, vel[1]),
        axis_time(entity.min_z, entity.max_z, block.min_z, block.max_z, vel[2]),
    };
}

fn axis_time(e_min: f32, e_max: f32, b_min: f32, b_max: f32, v: f32) f32 {
    assert(e_min < e_max);
    assert(b_min < b_max);
    // Already overlapping on this axis -> time is 0 so face classification
    // falls on one of the still-moving axes.
    if (e_max >= b_min and e_min <= b_max) return 0.0;
    if (v == 0.0) return MATH_LARGE;
    const d = if (v > 0.0) b_min - e_max else e_min - b_max;
    return @abs(d / v);
}

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

fn resolve_candidate(
    data: *const WorldData,
    state: *ResolveState,
    cand: Candidate,
) void {
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
        .y_max, .y_min => clip(state, cand.bounds, face),
        .x_min, .x_max, .z_min, .z_max => {
            if (!try_step(data, state, final, cand.bounds)) clip(state, cand.bounds, face);
        },
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

fn clip(state: *ResolveState, block: Aabb, face: Face) void {
    switch (face) {
        .y_max => {
            clip_interval(&state.entity.min_y, &state.entity.max_y, &state.vel[1], block.max_y, true);
            state.on_ground = true;
        },
        .y_min => {
            clip_interval(&state.entity.min_y, &state.entity.max_y, &state.vel[1], block.min_y, false);
            state.hit_y_above = true;
        },
        .x_max => clip_interval(&state.entity.min_x, &state.entity.max_x, &state.vel[0], block.max_x, true),
        .x_min => clip_interval(&state.entity.min_x, &state.entity.max_x, &state.vel[0], block.min_x, false),
        .z_max => clip_interval(&state.entity.min_z, &state.entity.max_z, &state.vel[2], block.max_z, true),
        .z_min => clip_interval(&state.entity.min_z, &state.entity.max_z, &state.vel[2], block.min_z, false),
        .none => unreachable,
    }
    if (face == .x_min or face == .x_max) state.hit_x = true;
    if (face == .z_min or face == .z_max) state.hit_z = true;
}

fn clip_interval(min: *f32, max: *f32, velocity: *f32, barrier: f32, move_min: bool) void {
    assert(min.* < max.*);
    assert(std.math.isFinite(barrier));
    const size = max.* - min.*;
    if (move_min) {
        min.* = barrier + EPSILON;
        max.* = min.* + size;
    } else {
        max.* = barrier - EPSILON;
        min.* = max.* - size;
    }
    velocity.* = 0;
}

fn try_step(
    data: *const WorldData,
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
    if (overlaps_any_solid(data, adj)) return false;

    state.entity.min_y = new_y;
    state.entity.max_y = new_y + height;
    state.vel[1] = 0;
    state.on_ground = true;
    return true;
}

fn overlaps_any_solid(data: *const WorldData, box: Aabb) bool {
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
                const bb = solid_block_aabb(data, bx, by, bz) orelse continue;
                if (intersects(box, bb)) return true;
            }
        }
    }
    return false;
}

fn find_landing_y(
    data: *const WorldData,
    px: f32,
    start_y: f32,
    pz: f32,
    half_w: f32,
    height: f32,
    max_drop: f32,
) ?f32 {
    assert(max_drop >= 0.0);
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
                const bb = solid_block_aabb(data, bx, by, bz) orelse continue;
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

/// Clamp invalid coordinates before converting them to cell indices.
fn floor_i32(v: f32) i32 {
    const f = @floor(v);
    if (!(f >= -2147483648.0)) return std.math.minInt(i32);
    if (!(f <= 2147483647.0)) return std.math.maxInt(i32);
    return @intFromFloat(f);
}

test "movement clips against blocks, slabs, ceilings, and world edges" {
    var data: WorldData = undefined;
    try data.init_in_place(std.testing.allocator, @import("world_dims.zig").default, 1);
    defer data.deinit();

    data.blocks[data.get_index(10, 0, 10)] = .stone;
    const floor = move_and_wall_slide(&data, .{ 10.5, 1.4, 10.5 }, .{ 0, -0.6, 0 }, 0.3, 1.8, 0, false);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0 + EPSILON), floor.y, 0.0001);
    try std.testing.expect(floor.on_ground);

    data.blocks[data.get_index(20, 0, 20)] = .slab;
    const slab = move_and_wall_slide(&data, .{ 20.5, 1.0, 20.5 }, .{ 0, -0.8, 0 }, 0.3, 1.8, 0, false);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5 + EPSILON), slab.y, 0.0001);
    try std.testing.expect(slab.on_ground);

    data.blocks[data.get_index(12, 1, 10)] = .stone;
    const wall = move_and_wall_slide(&data, .{ 11.2, 1.0, 10.5 }, .{ 1, 0, 0 }, 0.3, 1.8, 0, false);
    try std.testing.expectApproxEqAbs(@as(f32, 12.0 - EPSILON - 0.3), wall.x, 0.0001);
    try std.testing.expect(wall.hit_x);

    data.blocks[data.get_index(30, 3, 30)] = .stone;
    const ceiling = move_and_wall_slide(&data, .{ 30.5, 1.0, 30.5 }, .{ 0, 0.5, 0 }, 0.3, 1.8, 0, false);
    try std.testing.expectApproxEqAbs(@as(f32, 3.0 - EPSILON - 1.8), ceiling.y, 0.0001);
    try std.testing.expect(ceiling.hit_y_above);

    const edge = move_and_wall_slide(&data, .{ 0.4, 2.0, 10.5 }, .{ -1, 0, 0 }, 0.3, 1.8, 0, false);
    try std.testing.expectApproxEqAbs(@as(f32, EPSILON + 0.3), edge.x, 0.0001);
    try std.testing.expect(edge.hit_x);
}

test "grounded movement steps onto a clear reachable slab" {
    var data: WorldData = undefined;
    try data.init_in_place(std.testing.allocator, @import("world_dims.zig").default, 1);
    defer data.deinit();

    data.blocks[data.get_index(11, 1, 10)] = .slab;
    const stepped = move_and_wall_slide(&data, .{ 10.2, 1.0, 10.5 }, .{ 1.0, 0, 0 }, 0.3, 1.8, 0.5, true);
    try std.testing.expectApproxEqAbs(@as(f32, 11.2), stepped.x, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.5 + EPSILON), stepped.y, 0.0001);
    try std.testing.expect(stepped.on_ground);
    try std.testing.expect(!stepped.hit_x);

    data.blocks[data.get_index(21, 1, 10)] = .slab;
    const airborne = move_and_wall_slide(&data, .{ 20.2, 1.0, 10.5 }, .{ 1.0, 0, 0 }, 0.3, 1.8, 0.5, false);
    try std.testing.expectApproxEqAbs(@as(f32, 21.0 - EPSILON - 0.3), airborne.x, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), airborne.y, 0.0001);
    try std.testing.expect(airborne.hit_x);

    data.blocks[data.get_index(31, 1, 10)] = .stone;
    const too_high = move_and_wall_slide(&data, .{ 30.2, 1.0, 10.5 }, .{ 1.0, 0, 0 }, 0.3, 1.8, 0.5, true);
    try std.testing.expectApproxEqAbs(@as(f32, 31.0 - EPSILON - 0.3), too_high.x, 0.0001);
    try std.testing.expect(too_high.hit_x);

    data.blocks[data.get_index(41, 1, 10)] = .slab;
    data.blocks[data.get_index(41, 3, 10)] = .stone;
    const blocked = move_and_wall_slide(&data, .{ 40.2, 1.0, 10.5 }, .{ 1.0, 0, 0 }, 0.3, 1.8, 0.5, true);
    try std.testing.expectApproxEqAbs(@as(f32, 41.0 - EPSILON - 0.3), blocked.x, 0.0001);
    try std.testing.expect(blocked.hit_x);
}

test "try_step_up lands on a reachable slab and rejects blocked probes" {
    var data: WorldData = undefined;
    try data.init_in_place(std.testing.allocator, @import("world_dims.zig").default, 1);
    defer data.deinit();

    data.blocks[data.get_index(51, 1, 10)] = .slab;
    const stepped = try_step_up(&data, .{ 50.2, 1.0, 10.5 }, 1.0, 0, 0.3, 1.8, 0.5).?;
    try std.testing.expectApproxEqAbs(@as(f32, 51.2), stepped[0], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.5), stepped[1], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 10.5), stepped[2], 0.0001);

    data.blocks[data.get_index(60, 3, 10)] = .stone;
    try std.testing.expectEqual(
        @as(?[3]f32, null),
        try_step_up(&data, .{ 60.2, 1.0, 10.5 }, 1.0, 0, 0.3, 1.8, 0.5),
    );

    data.blocks[data.get_index(71, 1, 10)] = .stone;
    try std.testing.expectEqual(
        @as(?[3]f32, null),
        try_step_up(&data, .{ 70.2, 1.0, 10.5 }, 1.0, 0, 0.3, 1.8, 0.5),
    );
}

test "broadphase holds a maximum-speed dense sweep" {
    var data: WorldData = undefined;
    try data.init_in_place(std.testing.allocator, @import("world_dims.zig").default, 1);
    defer data.deinit();

    for (10..18) |y| {
        for (10..17) |z| {
            for (10..17) |x| {
                data.blocks[data.get_index(@intCast(x), @intCast(y), @intCast(z))] = .stone;
            }
        }
    }

    var candidates: [MAX_CANDIDATES]Candidate = undefined;
    // Check all sweep directions at the largest supported entity size.
    const speeds = [_]f32{ -MAX_TICK_VEL, MAX_TICK_VEL };
    for (speeds) |vx| for (speeds) |vy| for (speeds) |vz| {
        var count: usize = 0;
        broadphase(
            &data,
            entity_aabb(if (vx > 0) 10.5 else 15.5, if (vy > 0) 10.0 else 15.0, if (vz > 0) 10.5 else 15.5, 0.5, 2.0),
            .{ vx, vy, vz },
            &candidates,
            &count,
        );
        try std.testing.expectEqual(@as(usize, 392), count);
    };
}
