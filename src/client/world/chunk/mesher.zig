const std = @import("std");
const c = @import("common").consts;
const World = @import("game").World;
const TextureAtlas = @import("../../graphics/TextureAtlas.zig").TextureAtlas;
const Vertex = @import("../../graphics/Vertex.zig").Vertex;
const BlockRegistry = @import("../block/BlockRegistry.zig");
const face_mod = @import("face.zig");
const Face = face_mod.Face;

const SECTION_H: u32 = 16;
const B = c.Block;

/// Check sunlight at the neighbor block this face looks into.
fn face_sunlit(wx: u16, y: u32, wz: u16, face: Face) bool {
    const nx: i32 = @as(i32, wx) + switch (face) {
        .x_pos => @as(i32, 1),
        .x_neg => @as(i32, -1),
        else => @as(i32, 0),
    };
    const ny: i32 = @as(i32, @intCast(y)) + switch (face) {
        .y_pos => @as(i32, 1),
        .y_neg => @as(i32, -1),
        else => @as(i32, 0),
    };
    const nz: i32 = @as(i32, wz) + switch (face) {
        .z_pos => @as(i32, 1),
        .z_neg => @as(i32, -1),
        else => @as(i32, 0),
    };
    // Out-of-bounds neighbors are treated as sunlit (sky above / world edge)
    if (nx < 0 or nx >= c.WorldLength or
        nz < 0 or nz >= c.WorldDepth or
        ny < 0 or ny >= c.WorldHeight)
        return true;
    return World.is_sunlit(@intCast(nx), @intCast(ny), @intCast(nz));
}
const WORLD_H: u32 = c.WorldHeight;
const WORLD_W: u32 = c.WorldLength;
const WORLD_D: u32 = c.WorldDepth;

/// Bits 1..16 set: the 16 inner columns of the 18-wide padded row.
const SECTION_MASK: u32 = ((1 << 16) - 1) << 1;

const Row = struct {
    opq: u32,
    vis: u32,
    flu: u32,
    cross: u32,
    leaf: u32,
    slab: u32,
    /// Bits set where a leaf has all 6 neighbors covered (leaf-or-opaque).
    /// Filled by `compute_solid_leaves` after `pack_row` runs.
    solid_leaf: u32,
};

/// 18 Y levels x 18 Z rows (section + borders).
pub const BUF_Y: u32 = 18;
pub const BUF_Z: u32 = 18;
pub const SectionBuf = [BUF_Y][BUF_Z]Row;

pub const SectionCounts = struct {
    opaque_verts: u32, // solid blocks + fully-buried leaf faces
    transparent_verts: u32, // outer leaves + water/glass/cross
};

// -- Pack ---------------------------------------------------------------------

fn pack_row(cx: u32, y: i32, wz_raw: i32) Row {
    const BOUNDARY: Row = .{ .opq = 0x3FFFF, .vis = 0, .flu = 0, .cross = 0, .leaf = 0, .slab = 0, .solid_leaf = 0 };
    if (wz_raw < 0 or wz_raw >= @as(i32, WORLD_D)) return BOUNDARY;
    if (y < 0 or y >= @as(i32, WORLD_H)) return BOUNDARY;

    var opq: u32 = 0;
    var vis: u32 = 0;
    var flu: u32 = 0;
    var cross: u32 = 0;
    var leaf: u32 = 0;
    var slab: u32 = 0;
    const wy: u16 = @intCast(y);
    const wz: u16 = @intCast(wz_raw);

    for (0..18) |i| {
        const wx_raw: i32 = @as(i32, @intCast(cx)) * 16 + @as(i32, @intCast(i)) - 1;
        if (wx_raw < 0 or wx_raw >= @as(i32, WORLD_W)) {
            opq |= @as(u32, 1) << @intCast(i);
            continue;
        }
        const block = World.get_block(@intCast(wx_raw), wy, wz);
        const reg = &BlockRegistry.global;
        const bit: u32 = @as(u32, 1) << @intCast(i);
        if (reg.@"opaque".isSet(block)) opq |= bit;
        if (reg.visible.isSet(block)) vis |= bit;
        if (reg.fluid.isSet(block)) flu |= bit;
        if (reg.cross.isSet(block)) cross |= bit;
        if (reg.leaf.isSet(block)) leaf |= bit;
        if (reg.slab.isSet(block)) slab |= bit;
    }
    return .{ .opq = opq, .vis = vis, .flu = flu, .cross = cross, .leaf = leaf, .slab = slab, .solid_leaf = 0 };
}

/// Flag leaves whose all 6 neighbors are leaf-or-opaque. Such leaves are
/// treated like opaque for culling and are drawn on the opaque mesh — this
/// hides the interior of a leaf cluster while still letting the outer layer
/// render as a transparent shell with holes.
///
/// Buffer-edge cells (by/bz boundary) can't see 1-deep in every direction and
/// conservatively fall back to "not solid". The natural 0-fill of the u32
/// shifts handles the x-direction boundaries the same way.
///
/// In far LOD (`near_lod == false`), every leaf is unconditionally marked
/// solid. The downstream face-mask logic then routes all leaf faces through
/// the opaque mesh and culls neighbors against them, which is the cheap
/// "fast leaves" rendering used for distant chunks.
fn compute_solid_leaves(buf: *SectionBuf, near_lod: bool) void {
    if (!near_lod) {
        for (0..BUF_Y) |by| {
            for (0..BUF_Z) |bz| {
                buf[by][bz].solid_leaf = buf[by][bz].leaf;
            }
        }
        return;
    }
    for (0..BUF_Y) |by| {
        for (0..BUF_Z) |bz| {
            const cur = &buf[by][bz];
            if (cur.leaf == 0) {
                cur.solid_leaf = 0;
                continue;
            }
            const cov_cur = cur.opq | cur.leaf;

            var cov_zp: u32 = 0;
            if (bz + 1 < BUF_Z) {
                const n = &buf[by][bz + 1];
                cov_zp = n.opq | n.leaf;
            }
            var cov_zn: u32 = 0;
            if (bz > 0) {
                const n = &buf[by][bz - 1];
                cov_zn = n.opq | n.leaf;
            }
            var cov_yp: u32 = 0;
            if (by + 1 < BUF_Y) {
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
            std.debug.assert((cur.solid_leaf & ~cur.leaf) == 0);
        }
    }
}

pub fn pack_section(cx: u32, sy: u32, cz: u32, near_lod: bool, buf: *SectionBuf) void {
    const base_y: i32 = @as(i32, @intCast(sy)) * 16 - 1;
    for (0..BUF_Y) |by| {
        const wy: i32 = base_y + @as(i32, @intCast(by));
        for (0..BUF_Z) |bz| {
            const wz_raw: i32 = @as(i32, @intCast(cz)) * 16 + @as(i32, @intCast(bz)) - 1;
            buf[by][bz] = pack_row(cx, wy, wz_raw);
        }
    }
    compute_solid_leaves(buf, near_lod);
}

// -- Count --------------------------------------------------------------------

fn pop(v: u32) u32 {
    return @as(u32, @popCount(v));
}

/// Computed face masks for a single row, shared by counting and emission.
const FaceMasks = struct {
    // Faces routed via emit_mask (registry picks opaque vs transparent mesh).
    // Includes: opaque blocks, outer leaves, glass, and fluids.
    x_pos: u32,
    x_neg: u32,
    y_pos: u32,
    y_neg: u32,
    z_pos: u32,
    z_neg: u32,
    // Solid-leaf faces — always emitted to the opaque mesh. Only nonzero where
    // the neighbor in that direction is an outer leaf (everywhere else the
    // neighbor is opaque-or-solid-leaf and the face is culled by construction).
    sl_xp: u32,
    sl_xn: u32,
    sl_yp: u32,
    sl_yn: u32,
    sl_zp: u32,
    sl_zn: u32,
    cross: u32,
    opq: u32,
    leaf: u32,
    slab: u32,
    // Fluid y_pos faces needing double-sided emission (extra 6 verts each)
    flu_yp: u32,
};

fn compute_face_masks(by: u32, bz: u32, buf: *const SectionBuf) FaceMasks {
    const cur = buf[by][bz];
    const opq = cur.opq;
    const vis = cur.vis;
    const flu = cur.flu;
    const leaf = cur.leaf;
    const slab = cur.slab;
    const sleaf = cur.solid_leaf;

    // "Effective opaque" = real opaque + solid leaves. Anything in eff acts as
    // an opaque barrier for face culling — so a dirt block adjacent to a
    // solid-leaf does not draw its face, just like dirt-against-dirt.
    const n_zp = &buf[by][bz + 1];
    const n_zn = &buf[by][bz - 1];
    const n_yp = &buf[by + 1][bz];
    const n_yn = &buf[by - 1][bz];
    const eff_cur = opq | sleaf;
    const eff_zp = n_zp.opq | n_zp.solid_leaf;
    const eff_zn = n_zn.opq | n_zn.solid_leaf;
    const eff_yp = n_yp.opq | n_yp.solid_leaf;
    const eff_yn = n_yn.opq | n_yn.solid_leaf;

    // Standard visible blocks: opaque + outer leaves + glass. Fluids and solid
    // leaves are emitted through their own paths and excluded here.
    const std_vis = (vis & ~flu) & ~sleaf;

    const x_pos = (std_vis & ~(eff_cur >> 1)) & SECTION_MASK;
    const x_neg = (std_vis & ~(eff_cur << 1)) & SECTION_MASK;
    const z_pos = (std_vis & ~eff_zp) & SECTION_MASK;
    const z_neg = (std_vis & ~eff_zn) & SECTION_MASK;
    // Slab top sits at y+0.5 with a half-block air gap below the next block,
    // so it can never be occluded by its y+1 neighbor — force-emit unconditionally.
    const y_pos = ((std_vis & ~eff_yp) | slab) & SECTION_MASK;
    const y_neg = (std_vis & ~eff_yn) & SECTION_MASK;

    // Fluid faces: cull against eff (so fluid against solid-leaf is culled)
    // and against same-fluid neighbors (water-against-water looks like bulk).
    const flu_xp = (flu & ~(eff_cur >> 1) & ~(flu >> 1)) & SECTION_MASK;
    const flu_xn = (flu & ~(eff_cur << 1) & ~(flu << 1)) & SECTION_MASK;
    const flu_zp = (flu & ~eff_zp & ~n_zp.flu) & SECTION_MASK;
    const flu_zn = (flu & ~eff_zn & ~n_zn.flu) & SECTION_MASK;
    // Water/lava tops are inset (~0.9 blocks), so they must be emitted even
    // when the block above is opaque — omitting them leaves a visible gap.
    const flu_yp_bits = (flu & ~n_yp.flu) & SECTION_MASK;
    const flu_yn = (flu & ~eff_yn & ~n_yn.flu) & SECTION_MASK;

    // Solid-leaf faces. By construction, all 6 neighbors of a solid leaf are
    // leaf-or-opaque, so a face is only emitted where the neighbor is an
    // outer leaf (not in eff). That's exactly the boundary you'd see through
    // the transparent outer leaf — drawn here on the opaque mesh.
    const sl_xp = (sleaf & ~(eff_cur >> 1)) & SECTION_MASK;
    const sl_xn = (sleaf & ~(eff_cur << 1)) & SECTION_MASK;
    const sl_zp = (sleaf & ~eff_zp) & SECTION_MASK;
    const sl_zn = (sleaf & ~eff_zn) & SECTION_MASK;
    const sl_yp = (sleaf & ~eff_yp) & SECTION_MASK;
    const sl_yn = (sleaf & ~eff_yn) & SECTION_MASK;

    return .{
        .x_pos = x_pos | flu_xp,
        .x_neg = x_neg | flu_xn,
        .y_pos = y_pos | flu_yp_bits,
        .y_neg = y_neg | flu_yn,
        .z_pos = z_pos | flu_zp,
        .z_neg = z_neg | flu_zn,
        .sl_xp = sl_xp,
        .sl_xn = sl_xn,
        .sl_yp = sl_yp,
        .sl_yn = sl_yn,
        .sl_zp = sl_zp,
        .sl_zn = sl_zn,
        .cross = cur.cross & SECTION_MASK,
        .opq = opq,
        .leaf = leaf,
        .slab = slab,
        .flu_yp = flu_yp_bits,
    };
}

fn count_row_faces(by: u32, bz: u32, buf: *const SectionBuf) SectionCounts {
    const f = compute_face_masks(by, bz, buf);

    const sl_count = pop(f.sl_xp) + pop(f.sl_xn) + pop(f.sl_zp) + pop(f.sl_zn) + pop(f.sl_yp) + pop(f.sl_yn);
    // Slabs render to the opaque mesh even though they're not in `opq`
    // (which is the cull mask). Fold them in for vertex-count routing.
    const routed_opq = f.opq | f.slab;
    const opq_count = pop(routed_opq & f.x_pos) + pop(routed_opq & f.x_neg) +
        pop(routed_opq & f.z_pos) + pop(routed_opq & f.z_neg) +
        pop(routed_opq & f.y_pos) + pop(routed_opq & f.y_neg);
    const all_count = pop(f.x_pos) + pop(f.x_neg) +
        pop(f.z_pos) + pop(f.z_neg) +
        pop(f.y_pos) + pop(f.y_neg);
    const cross_count = pop(f.cross);
    const flu_top_extra = pop(f.flu_yp);

    return .{
        .opaque_verts = (opq_count + sl_count) * 6,
        .transparent_verts = (all_count - opq_count) * 6 + cross_count * 24 + flu_top_extra * 6,
    };
}

pub fn count_section(buf: *const SectionBuf) SectionCounts {
    var total: SectionCounts = .{ .opaque_verts = 0, .transparent_verts = 0 };
    for (1..BUF_Y - 1) |by| {
        for (1..BUF_Z - 1) |bz| {
            const row = count_row_faces(@intCast(by), @intCast(bz), buf);
            total.opaque_verts += row.opaque_verts;
            total.transparent_verts += row.transparent_verts;
        }
    }
    return total;
}

// -- Emit ---------------------------------------------------------------------

fn assert_has_room(verts: *const std.ArrayList(Vertex), n: u32) void {
    std.debug.assert(verts.items.len + n <= verts.capacity);
}

pub const Meshes = struct {
    @"opaque": *std.ArrayList(Vertex),
    transparent: *std.ArrayList(Vertex),
};

fn emit_mask(
    mask: u32,
    y: u32,
    lz: u32,
    cx: u32,
    cz: u32,
    face: Face,
    m: Meshes,
    atlas: *const TextureAtlas,
) void {
    const local_y: u32 = y % SECTION_H;
    var bits = mask;
    while (bits != 0) {
        const bit_pos: u5 = @intCast(@ctz(bits));
        bits &= bits - 1;

        const lx: u32 = @as(u32, bit_pos) - 1;
        const wx: u16 = @intCast(cx * 16 + lx);
        const wz: u16 = @intCast(cz * 16 + lz);
        const block = World.get_block(wx, @intCast(y), wz);
        const reg = &BlockRegistry.global;
        const tile = reg.get_face_tile(block, face);

        const is_slab = reg.slab.isSet(block);
        const mesh = if (reg.@"opaque".isSet(block) or is_slab) m.@"opaque" else m.transparent;

        const shadowed = !face_sunlit(wx, y, wz, face) and
            block != B.Flowing_Lava and block != B.Still_Lava;

        if (face == .y_pos and reg.fluid.isSet(block)) {
            assert_has_room(mesh, 12);
            face_mod.emit_fluid_top(mesh, lx, local_y, lz, tile, atlas, shadowed);
        } else if (is_slab) {
            assert_has_room(mesh, 6);
            face_mod.emit_slab_face(mesh, face, lx, local_y, lz, tile, atlas, shadowed);
        } else {
            assert_has_room(mesh, 6);
            face_mod.emit_face(mesh, face, lx, local_y, lz, tile, atlas, shadowed);
        }
    }
}

/// Emit solid-leaf faces directly to the opaque mesh.
fn emit_opaque_leaf_mask(
    mask: u32,
    y: u32,
    lz: u32,
    cx: u32,
    cz: u32,
    face: Face,
    opaque_mesh: *std.ArrayList(Vertex),
    atlas: *const TextureAtlas,
) void {
    const local_y: u32 = y % SECTION_H;
    var bits = mask;
    while (bits != 0) {
        const bit_pos: u5 = @intCast(@ctz(bits));
        bits &= bits - 1;
        assert_has_room(opaque_mesh, 6);

        const lx: u32 = @as(u32, bit_pos) - 1;
        const wx: u16 = @intCast(cx * 16 + lx);
        const wz: u16 = @intCast(cz * 16 + lz);
        const block = World.get_block(wx, @intCast(y), wz);
        const tile = BlockRegistry.global.get_face_tile(block, face);
        const shadowed = !face_sunlit(wx, y, wz, face);
        face_mod.emit_face(opaque_mesh, face, lx, local_y, lz, tile, atlas, shadowed);
    }
}

fn emit_cross_mask(
    mask: u32,
    y: u32,
    lz: u32,
    cx: u32,
    cz: u32,
    transparent_mesh: *std.ArrayList(Vertex),
    atlas: *const TextureAtlas,
) void {
    const local_y: u32 = y % SECTION_H;
    var bits = mask;
    while (bits != 0) {
        const bit_pos: u5 = @intCast(@ctz(bits));
        bits &= bits - 1;
        assert_has_room(transparent_mesh, 24);

        const lx: u32 = @as(u32, bit_pos) - 1;
        const wx: u16 = @intCast(cx * 16 + lx);
        const wz: u16 = @intCast(cz * 16 + lz);
        const block = World.get_block(wx, @intCast(y), wz);
        const tile = BlockRegistry.global.get_face_tile(block, .y_pos);
        face_mod.emit_cross(transparent_mesh, lx, local_y, lz, tile, atlas, !World.is_sunlit(wx, @intCast(y), wz));
    }
}

pub fn emit_section(
    buf: *const SectionBuf,
    cx: u32,
    sy: u32,
    cz: u32,
    m: Meshes,
    atlas: *const TextureAtlas,
) void {
    const base_y: u32 = sy * SECTION_H;
    for (0..SECTION_H) |ly| {
        const by: u32 = @as(u32, @intCast(ly)) + 1;
        const world_y: u32 = base_y + @as(u32, @intCast(ly));
        for (0..16) |lz| {
            const bz: u32 = @as(u32, @intCast(lz)) + 1;
            const f = compute_face_masks(by, bz, buf);

            // Standard faces — emit_mask routes opaque blocks to the opaque
            // mesh and outer leaves / glass / fluids to the transparent mesh.
            if (f.x_pos != 0) emit_mask(f.x_pos, world_y, @intCast(lz), cx, cz, .x_pos, m, atlas);
            if (f.x_neg != 0) emit_mask(f.x_neg, world_y, @intCast(lz), cx, cz, .x_neg, m, atlas);
            if (f.z_pos != 0) emit_mask(f.z_pos, world_y, @intCast(lz), cx, cz, .z_pos, m, atlas);
            if (f.z_neg != 0) emit_mask(f.z_neg, world_y, @intCast(lz), cx, cz, .z_neg, m, atlas);
            if (f.y_pos != 0) emit_mask(f.y_pos, world_y, @intCast(lz), cx, cz, .y_pos, m, atlas);
            if (f.y_neg != 0) emit_mask(f.y_neg, world_y, @intCast(lz), cx, cz, .y_neg, m, atlas);

            // Emit solid-leaf faces -> opaque mesh
            if (f.sl_xp != 0) emit_opaque_leaf_mask(f.sl_xp, world_y, @intCast(lz), cx, cz, .x_pos, m.@"opaque", atlas);
            if (f.sl_xn != 0) emit_opaque_leaf_mask(f.sl_xn, world_y, @intCast(lz), cx, cz, .x_neg, m.@"opaque", atlas);
            if (f.sl_zp != 0) emit_opaque_leaf_mask(f.sl_zp, world_y, @intCast(lz), cx, cz, .z_pos, m.@"opaque", atlas);
            if (f.sl_zn != 0) emit_opaque_leaf_mask(f.sl_zn, world_y, @intCast(lz), cx, cz, .z_neg, m.@"opaque", atlas);
            if (f.sl_yp != 0) emit_opaque_leaf_mask(f.sl_yp, world_y, @intCast(lz), cx, cz, .y_pos, m.@"opaque", atlas);
            if (f.sl_yn != 0) emit_opaque_leaf_mask(f.sl_yn, world_y, @intCast(lz), cx, cz, .y_neg, m.@"opaque", atlas);

            if (f.cross != 0) emit_cross_mask(f.cross, world_y, @intCast(lz), cx, cz, m.transparent, atlas);
        }
    }
}
