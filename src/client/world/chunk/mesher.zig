const std = @import("std");
const c = @import("common").consts;
const World = @import("game").World;
const TextureAtlas = @import("../../graphics/TextureAtlas.zig").TextureAtlas;
const Vertex = @import("../../graphics/Vertex.zig").Vertex;
const lut = @import("lut.zig");
const face_mod = @import("face.zig");
const Face = face_mod.Face;

const SECTION_H: u32 = 16;
const WORLD_H: u32 = c.WorldHeight;
const WORLD_W: u32 = c.WorldLength;
const WORLD_D: u32 = c.WorldDepth;

const SECTION_MASK: u32 = 0x1FFFE;

const Row = struct {
    opq: u32,
    vis: u32,
    flu: u32,
    cross: u32,
    leaf: u32,
};

/// 18 Y levels x 18 Z rows (section + borders).
pub const BUF_Y: u32 = 18;
pub const BUF_Z: u32 = 18;
pub const SectionBuf = [BUF_Y][BUF_Z]Row;

pub const SectionCounts = struct {
    opaque_verts: u32, // solid blocks + leaf shell faces
    transparent_verts: u32, // outer leaves + water/glass/cross
};

// -- Pack ---------------------------------------------------------------------

fn pack_row(cx: u32, y: i32, wz_raw: i32) Row {
    const BOUNDARY: Row = .{ .opq = 0x3FFFF, .vis = 0, .flu = 0, .cross = 0, .leaf = 0 };
    if (wz_raw < 0 or wz_raw >= @as(i32, WORLD_D)) return BOUNDARY;
    if (y < 0 or y >= @as(i32, WORLD_H)) return BOUNDARY;

    var opq: u32 = 0;
    var vis: u32 = 0;
    var flu: u32 = 0;
    var cross: u32 = 0;
    var leaf: u32 = 0;
    const wy: u16 = @intCast(y);
    const wz: u16 = @intCast(wz_raw);

    for (0..18) |i| {
        const wx_raw: i32 = @as(i32, @intCast(cx)) * 16 + @as(i32, @intCast(i)) - 1;
        if (wx_raw < 0 or wx_raw >= @as(i32, WORLD_W)) {
            opq |= @as(u32, 1) << @intCast(i);
            continue;
        }
        const block = World.get_block(@intCast(wx_raw), wy, wz);
        if (block < 50) {
            if (lut.opaque_lut[block]) opq |= @as(u32, 1) << @intCast(i);
            if (lut.visible_lut[block]) vis |= @as(u32, 1) << @intCast(i);
            if (lut.fluid_lut[block]) flu |= @as(u32, 1) << @intCast(i);
            if (lut.cross_lut[block]) cross |= @as(u32, 1) << @intCast(i);
            if (lut.leaf_lut[block]) leaf |= @as(u32, 1) << @intCast(i);
        }
    }
    return .{ .opq = opq, .vis = vis, .flu = flu, .cross = cross, .leaf = leaf };
}

pub fn pack_section(cx: u32, sy: u32, cz: u32, buf: *SectionBuf) void {
    const base_y: i32 = @as(i32, @intCast(sy)) * 16 - 1;
    for (0..BUF_Y) |by| {
        const wy: i32 = base_y + @as(i32, @intCast(by));
        for (0..BUF_Z) |bz| {
            const wz_raw: i32 = @as(i32, @intCast(cz)) * 16 + @as(i32, @intCast(bz)) - 1;
            buf[by][bz] = pack_row(cx, wy, wz_raw);
        }
    }
}

// -- Count --------------------------------------------------------------------

fn pop(v: u32) u32 {
    return @as(u32, @popCount(v));
}

fn count_row_faces(by: u32, bz: u32, buf: *const SectionBuf) SectionCounts {
    const cur = buf[by][bz];
    const opq = cur.opq;
    const vis = cur.vis;
    const flu = cur.flu;
    const leaf = cur.leaf;
    const solid_vis = vis & ~flu;
    const covered = opq | leaf;

    var x_pos = (solid_vis & ~(opq >> 1)) & SECTION_MASK;
    var x_neg = (solid_vis & ~(opq << 1)) & SECTION_MASK;
    var z_pos = (solid_vis & ~buf[by][bz + 1].opq) & SECTION_MASK;
    var z_neg = (solid_vis & ~buf[by][bz - 1].opq) & SECTION_MASK;
    var y_pos = (vis & ~buf[by + 1][bz].opq & ~(flu & buf[by + 1][bz].flu)) & SECTION_MASK;
    var y_neg = (solid_vis & ~buf[by - 1][bz].opq) & SECTION_MASK;

    // Per-face leaf depth: cull deep interior (leaf 1 ahead AND covered 2 ahead)
    const cov_2_zp: u32 = if (bz + 2 < BUF_Z) (buf[by][bz + 2].opq | buf[by][bz + 2].leaf) else 0;
    const cov_2_zn: u32 = if (bz >= 2) (buf[by][bz - 2].opq | buf[by][bz - 2].leaf) else 0;
    const cov_2_yp: u32 = if (by + 2 < BUF_Y) (buf[by + 2][bz].opq | buf[by + 2][bz].leaf) else 0;
    const cov_2_yn: u32 = if (by >= 2) (buf[by - 2][bz].opq | buf[by - 2][bz].leaf) else 0;

    x_pos &= ~(leaf & (leaf >> 1) & (covered >> 2));
    x_neg &= ~(leaf & (leaf << 1) & (covered << 2));
    z_pos &= ~(leaf & buf[by][bz + 1].leaf & cov_2_zp);
    z_neg &= ~(leaf & buf[by][bz - 1].leaf & cov_2_zn);
    y_pos &= ~(leaf & buf[by + 1][bz].leaf & cov_2_yp);
    y_neg &= ~(leaf & buf[by - 1][bz].leaf & cov_2_yn);

    const opq_count = pop(opq & x_pos) + pop(opq & x_neg) +
        pop(opq & z_pos) + pop(opq & z_neg) +
        pop(opq & y_pos) + pop(opq & y_neg);
    const all_count = pop(x_pos) + pop(x_neg) +
        pop(z_pos) + pop(z_neg) +
        pop(y_pos) + pop(y_neg);
    const cross_count = pop(cur.cross & SECTION_MASK);

    // Shell: leaf with leaf 1 ahead (post-cull => only uncovered-2-ahead remain)
    const shell = pop(leaf & x_pos & (leaf >> 1)) + pop(leaf & x_neg & (leaf << 1)) +
        pop(leaf & z_pos & buf[by][bz + 1].leaf) + pop(leaf & z_neg & buf[by][bz - 1].leaf) +
        pop(leaf & y_pos & buf[by + 1][bz].leaf) + pop(leaf & y_neg & buf[by - 1][bz].leaf);

    return .{
        .opaque_verts = (opq_count + shell) * 6,
        .transparent_verts = (all_count - opq_count - shell) * 6 + cross_count * 24,
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

fn has_room(verts: *const std.ArrayList(Vertex), n: u32) bool {
    return verts.items.len + n <= verts.capacity;
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
        const tile = lut.get_face_tile(block, face);

        const mesh = if (block < 50 and lut.opaque_lut[block]) m.@"opaque" else m.transparent;
        if (!has_room(mesh, 6)) continue;

        if (face == .y_pos and block < 50 and lut.fluid_lut[block]) {
            face_mod.emit_fluid_top(mesh, lx, local_y, lz, tile, atlas);
        } else {
            face_mod.emit_face(mesh, face, lx, local_y, lz, tile, atlas);
        }
    }
}

/// Emit leaf shell faces directly to the opaque mesh.
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
        if (!has_room(opaque_mesh, 6)) continue;

        const lx: u32 = @as(u32, bit_pos) - 1;
        const wx: u16 = @intCast(cx * 16 + lx);
        const wz: u16 = @intCast(cz * 16 + lz);
        const block = World.get_block(wx, @intCast(y), wz);
        const tile = lut.get_face_tile(block, face);
        face_mod.emit_face(opaque_mesh, face, lx, local_y, lz, tile, atlas);
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
        if (!has_room(transparent_mesh, 24)) continue;

        const lx: u32 = @as(u32, bit_pos) - 1;
        const wx: u16 = @intCast(cx * 16 + lx);
        const wz: u16 = @intCast(cz * 16 + lz);
        const block = World.get_block(wx, @intCast(y), wz);
        const tile = lut.get_face_tile(block, .y_pos);
        face_mod.emit_cross(transparent_mesh, lx, local_y, lz, tile, atlas);
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
            const cur = buf[by][bz];
            const opq = cur.opq;
            const vis = cur.vis;
            const flu = cur.flu;
            const leaf = cur.leaf;
            const solid_vis = vis & ~flu;

            const covered = opq | leaf;

            var x_pos = (solid_vis & ~(opq >> 1)) & SECTION_MASK;
            var x_neg = (solid_vis & ~(opq << 1)) & SECTION_MASK;
            var z_pos = (solid_vis & ~buf[by][bz + 1].opq) & SECTION_MASK;
            var z_neg = (solid_vis & ~buf[by][bz - 1].opq) & SECTION_MASK;
            var y_pos = (vis & ~buf[by + 1][bz].opq & ~(flu & buf[by + 1][bz].flu)) & SECTION_MASK;
            var y_neg = (solid_vis & ~buf[by - 1][bz].opq) & SECTION_MASK;

            // Cull deep interior leaf faces (leaf 1 ahead AND covered 2 ahead)
            const cov_2_zp: u32 = if (bz + 2 < BUF_Z) (buf[by][bz + 2].opq | buf[by][bz + 2].leaf) else 0;
            const cov_2_zn: u32 = if (bz >= 2) (buf[by][bz - 2].opq | buf[by][bz - 2].leaf) else 0;
            const cov_2_yp: u32 = if (by + 2 < BUF_Y) (buf[by + 2][bz].opq | buf[by + 2][bz].leaf) else 0;
            const cov_2_yn: u32 = if (by >= 2) (buf[by - 2][bz].opq | buf[by - 2][bz].leaf) else 0;

            x_pos &= ~(leaf & (leaf >> 1) & (covered >> 2));
            x_neg &= ~(leaf & (leaf << 1) & (covered << 2));
            z_pos &= ~(leaf & buf[by][bz + 1].leaf & cov_2_zp);
            z_neg &= ~(leaf & buf[by][bz - 1].leaf & cov_2_zn);
            y_pos &= ~(leaf & buf[by + 1][bz].leaf & cov_2_yp);
            y_neg &= ~(leaf & buf[by - 1][bz].leaf & cov_2_yn);

            // Shell: leaf with leaf 1 ahead (post-cull => opaque boundary)
            const s_xp = leaf & x_pos & (leaf >> 1);
            const s_xn = leaf & x_neg & (leaf << 1);
            const s_zp = leaf & z_pos & buf[by][bz + 1].leaf;
            const s_zn = leaf & z_neg & buf[by][bz - 1].leaf;
            const s_yp = leaf & y_pos & buf[by + 1][bz].leaf;
            const s_yn = leaf & y_neg & buf[by - 1][bz].leaf;

            x_pos &= ~s_xp;
            x_neg &= ~s_xn;
            z_pos &= ~s_zp;
            z_neg &= ~s_zn;
            y_pos &= ~s_yp;
            y_neg &= ~s_yn;

            // Emit remaining faces (transparent routing for outer leaves)
            if (x_pos != 0) emit_mask(x_pos, world_y, @intCast(lz), cx, cz, .x_pos, m, atlas);
            if (x_neg != 0) emit_mask(x_neg, world_y, @intCast(lz), cx, cz, .x_neg, m, atlas);
            if (z_pos != 0) emit_mask(z_pos, world_y, @intCast(lz), cx, cz, .z_pos, m, atlas);
            if (z_neg != 0) emit_mask(z_neg, world_y, @intCast(lz), cx, cz, .z_neg, m, atlas);
            if (y_pos != 0) emit_mask(y_pos, world_y, @intCast(lz), cx, cz, .y_pos, m, atlas);
            if (y_neg != 0) emit_mask(y_neg, world_y, @intCast(lz), cx, cz, .y_neg, m, atlas);

            // Emit shell faces -> opaque mesh
            if (s_xp != 0) emit_opaque_leaf_mask(s_xp, world_y, @intCast(lz), cx, cz, .x_pos, m.@"opaque", atlas);
            if (s_xn != 0) emit_opaque_leaf_mask(s_xn, world_y, @intCast(lz), cx, cz, .x_neg, m.@"opaque", atlas);
            if (s_zp != 0) emit_opaque_leaf_mask(s_zp, world_y, @intCast(lz), cx, cz, .z_pos, m.@"opaque", atlas);
            if (s_zn != 0) emit_opaque_leaf_mask(s_zn, world_y, @intCast(lz), cx, cz, .z_neg, m.@"opaque", atlas);
            if (s_yp != 0) emit_opaque_leaf_mask(s_yp, world_y, @intCast(lz), cx, cz, .y_pos, m.@"opaque", atlas);
            if (s_yn != 0) emit_opaque_leaf_mask(s_yn, world_y, @intCast(lz), cx, cz, .y_neg, m.@"opaque", atlas);

            const cross = cur.cross & SECTION_MASK;
            if (cross != 0) emit_cross_mask(cross, world_y, @intCast(lz), cx, cz, m.transparent, atlas);
        }
    }
}

