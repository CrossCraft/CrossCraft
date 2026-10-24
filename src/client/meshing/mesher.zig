const std = @import("std");
const assert = std.debug.assert;
const core = @import("core");
const World = core.World;
const TextureAtlas = @import("aether").Ui.TextureAtlas;
const Rendering = @import("aether").Rendering;
const Vertex = Rendering.Vertex;
const BatchMesh = Rendering.MeshDataType(Vertex);
const face_mod = @import("face.zig");
const Face = face_mod.Face;

const SectionH: u32 = core.world_dims.chunk_size;
const Block = core.blocks.Block;

/// Whether the cell beside padded (bx, by, bz) across `face` is sunlit.
/// Cells outside the world count as sunlit (sky above, world edge).
fn face_sunlit(snap: *const Snapshot, bx: u32, by: u32, bz: u32, face: Face) bool {
    const nx: u32 = switch (face) {
        .x_pos => bx + 1,
        .x_neg => bx - 1,
        else => bx,
    };
    const ny: u32 = switch (face) {
        .y_pos => by + 1,
        .y_neg => by - 1,
        else => by,
    };
    const nz: u32 = switch (face) {
        .z_pos => bz + 1,
        .z_neg => bz - 1,
        else => bz,
    };
    return cell_sunlit(snap, nx, ny, nz);
}

fn cell_sunlit(snap: *const Snapshot, bx: u32, by: u32, bz: u32) bool {
    assert(bx < BufZ and by < BufY and bz < BufZ);
    const wy: i32 = @as(i32, @intCast(snap.sy * SectionH + by)) - 1;
    if (wy < 0) return true;
    return wy + 1 >= snap.light[bz][bx];
}

/// Bits 1..16 set: the 16 inner columns of the 18-wide padded row.
const SectionMask: u32 = ((@as(u32, 1) << SectionH) - 1) << 1;

const Row = struct {
    opq: u32,
    vis: u32,
    flu: u32,
    cross: u32,
    leaf: u32,
    slab: u32,
    /// Blocks that cull shared faces against the same type.
    glass: u32,
    /// Leaves covered by leaf-or-opaque blocks on all six sides.
    solid_leaf: u32,
};

/// One section plus a one-block neighbor border on every side.
pub const BufY: u32 = SectionH + 2;
pub const BufZ: u32 = SectionH + 2;
pub const SectionBuf = [BufY][BufZ]Row;

pub const SectionCounts = struct {
    opaque_verts: u32,
    transparent_verts: u32,
    fluid_verts: u32,
};

/// Everything a section build reads, captured once so the remaining build steps run without the world lock and can span frames.
/// A streaming world can fill it from a page plus its neighbors' borders.
pub const Snapshot = struct {
    /// Padded [y][z][x]: the section and a one-block border. Cells outside the world hold air; packing classifies them by position.
    blocks: [BufY][BufZ][BufZ]Block,
    /// Light height (y + 1 of the top light blocker) of each padded column [z][x]; 0 outside the world, which reads as sunlit.
    light: [BufZ][BufZ]u8,
    cx: u32,
    sy: u32,
    cz: u32,
    world_length: u32,
    world_height: u32,
    world_depth: u32,
    all_opaque: bool,
};

/// Capture a section for building. The caller holds the world lock.
pub fn gather(snap: *Snapshot, cx: u32, sy: u32, cz: u32) void {
    const dims = World.data.dims;
    assert(cx < dims.chunks_x and sy < dims.chunks_y and cz < dims.chunks_z);
    snap.cx = cx;
    snap.sy = sy;
    snap.cz = cz;
    snap.world_length = dims.length;
    snap.world_height = dims.height;
    snap.world_depth = dims.depth;
    snap.all_opaque = World.data.is_chunk_all_opaque(cx, sy, cz);
    const x0: i32 = @as(i32, @intCast(cx * SectionH)) - 1;
    const z0: i32 = @as(i32, @intCast(cz * SectionH)) - 1;
    const y0: i32 = @as(i32, @intCast(sy * SectionH)) - 1;
    for (0..BufY) |by| {
        const y = y0 + @as(i32, @intCast(by));
        for (0..BufZ) |bz| {
            const z = z0 + @as(i32, @intCast(bz));
            const row = &snap.blocks[by][bz];
            if (y < 0 or y >= dims.height or z < 0 or z >= dims.depth) {
                @memset(row, .air);
                continue;
            }
            // The inner 16 blocks are one contiguous chunk row.
            row[1..17].* = World.data.get_chunk_row(@intCast(cx * SectionH), @intCast(y), @intCast(z)).*;
            row[0] = if (x0 >= 0) World.get_block(@intCast(x0), @intCast(y), @intCast(z)) else .air;
            row[17] = if (x0 + 17 < dims.length) World.get_block(@intCast(x0 + 17), @intCast(y), @intCast(z)) else .air;
        }
    }
    for (0..BufZ) |bz| {
        const z = z0 + @as(i32, @intCast(bz));
        for (0..BufZ) |bx| {
            const x = x0 + @as(i32, @intCast(bx));
            snap.light[bz][bx] = if (x < 0 or z < 0 or x >= dims.length or z >= dims.depth)
                0
            else
                World.data.light_height(@intCast(x), @intCast(z));
        }
    }
}

fn pack_row(snap: *const Snapshot, by: u32, bz: u32) Row {
    const Air: Row = .{ .opq = 0, .vis = 0, .flu = 0, .cross = 0, .leaf = 0, .slab = 0, .glass = 0, .solid_leaf = 0 };
    const Boundary: Row = .{ .opq = 0x3FFFF, .vis = 0, .flu = 0, .cross = 0, .leaf = 0, .slab = 0, .glass = 0, .solid_leaf = 0 };
    const y: i32 = @as(i32, @intCast(snap.sy * SectionH + by)) - 1;
    const z: i32 = @as(i32, @intCast(snap.cz * SectionH + bz)) - 1;
    if (y >= snap.world_height) return Air;
    if (z < 0 or z >= snap.world_depth) return Boundary;
    if (y < 0) return Boundary;

    var opq: u32 = 0;
    var vis: u32 = 0;
    var flu: u32 = 0;
    var cross: u32 = 0;
    var leaf: u32 = 0;
    var slab: u32 = 0;
    var glass: u32 = 0;
    const row = &snap.blocks[by][bz];
    for (0..BufZ) |i| {
        const x: i32 = @as(i32, @intCast(snap.cx * SectionH + i)) - 1;
        if (x < 0 or x >= snap.world_length) {
            opq |= @as(u32, 1) << @intCast(i);
            continue;
        }
        classify_block(row[i], @intCast(i), &opq, &vis, &flu, &cross, &leaf, &slab, &glass);
    }
    return .{ .opq = opq, .vis = vis, .flu = flu, .cross = cross, .leaf = leaf, .slab = slab, .glass = glass, .solid_leaf = 0 };
}

/// Interior leaves join the opaque mesh; the outer shell remains transparent.
/// Border cells conservatively remain outer leaves. Far LOD treats every leaf
/// as interior to provide the cheap opaque-leaf path.
fn compute_solid_leaves(buf: *SectionBuf, near_lod: bool) void {
    if (!near_lod) {
        for (0..BufY) |by| {
            for (0..BufZ) |bz| {
                buf[by][bz].solid_leaf = buf[by][bz].leaf;
            }
        }
        return;
    }
    for (0..BufY) |by| {
        for (0..BufZ) |bz| {
            const cur = &buf[by][bz];
            if (cur.leaf == 0) {
                cur.solid_leaf = 0;
                continue;
            }
            const cov_cur = cur.opq | cur.leaf;

            var cov_zp: u32 = 0;
            if (bz + 1 < BufZ) {
                const n = &buf[by][bz + 1];
                cov_zp = n.opq | n.leaf;
            }
            var cov_zn: u32 = 0;
            if (bz > 0) {
                const n = &buf[by][bz - 1];
                cov_zn = n.opq | n.leaf;
            }
            var cov_yp: u32 = 0;
            if (by + 1 < BufY) {
                const n = &buf[by + 1][bz];
                cov_yp = n.opq | n.leaf;
            }
            var cov_yn: u32 = 0;
            if (by > 0) {
                const n = &buf[by - 1][bz];
                cov_yn = n.opq | n.leaf;
            }

            cur.solid_leaf = cur.leaf &
                (cov_cur >> 1) & (cov_cur << 1) &
                cov_zp & cov_zn & cov_yp & cov_yn;
            assert((cur.solid_leaf & ~cur.leaf) == 0);
        }
    }
}

/// Fill `buf` with the snapshot's row masks.
pub fn pack_section(snap: *const Snapshot, near_lod: bool, buf: *SectionBuf) void {
    for (0..BufY) |by| {
        for (0..BufZ) |bz| {
            buf[by][bz] = if (snap.all_opaque and by >= 1 and by <= 16 and bz >= 1 and bz <= 16)
                pack_row_opaque(snap, @intCast(by), @intCast(bz))
            else
                pack_row(snap, @intCast(by), @intCast(bz));
        }
    }
    if (!snap.all_opaque) compute_solid_leaves(buf, near_lod);
}

/// All-opaque inner rows require classification only at their two borders.
fn pack_row_opaque(snap: *const Snapshot, by: u32, bz: u32) Row {
    var opq: u32 = SectionMask;
    var vis: u32 = SectionMask;
    var flu: u32 = 0;
    var cross: u32 = 0;
    var leaf: u32 = 0;
    var slab: u32 = 0;
    var glass: u32 = 0;
    const row = &snap.blocks[by][bz];
    if (snap.cx == 0) {
        opq |= 1;
    } else {
        classify_block(row[0], 0, &opq, &vis, &flu, &cross, &leaf, &slab, &glass);
    }
    if ((snap.cx + 1) * SectionH >= snap.world_length) {
        opq |= @as(u32, 1) << 17;
    } else {
        classify_block(row[17], 17, &opq, &vis, &flu, &cross, &leaf, &slab, &glass);
    }
    return .{ .opq = opq, .vis = vis, .flu = flu, .cross = cross, .leaf = leaf, .slab = slab, .glass = glass, .solid_leaf = 0 };
}

inline fn classify_block(block: Block, bit_pos: u5, opq: *u32, vis: *u32, flu: *u32, cross_: *u32, leaf_: *u32, slab_: *u32, glass_: *u32) void {
    const p = block.mesh_props();
    const bit: u32 = @as(u32, 1) << bit_pos;
    if (p.@"opaque") opq.* |= bit;
    if (p.visible) vis.* |= bit;
    if (p.fluid) flu.* |= bit;
    if (p.cross) cross_.* |= bit;
    if (p.leaf) leaf_.* |= bit;
    if (p.slab) slab_.* |= bit;
    if (p.glass) glass_.* |= bit;
}

fn pop(v: u32) u32 {
    return @as(u32, @popCount(v));
}

/// Row masks shared by counting and emission; scalar counts avoid retaining
/// another six masks solely for later popcounts.
const FaceMasks = struct {
    // General faces; block properties select the destination mesh.
    x_pos: u32,
    x_neg: u32,
    y_pos: u32,
    y_neg: u32,
    z_pos: u32,
    z_neg: u32,
    // Solid-leaf faces visible through a neighboring outer leaf.
    sl_xp: u32,
    sl_xn: u32,
    sl_yp: u32,
    sl_yn: u32,
    sl_zp: u32,
    sl_zn: u32,
    cross: u32,
    // Fluid overlays on transparent-block boundaries.
    tfl_xp: u32,
    tfl_xn: u32,
    tfl_yp: u32,
    tfl_yn: u32,
    tfl_zp: u32,
    tfl_zn: u32,
    // Slabs route to opaque without acting as cull barriers.
    opq_count: u8,
    flu_count: u8,
    flu_yp_count: u8,
};

fn floor_row(sy: u32) u32 {
    return if (sy == 0) 1 else BufY;
}

fn compute_face_masks(by: u32, bz: u32, buf: *const SectionBuf, floor_by: u32) FaceMasks {
    assert(by > 0 and by < BufY - 1);
    assert(bz > 0 and bz < BufZ - 1);
    const cur = buf[by][bz];

    // Cross-plants are not in vis, so they require a separate empty-row check.
    if (cur.vis == 0 and cur.cross == 0) return std.mem.zeroes(FaceMasks);

    const opq = cur.opq;
    const vis = cur.vis;
    const flu = cur.flu;
    const slab = cur.slab;
    const sleaf = cur.solid_leaf;

    const n_zp = &buf[by][bz + 1];
    const n_zn = &buf[by][bz - 1];
    const n_yp = &buf[by + 1][bz];
    const n_yn = &buf[by - 1][bz];
    const eff_cur = opq | sleaf;
    const eff_zp = n_zp.opq | n_zp.solid_leaf;
    const eff_zn = n_zn.opq | n_zn.solid_leaf;
    const eff_yp = n_yp.opq | n_yp.solid_leaf;
    // The y=0 fluid layer is unreachable, so faces above it can never be seen, therefore they can be culled, saving hugely
    const floor_fluid = if (by - 1 == floor_by) n_yn.flu else 0;
    const eff_yn = n_yn.opq | n_yn.solid_leaf | floor_fluid;

    // A fully opaque 18-bit row surrounded on Y/Z has no emitting masks.
    // Slabs, cross-plants, and fluids never contribute to eff_cur.
    const All18: u32 = (1 << 18) - 1;
    if (eff_cur == All18 and
        (eff_zp & SectionMask) == SectionMask and
        (eff_zn & SectionMask) == SectionMask and
        (eff_yp & SectionMask) == SectionMask and
        (eff_yn & SectionMask) == SectionMask)
    {
        return std.mem.zeroes(FaceMasks);
    }

    const std_vis = (vis & ~flu) & ~sleaf;

    const g = cur.glass;
    const g_xp = g & (g >> 1);
    const g_xn = g & (g << 1);
    const g_zp = g & n_zp.glass;
    const g_zn = g & n_zn.glass;
    const g_yp = g & n_yp.glass;
    const g_yn = g & n_yn.glass;

    const x_pos = (std_vis & ~(eff_cur >> 1) & ~g_xp) & SectionMask;
    const x_neg = (std_vis & ~(eff_cur << 1) & ~g_xn) & SectionMask;
    const z_pos = (std_vis & ~eff_zp & ~g_zp) & SectionMask;
    const z_neg = (std_vis & ~eff_zn & ~g_zn) & SectionMask;
    // The inset slab top cannot touch its upper neighbor and is always visible.
    const y_pos = ((std_vis & ~eff_yp & ~g_yp) | slab) & SectionMask;
    const y_neg = (std_vis & ~eff_yn & ~g_yn) & SectionMask;

    const flu_xp = (flu & ~(eff_cur >> 1) & ~(flu >> 1)) & SectionMask;
    const flu_xn = (flu & ~(eff_cur << 1) & ~(flu << 1)) & SectionMask;
    const flu_zp = (flu & ~eff_zp & ~n_zp.flu) & SectionMask;
    const flu_zn = (flu & ~eff_zn & ~n_zn.flu) & SectionMask;
    // Inset fluid tops emit when exposed. Covered tops retain a one-block
    // border beside exposed fluid to hide the height seam.
    const n_yp_zp = &buf[by + 1][bz + 1];
    const n_yp_zn = &buf[by + 1][bz - 1];
    const eff_yp_zp = n_yp_zp.opq | n_yp_zp.solid_leaf;
    const eff_yp_zn = n_yp_zn.opq | n_yp_zn.solid_leaf;
    const naked_cur = flu & ~n_yp.flu & ~eff_yp;
    const naked_zp = n_zp.flu & ~n_yp_zp.flu & ~eff_yp_zp;
    const naked_zn = n_zn.flu & ~n_yp_zn.flu & ~eff_yp_zn;
    const naked_border = naked_cur | (naked_cur << 1) | (naked_cur >> 1) |
        naked_zp | (naked_zp << 1) | (naked_zp >> 1) |
        naked_zn | (naked_zn << 1) | (naked_zn >> 1);
    const flu_yp_bits = (flu & ~n_yp.flu & (~eff_yp | naked_border)) & SectionMask;
    const flu_yn = (flu & ~eff_yn & ~n_yn.flu) & SectionMask;

    // Only faces adjoining the transparent outer shell expose solid leaves.
    const sl_xp = (sleaf & ~(eff_cur >> 1)) & SectionMask;
    const sl_xn = (sleaf & ~(eff_cur << 1)) & SectionMask;
    const sl_zp = (sleaf & ~eff_zp) & SectionMask;
    const sl_zn = (sleaf & ~eff_zn) & SectionMask;
    const sl_yp = (sleaf & ~eff_yp) & SectionMask;
    const sl_yn = (sleaf & ~eff_yn) & SectionMask;

    // Transparent boundaries receive a fluid-side overlay.
    const trans = std_vis & ~opq;
    const tfl_xp = (trans & (flu >> 1)) & SectionMask;
    const tfl_xn = (trans & (flu << 1)) & SectionMask;
    const tfl_zp = (trans & n_zp.flu) & SectionMask;
    const tfl_zn = (trans & n_zn.flu) & SectionMask;
    const tfl_yp = (trans & n_yp.flu) & SectionMask;
    const tfl_yn = (trans & n_yn.flu & ~floor_fluid) & SectionMask;

    const xp_all = x_pos | flu_xp;
    const xn_all = x_neg | flu_xn;
    const yp_all = y_pos | flu_yp_bits;
    const yn_all = y_neg | flu_yn;
    const zp_all = z_pos | flu_zp;
    const zn_all = z_neg | flu_zn;

    const routed_opq = opq | slab;
    const opq_count: u8 = @intCast(pop(routed_opq & xp_all) + pop(routed_opq & xn_all) +
        pop(routed_opq & zp_all) + pop(routed_opq & zn_all) +
        pop(routed_opq & yp_all) + pop(routed_opq & yn_all));
    const flu_yp_count: u8 = @intCast(pop(flu_yp_bits));
    const flu_count: u8 = @intCast(pop(flu_xp) + pop(flu_xn) +
        pop(flu_zp) + pop(flu_zn) +
        @as(u32, flu_yp_count) + pop(flu_yn));

    return .{
        .x_pos = xp_all,
        .x_neg = xn_all,
        .y_pos = yp_all,
        .y_neg = yn_all,
        .z_pos = zp_all,
        .z_neg = zn_all,
        .sl_xp = sl_xp,
        .sl_xn = sl_xn,
        .sl_yp = sl_yp,
        .sl_yn = sl_yn,
        .sl_zp = sl_zp,
        .sl_zn = sl_zn,
        .cross = cur.cross & SectionMask,
        .tfl_xp = tfl_xp,
        .tfl_xn = tfl_xn,
        .tfl_yp = tfl_yp,
        .tfl_yn = tfl_yn,
        .tfl_zp = tfl_zp,
        .tfl_zn = tfl_zn,
        .opq_count = opq_count,
        .flu_count = flu_count,
        .flu_yp_count = flu_yp_count,
    };
}

fn counts_from_masks(f: FaceMasks) SectionCounts {
    const sl_count = pop(f.sl_xp) + pop(f.sl_xn) + pop(f.sl_zp) + pop(f.sl_zn) + pop(f.sl_yp) + pop(f.sl_yn);
    const all_count = pop(f.x_pos) + pop(f.x_neg) +
        pop(f.z_pos) + pop(f.z_neg) +
        pop(f.y_pos) + pop(f.y_neg);
    const cross_count = pop(f.cross);
    const tfl_count = pop(f.tfl_xp) + pop(f.tfl_xn) +
        pop(f.tfl_zp) + pop(f.tfl_zn) +
        pop(f.tfl_yp) + pop(f.tfl_yn);
    const opq_count: u32 = f.opq_count;
    const flu_count: u32 = f.flu_count;
    const flu_top_extra: u32 = f.flu_yp_count;

    return .{
        .opaque_verts = (opq_count + sl_count) * 6,
        .transparent_verts = (all_count - opq_count - flu_count) * 6 + cross_count * 24,
        .fluid_verts = flu_count * 6 + flu_top_extra * 6 + tfl_count * 6,
    };
}

pub fn count_section(buf: *const SectionBuf, sy: u32) SectionCounts {
    var total: SectionCounts = .{ .opaque_verts = 0, .transparent_verts = 0, .fluid_verts = 0 };
    for (1..BufY - 1) |by| {
        for (1..BufZ - 1) |bz| {
            const f = compute_face_masks(@intCast(by), @intCast(bz), buf, floor_row(sy));
            const row = counts_from_masks(f);
            total.opaque_verts += row.opaque_verts;
            total.transparent_verts += row.transparent_verts;
            total.fluid_verts += row.fluid_verts;
        }
    }
    return total;
}

fn assert_has_room(mesh: *const BatchMesh, quad_count: u32) void {
    const quads: usize = quad_count;
    if (Rendering.mesh.indexing_enabled) {
        assert(mesh.vertices.items.len + quads * 4 <= mesh.vertices.capacity);
        assert(mesh.indices.items.len + quads * 6 <= mesh.indices.capacity);
    } else {
        assert(mesh.vertices.items.len + quads * 6 <= mesh.vertices.capacity);
    }
}

// AO samples two tangent neighbors and their diagonal. Interior leaves cast AO
// because they participate in the effective-opaque mask.

const AoMul: [4]u8 = .{ 128, 170, 212, 255 };

fn eff_bit(buf: *const SectionBuf, by: u32, bz: u32, bit: u32) u32 {
    assert(bit < SectionH + 2);
    const row = &buf[by][bz];
    const eff = row.opq | row.solid_leaf;
    return (eff >> @intCast(bit)) & 1;
}

fn ao_level(t1: u32, t2: u32, d: u32) u32 {
    assert(t1 <= 1 and t2 <= 1 and d <= 1);
    if (t1 != 0 and t2 != 0) return 0;
    return 3 - (t1 + t2 + d);
}

fn ao_modulate(color: u32, level: u32) u32 {
    const m: u32 = AoMul[level];
    const a = color & 0xFF000000;
    const r = (color >> 16) & 0xFF;
    const g = (color >> 8) & 0xFF;
    const b = color & 0xFF;
    return a | (((r * m) >> 8) << 16) | (((g * m) >> 8) << 8) | ((b * m) >> 8);
}

/// Compute the 4 per-corner colors for a cube face at buffer position
/// (by, bz, bit). Vertex order matches `make_quad` for the given face.
fn compute_ao_colors(buf: *const SectionBuf, by: u32, bz: u32, bit: u5, face: Face, shadowed: bool) [4]u32 {
    assert(by > 0 and by < BufY - 1);
    assert(bz > 0 and bz < BufZ - 1);
    assert(bit > 0 and bit <= SectionH);
    const base_unshadowed = face_mod.face_color(face);
    const base: u32 = if (shadowed) face_mod.apply_shadow(base_unshadowed) else base_unshadowed;
    const b: u32 = bit;
    var out: [4]u32 = undefined;

    switch (face) {
        .y_pos => {
            const plane = by + 1;
            // v0 (-X,-Z), v1 (+X,-Z), v2 (+X,+Z), v3 (-X,+Z)
            out[0] = ao_modulate(base, ao_level(eff_bit(buf, plane, bz, b - 1), eff_bit(buf, plane, bz - 1, b), eff_bit(buf, plane, bz - 1, b - 1)));
            out[1] = ao_modulate(base, ao_level(eff_bit(buf, plane, bz, b + 1), eff_bit(buf, plane, bz - 1, b), eff_bit(buf, plane, bz - 1, b + 1)));
            out[2] = ao_modulate(base, ao_level(eff_bit(buf, plane, bz, b + 1), eff_bit(buf, plane, bz + 1, b), eff_bit(buf, plane, bz + 1, b + 1)));
            out[3] = ao_modulate(base, ao_level(eff_bit(buf, plane, bz, b - 1), eff_bit(buf, plane, bz + 1, b), eff_bit(buf, plane, bz + 1, b - 1)));
        },
        .y_neg => {
            const plane = by - 1;
            // v0 (-X,+Z), v1 (+X,+Z), v2 (+X,-Z), v3 (-X,-Z)
            out[0] = ao_modulate(base, ao_level(eff_bit(buf, plane, bz, b - 1), eff_bit(buf, plane, bz + 1, b), eff_bit(buf, plane, bz + 1, b - 1)));
            out[1] = ao_modulate(base, ao_level(eff_bit(buf, plane, bz, b + 1), eff_bit(buf, plane, bz + 1, b), eff_bit(buf, plane, bz + 1, b + 1)));
            out[2] = ao_modulate(base, ao_level(eff_bit(buf, plane, bz, b + 1), eff_bit(buf, plane, bz - 1, b), eff_bit(buf, plane, bz - 1, b + 1)));
            out[3] = ao_modulate(base, ao_level(eff_bit(buf, plane, bz, b - 1), eff_bit(buf, plane, bz - 1, b), eff_bit(buf, plane, bz - 1, b - 1)));
        },
        .x_pos => {
            const bp = b + 1;
            // v0 (-Y,-Z), v1 (-Y,+Z), v2 (+Y,+Z), v3 (+Y,-Z)
            out[0] = ao_modulate(base, ao_level(eff_bit(buf, by - 1, bz, bp), eff_bit(buf, by, bz - 1, bp), eff_bit(buf, by - 1, bz - 1, bp)));
            out[1] = ao_modulate(base, ao_level(eff_bit(buf, by - 1, bz, bp), eff_bit(buf, by, bz + 1, bp), eff_bit(buf, by - 1, bz + 1, bp)));
            out[2] = ao_modulate(base, ao_level(eff_bit(buf, by + 1, bz, bp), eff_bit(buf, by, bz + 1, bp), eff_bit(buf, by + 1, bz + 1, bp)));
            out[3] = ao_modulate(base, ao_level(eff_bit(buf, by + 1, bz, bp), eff_bit(buf, by, bz - 1, bp), eff_bit(buf, by + 1, bz - 1, bp)));
        },
        .x_neg => {
            const bp = b - 1;
            // v0 (-Y,+Z), v1 (-Y,-Z), v2 (+Y,-Z), v3 (+Y,+Z)
            out[0] = ao_modulate(base, ao_level(eff_bit(buf, by - 1, bz, bp), eff_bit(buf, by, bz + 1, bp), eff_bit(buf, by - 1, bz + 1, bp)));
            out[1] = ao_modulate(base, ao_level(eff_bit(buf, by - 1, bz, bp), eff_bit(buf, by, bz - 1, bp), eff_bit(buf, by - 1, bz - 1, bp)));
            out[2] = ao_modulate(base, ao_level(eff_bit(buf, by + 1, bz, bp), eff_bit(buf, by, bz - 1, bp), eff_bit(buf, by + 1, bz - 1, bp)));
            out[3] = ao_modulate(base, ao_level(eff_bit(buf, by + 1, bz, bp), eff_bit(buf, by, bz + 1, bp), eff_bit(buf, by + 1, bz + 1, bp)));
        },
        .z_pos => {
            const plane = bz + 1;
            // v0 (+X,-Y), v1 (-X,-Y), v2 (-X,+Y), v3 (+X,+Y)
            out[0] = ao_modulate(base, ao_level(eff_bit(buf, by, plane, b + 1), eff_bit(buf, by - 1, plane, b), eff_bit(buf, by - 1, plane, b + 1)));
            out[1] = ao_modulate(base, ao_level(eff_bit(buf, by, plane, b - 1), eff_bit(buf, by - 1, plane, b), eff_bit(buf, by - 1, plane, b - 1)));
            out[2] = ao_modulate(base, ao_level(eff_bit(buf, by, plane, b - 1), eff_bit(buf, by + 1, plane, b), eff_bit(buf, by + 1, plane, b - 1)));
            out[3] = ao_modulate(base, ao_level(eff_bit(buf, by, plane, b + 1), eff_bit(buf, by + 1, plane, b), eff_bit(buf, by + 1, plane, b + 1)));
        },
        .z_neg => {
            const plane = bz - 1;
            // v0 (-X,-Y), v1 (+X,-Y), v2 (+X,+Y), v3 (-X,+Y)
            out[0] = ao_modulate(base, ao_level(eff_bit(buf, by, plane, b - 1), eff_bit(buf, by - 1, plane, b), eff_bit(buf, by - 1, plane, b - 1)));
            out[1] = ao_modulate(base, ao_level(eff_bit(buf, by, plane, b + 1), eff_bit(buf, by - 1, plane, b), eff_bit(buf, by - 1, plane, b + 1)));
            out[2] = ao_modulate(base, ao_level(eff_bit(buf, by, plane, b + 1), eff_bit(buf, by + 1, plane, b), eff_bit(buf, by + 1, plane, b + 1)));
            out[3] = ao_modulate(base, ao_level(eff_bit(buf, by, plane, b - 1), eff_bit(buf, by + 1, plane, b), eff_bit(buf, by + 1, plane, b - 1)));
        },
    }
    return out;
}

pub const Meshes = struct {
    @"opaque": *BatchMesh,
    transparent: *BatchMesh,
    fluid: *BatchMesh,
};

fn emit_mask(
    mask: u32,
    snap: *const Snapshot,
    face: Face,
    m: Meshes,
    atlas: *const TextureAtlas,
    buf: *const SectionBuf,
    by: u32,
    bz: u32,
    ao: bool,
) void {
    const local_y: u32 = by - 1;
    const lz: u32 = bz - 1;
    var bits = mask;
    while (bits != 0) {
        const bit_pos: u5 = @intCast(@ctz(bits));
        bits &= bits - 1;

        const lx: u32 = @as(u32, bit_pos) - 1;
        const block = snap.blocks[by][bz][bit_pos];
        const tile = block.face_tile(face);

        const p = block.mesh_props();
        const is_slab = p.slab;
        const is_fluid = p.fluid;
        const mesh = if (p.@"opaque" or is_slab)
            m.@"opaque"
        else if (is_fluid)
            m.fluid
        else
            m.transparent;

        const shadowed = !face_sunlit(snap, bit_pos, by, bz, face) and !p.emits_light;

        if (face == .y_pos and is_fluid) {
            assert_has_room(mesh, 2);
            face_mod.emit_fluid_top(mesh, lx, local_y, lz, tile, atlas, shadowed);
        } else if (is_fluid and face != .y_neg) {
            // Exposed fluid sides meet the inset top; stacked sides remain full-height.
            assert_has_room(mesh, 1);
            const above_is_fluid = ((buf[by + 1][bz].flu >> bit_pos) & 1) != 0;
            face_mod.emit_fluid_side_face(mesh, face, lx, local_y, lz, tile, atlas, shadowed, above_is_fluid);
        } else if (is_slab) {
            assert_has_room(mesh, 1);
            face_mod.emit_slab_face(mesh, face, lx, local_y, lz, tile, atlas, shadowed);
        } else if (ao and !is_fluid) {
            assert_has_room(mesh, 1);
            const colors = compute_ao_colors(buf, by, bz, bit_pos, face, shadowed);
            face_mod.emit_face_colors(mesh, face, lx, local_y, lz, tile, atlas, colors);
        } else {
            assert_has_room(mesh, 1);
            face_mod.emit_face(mesh, face, lx, local_y, lz, tile, atlas, shadowed);
        }
    }
}

fn emit_opaque_leaf_mask(
    mask: u32,
    snap: *const Snapshot,
    face: Face,
    opaque_mesh: *BatchMesh,
    atlas: *const TextureAtlas,
    buf: *const SectionBuf,
    by: u32,
    bz: u32,
    ao: bool,
) void {
    const local_y: u32 = by - 1;
    const lz: u32 = bz - 1;
    var bits = mask;
    while (bits != 0) {
        const bit_pos: u5 = @intCast(@ctz(bits));
        bits &= bits - 1;
        assert_has_room(opaque_mesh, 1);

        const lx: u32 = @as(u32, bit_pos) - 1;
        const block = snap.blocks[by][bz][bit_pos];
        const tile = block.face_tile(face);
        const shadowed = !face_sunlit(snap, bit_pos, by, bz, face);
        if (ao) {
            const colors = compute_ao_colors(buf, by, bz, bit_pos, face, shadowed);
            face_mod.emit_face_colors(opaque_mesh, face, lx, local_y, lz, tile, atlas, colors);
        } else {
            face_mod.emit_face(opaque_mesh, face, lx, local_y, lz, tile, atlas, shadowed);
        }
    }
}

fn emit_cross_mask(
    mask: u32,
    snap: *const Snapshot,
    transparent_mesh: *BatchMesh,
    atlas: *const TextureAtlas,
    by: u32,
    bz: u32,
) void {
    var bits = mask;
    while (bits != 0) {
        const bit_pos: u5 = @intCast(@ctz(bits));
        bits &= bits - 1;
        assert_has_room(transparent_mesh, 4);

        const lx: u32 = @as(u32, bit_pos) - 1;
        const block = snap.blocks[by][bz][bit_pos];
        const tile = block.face_tile(.y_pos);
        face_mod.emit_cross(transparent_mesh, lx, by - 1, bz - 1, tile, atlas, !cell_sunlit(snap, bit_pos, by, bz));
    }
}

/// The overlay takes the neighbor's texture, which may lie in the border.
fn emit_fluid_overlay_mask(
    mask: u32,
    snap: *const Snapshot,
    face: Face,
    fluid_mesh: *BatchMesh,
    atlas: *const TextureAtlas,
    by: u32,
    bz: u32,
) void {
    const ny: u32 = switch (face) {
        .y_pos => by + 1,
        .y_neg => by - 1,
        else => by,
    };
    const nz: u32 = switch (face) {
        .z_pos => bz + 1,
        .z_neg => bz - 1,
        else => bz,
    };
    var bits = mask;
    while (bits != 0) {
        const bit_pos: u5 = @intCast(@ctz(bits));
        bits &= bits - 1;
        assert_has_room(fluid_mesh, 1);

        const nx: u32 = switch (face) {
            .x_pos => @as(u32, bit_pos) + 1,
            .x_neg => @as(u32, bit_pos) - 1,
            else => bit_pos,
        };
        const neighbor = snap.blocks[ny][nz][nx];
        const tile = neighbor.face_tile(face);
        const shadowed = !face_sunlit(snap, bit_pos, by, bz, face) and !neighbor.emits_light();
        face_mod.emit_fluid_overlay(fluid_mesh, face, @as(u32, bit_pos) - 1, by - 1, bz - 1, tile, atlas, shadowed);
    }
}

/// Opaque faces are emitted grouped by direction, in connectivity face order, so renderers can skip directions that cannot face the camera.
pub const opaque_dir_faces = [6]Face{ .x_neg, .x_pos, .y_neg, .y_pos, .z_neg, .z_pos };

/// One row's opaque emission, deferred to the direction-major pass.
const OpaqueRow = struct {
    /// Inner 16 bits of the opaque-routed masks, in `opaque_dir_faces` order.
    faces: [6]u16,
    solid_leaf: [6]u16,
};

/// A section build split into steps short enough to spread across frames.
/// Only `begin` touches the world, through `gather`.
pub const BuildJob = struct {
    snap: Snapshot,
    buf: SectionBuf,
    opaque_rows: [SectionH * SectionH]OpaqueRow,
    opaque_row_used: [SectionH * SectionH]bool,
    counts: SectionCounts,
    connectivity: u16,
    /// First opaque quad of each direction in `opaque_dir_faces` order, then the opaque quad count.
    opaque_dir_start: [7]u16,
    near_lod: bool,
    ao: bool,
    stage: Stage,
    /// Next row of the first emit pass, or next direction of the opaque pass.
    cursor: u32,

    pub const Stage = enum { pack, count, connect, emit_rows, emit_opaque, done };

    /// Rows per first-pass emit step; a quarter of the section.
    const rows_per_step: u32 = 64;

    /// Start a build; the caller holds the world lock.
    pub fn begin(self: *BuildJob, cx: u32, sy: u32, cz: u32, near_lod: bool, ao: bool) void {
        gather(&self.snap, cx, sy, cz);
        self.near_lod = near_lod;
        self.ao = ao;
        self.stage = .pack;
        self.cursor = 0;
    }

    pub fn step_pack(self: *BuildJob) void {
        assert(self.stage == .pack);
        pack_section(&self.snap, self.near_lod, &self.buf);
        self.stage = .count;
    }

    /// Afterwards `counts` holds exact capacities for the output meshes.
    pub fn step_count(self: *BuildJob) void {
        assert(self.stage == .count);
        self.counts = count_section(&self.buf, self.snap.sy);
        self.stage = .connect;
    }

    /// The flood fill is as long as counting on PSP, so it is its own step.
    pub fn step_connect(self: *BuildJob) void {
        assert(self.stage == .connect);
        self.connectivity = section_connectivity(&self.buf);
        self.stage = .emit_rows;
    }

    /// Meshes must start empty with the capacities from `counts`, and stay the same across steps.
    pub fn step_emit(self: *BuildJob, m: Meshes, atlas: *const TextureAtlas) void {
        assert(self.cursor <= SectionH * SectionH);
        switch (self.stage) {
            .emit_rows => {
                const end = if (self.cursor + rows_per_step < SectionH * SectionH) self.cursor + rows_per_step else SectionH * SectionH;
                for (self.cursor..end) |row_index| self.emit_row(@intCast(row_index), m, atlas);
                self.cursor = end;
                if (end == SectionH * SectionH) {
                    // Nothing else routes to the opaque mesh before its pass.
                    assert(m.@"opaque".vertices.items.len == 0);
                    self.stage = .emit_opaque;
                    self.cursor = 0;
                }
            },
            .emit_opaque => {
                const verts_per_quad: usize = if (Rendering.mesh.indexing_enabled) 4 else 6;
                const d = self.cursor;
                const face = opaque_dir_faces[d];
                self.opaque_dir_start[d] = @intCast(m.@"opaque".vertices.items.len / verts_per_quad);
                for (0..SectionH * SectionH) |row_index| {
                    if (!self.opaque_row_used[row_index]) continue;
                    const row = &self.opaque_rows[row_index];
                    const by: u32 = @as(u32, @intCast(row_index / SectionH)) + 1;
                    const bz: u32 = @as(u32, @intCast(row_index % SectionH)) + 1;
                    const faces = @as(u32, row.faces[d]) << 1;
                    const leaves = @as(u32, row.solid_leaf[d]) << 1;
                    if (faces != 0) emit_mask(faces, &self.snap, face, m, atlas, &self.buf, by, bz, self.ao);
                    if (leaves != 0) emit_opaque_leaf_mask(leaves, &self.snap, face, m.@"opaque", atlas, &self.buf, by, bz, self.ao);
                }
                self.cursor += 1;
                if (self.cursor == opaque_dir_faces.len) {
                    self.opaque_dir_start[6] = @intCast(m.@"opaque".vertices.items.len / verts_per_quad);
                    self.stage = .done;
                }
            },
            else => unreachable,
        }
    }

    /// Emit a row's transparent and fluid geometry and defer its opaque faces.
    fn emit_row(self: *BuildJob, row_index: u32, m: Meshes, atlas: *const TextureAtlas) void {
        const by: u32 = row_index / SectionH + 1;
        const bz: u32 = row_index % SectionH + 1;
        self.opaque_row_used[row_index] = false;
        const buf = &self.buf;
        const f = compute_face_masks(by, bz, buf, floor_row(self.snap.sy));

        const any = f.x_pos | f.x_neg | f.y_pos | f.y_neg | f.z_pos | f.z_neg |
            f.sl_xp | f.sl_xn | f.sl_yp | f.sl_yn | f.sl_zp | f.sl_zn |
            f.cross |
            f.tfl_xp | f.tfl_xn | f.tfl_yp | f.tfl_yn | f.tfl_zp | f.tfl_zn;
        if (any == 0) return;

        // Matches emit_mask's routing: opaque blocks and slabs go to the opaque mesh.
        const routed = buf[by][bz].opq | buf[by][bz].slab;
        const dir_masks = [6]u32{ f.x_neg, f.x_pos, f.y_neg, f.y_pos, f.z_neg, f.z_pos };
        const leaf_masks = [6]u32{ f.sl_xn, f.sl_xp, f.sl_yn, f.sl_yp, f.sl_zn, f.sl_zp };
        var deferred: u32 = 0;
        const row = &self.opaque_rows[row_index];
        for (dir_masks, leaf_masks, 0..) |mask, leaf, d| {
            row.faces[d] = @truncate((mask & routed) >> 1);
            row.solid_leaf[d] = @truncate(leaf >> 1);
            deferred |= (mask & routed) | leaf;
            const rest = mask & ~routed;
            if (rest != 0) emit_mask(rest, &self.snap, opaque_dir_faces[d], m, atlas, buf, by, bz, self.ao);
        }
        self.opaque_row_used[row_index] = deferred != 0;

        if (f.cross != 0) emit_cross_mask(f.cross, &self.snap, m.transparent, atlas, by, bz);

        if (f.tfl_xp != 0) emit_fluid_overlay_mask(f.tfl_xp, &self.snap, .x_pos, m.fluid, atlas, by, bz);
        if (f.tfl_xn != 0) emit_fluid_overlay_mask(f.tfl_xn, &self.snap, .x_neg, m.fluid, atlas, by, bz);
        if (f.tfl_zp != 0) emit_fluid_overlay_mask(f.tfl_zp, &self.snap, .z_pos, m.fluid, atlas, by, bz);
        if (f.tfl_zn != 0) emit_fluid_overlay_mask(f.tfl_zn, &self.snap, .z_neg, m.fluid, atlas, by, bz);
        if (f.tfl_yp != 0) emit_fluid_overlay_mask(f.tfl_yp, &self.snap, .y_pos, m.fluid, atlas, by, bz);
        if (f.tfl_yn != 0) emit_fluid_overlay_mask(f.tfl_yn, &self.snap, .y_neg, m.fluid, atlas, by, bz);
    }
};

/// Bit for an unordered pair of section faces, indexed x-, x+, y-, y+, z-, z+.
fn face_pair_bit(a: u3, b: u3) u16 {
    assert(a != b and a < 6 and b < 6);
    const lo: u32 = if (a < b) a else b;
    const hi: u32 = if (a < b) b else a;
    return @as(u16, 1) << @intCast(lo * (11 - lo) / 2 + hi - lo - 1);
}

pub const all_faces_connected: u16 = (1 << 15) - 1;

pub fn faces_connected(connectivity: u16, a: u3, b: u3) bool {
    return connectivity & face_pair_bit(a, b) != 0;
}

/// Grow `seed` along X through the open cells of one row.
fn fill_row(seed: u16, open: u16) u16 {
    var s = seed & open;
    defer assert(s & ~open == 0);

    while (true) {
        const n = (s | (s << 1) | (s >> 1)) & open;
        if (n == s) return s;
        s = n;
    }
}

/// Which pairs of section faces see each other through non-opaque cells.
/// Only regions touching the boundary matter, so floods start there and sealed pockets are never visited.
pub fn section_connectivity(buf: *const SectionBuf) u16 {
    var open: [SectionH][SectionH]u16 = undefined;
    var any: u16 = 0;
    var every: u16 = 0xFFFF;
    for (0..SectionH) |y| {
        for (0..SectionH) |z| {
            const row: u16 = @truncate(~buf[y + 1][z + 1].opq >> 1);
            open[y][z] = row;
            any |= row;
            every &= row;
        }
    }
    if (any == 0) return 0;
    if (every == 0xFFFF) return all_faces_connected;

    var result: u16 = 0;
    var comp: [SectionH][SectionH]u16 = undefined;
    while (result != all_faces_connected) {
        var seed_y: usize = 0;
        var seed_z: usize = 0;
        var seed_bits: u16 = 0;
        search: for (0..SectionH) |y| {
            for (0..SectionH) |z| {
                const edge_row = y == 0 or y == SectionH - 1 or z == 0 or z == SectionH - 1;
                const candidates = if (edge_row) open[y][z] else open[y][z] & 0x8001;
                if (candidates != 0) {
                    seed_y = y;
                    seed_z = z;
                    seed_bits = candidates & (0 -% candidates);
                    break :search;
                }
            }
        }
        if (seed_bits == 0) break;
        assert(@popCount(seed_bits) == 1 and seed_bits & open[seed_y][seed_z] != 0);

        @memset(std.mem.asBytes(&comp), 0);
        comp[seed_y][seed_z] = fill_row(seed_bits, open[seed_y][seed_z]);
        // Alternating sweeps carry the fill across the whole section per pass.
        var changed = true;
        while (changed) {
            changed = false;
            for (0..2) |pass| {
                for (0..SectionH) |i| {
                    const y = if (pass == 0) i else SectionH - 1 - i;
                    for (0..SectionH) |j| {
                        const z = if (pass == 0) j else SectionH - 1 - j;
                        var s = comp[y][z];
                        if (y > 0) s |= comp[y - 1][z];
                        if (y + 1 < SectionH) s |= comp[y + 1][z];
                        if (z > 0) s |= comp[y][z - 1];
                        if (z + 1 < SectionH) s |= comp[y][z + 1];
                        s = fill_row(s, open[y][z]);
                        if (s != comp[y][z]) {
                            comp[y][z] = s;
                            changed = true;
                        }
                    }
                }
            }
        }

        var faces: u8 = 0;
        assert(comp[seed_y][seed_z] & seed_bits != 0);
        for (0..SectionH) |y| {
            for (0..SectionH) |z| {
                const row = comp[y][z];
                if (row == 0) continue;
                if (row & 1 != 0) faces |= 1 << 0;
                if (row & 0x8000 != 0) faces |= 1 << 1;
                if (y == 0) faces |= 1 << 2;
                if (y == SectionH - 1) faces |= 1 << 3;
                if (z == 0) faces |= 1 << 4;
                if (z == SectionH - 1) faces |= 1 << 5;
                assert(row & ~open[y][z] == 0);
                open[y][z] &= ~row;
            }
        }
        for (0..6) |a| {
            if (faces & (@as(u8, 1) << @intCast(a)) == 0) continue;
            for (a + 1..6) |b| {
                if (faces & (@as(u8, 1) << @intCast(b)) != 0) result |= face_pair_bit(@intCast(a), @intCast(b));
            }
        }
    }
    assert(result & ~all_faces_connected == 0);
    return result;
}
