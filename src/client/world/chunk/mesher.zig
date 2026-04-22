const std = @import("std");
const common = @import("common");
const c = common.consts;
const prefetch = common.prefetch;
const World = @import("game").World;
const TextureAtlas = @import("../../graphics/TextureAtlas.zig").TextureAtlas;
const Vertex = @import("../../graphics/Vertex.zig").Vertex;
const BlockRegistry = @import("common").BlockRegistry;
const face_mod = @import("face.zig");
const Face = face_mod.Face;

const SECTION_H: u32 = 16;
const Block = c.Block;

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
    /// Glass (and any other block that culls faces against a same-type
    /// neighbor). Two adjacent glass blocks don't draw the shared face.
    glass: u32,
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
    transparent_verts: u32, // outer leaves + glass/cross
    fluid_verts: u32, // water/lava
};

// -- Prefetch -----------------------------------------------------------------

/// 256 bytes (one chunk Y-slice: 16 z-rows x 16 x-blocks) = 4 cache lines.
const Y_SLICE_BYTES: u32 = c.ChunkSize * c.ChunkSize;

/// Streaming prefetch for one Y-level's worth of central-chunk data.
/// Caller must ensure y_local is in [0, ChunkSize). No-op for callers
/// whose pack path doesn't read this data (all-opaque chunks hit the
/// boundary-only fast path).
inline fn prefetch_y_slice(chunk_ptr: *const [c.ChunkVolume]c.Block, y_local: u32) void {
    const offset: u32 = y_local * Y_SLICE_BYTES;
    const slice = chunk_ptr[offset..][0..Y_SLICE_BYTES];
    prefetch.prefetch_slice(c.Block, slice);
}

// -- Pack ---------------------------------------------------------------------

fn pack_row(cx: u32, y: i32, wz_raw: i32) Row {
    const BOUNDARY: Row = .{ .opq = 0x3FFFF, .vis = 0, .flu = 0, .cross = 0, .leaf = 0, .slab = 0, .glass = 0, .solid_leaf = 0 };
    if (wz_raw < 0 or wz_raw >= @as(i32, WORLD_D)) return BOUNDARY;
    if (y < 0 or y >= @as(i32, WORLD_H)) return BOUNDARY;

    var opq: u32 = 0;
    var vis: u32 = 0;
    var flu: u32 = 0;
    var cross: u32 = 0;
    var leaf: u32 = 0;
    var slab: u32 = 0;
    var glass: u32 = 0;
    const wy: u16 = @intCast(y);
    const wz: u16 = @intCast(wz_raw);

    // The 16 inner blocks (bits 1..16) share a chunk and are contiguous in
    // the chunk-aware layout. Read them as a single slice to avoid 16
    // individual block_index computations on the hot path.
    const chunk_row = World.get_chunk_row(@intCast(cx * 16), wy, wz);

    for (0..18) |i| {
        const wx_raw: i32 = @as(i32, @intCast(cx)) * 16 + @as(i32, @intCast(i)) - 1;
        if (wx_raw < 0 or wx_raw >= @as(i32, WORLD_W)) {
            opq |= @as(u32, 1) << @intCast(i);
            continue;
        }
        const block = if (i >= 1 and i <= 16) chunk_row[i - 1] else World.get_block(@intCast(wx_raw), wy, wz);
        const p = BlockRegistry.global.mesh_props[@intFromEnum(block.id)];
        const bit: u32 = @as(u32, 1) << @intCast(i);
        if (p.@"opaque") opq |= bit;
        if (p.visible) vis |= bit;
        if (p.fluid) flu |= bit;
        if (p.cross) cross |= bit;
        if (p.leaf) leaf |= bit;
        if (p.slab) slab |= bit;
        if (p.glass) glass |= bit;
    }
    return .{ .opq = opq, .vis = vis, .flu = flu, .cross = cross, .leaf = leaf, .slab = slab, .glass = glass, .solid_leaf = 0 };
}

/// Flag leaves whose all 6 neighbors are leaf-or-opaque. Such leaves are
/// treated like opaque for culling and are drawn on the opaque mesh - this
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

/// Pack the SectionBuf and return the per-mesh vertex counts so the caller
/// can pre-allocate exact capacity before emit_section runs. emit_section
/// recomputes face masks rather than reading from a cache because, on PSP,
/// a 28 KiB FaceMasks cache exceeds the 16 KiB D-cache and the resulting
/// thrash costs more than re-running compute_face_masks (~3.6 us/cell of
/// bit ops on top of an already-resident SectionBuf).
pub fn pack_section(cx: u32, sy: u32, cz: u32, near_lod: bool, buf: *SectionBuf) SectionCounts {
    const all_opaque = World.is_chunk_all_opaque(cx, sy, cz);
    const base_y: i32 = @as(i32, @intCast(sy)) * 16 - 1;

    // Streaming prefetch only for non-opaque chunks: pack_row_opaque reads
    // just the 2 boundary blocks, so warming the central chunk for opaque
    // sections is pure waste. For non-opaque, prefetch each Y-slice (256 B
    // = 4 cache lines) one iteration ahead so the misses overlap with the
    // current iteration's compute (BlockRegistry props lookups, bit packing,
    // SectionBuf writes) rather than blocking pack_row's reads.
    const chunk_ptr: ?*const [c.ChunkVolume]c.Block = if (all_opaque)
        null
    else
        World.get_chunk_ptr(cx, sy, cz);

    // Pre-warm the first inner slice (read by by==1) before the loop, then
    // each inner iteration issues the slice that the *next* iteration will
    // read. by==0 (y-1 boundary) and by==16/17 don't read inner-chunk data
    // either side, so the prefetch span is exactly y_local = 0..15.
    if (chunk_ptr) |ptr| prefetch_y_slice(ptr, 0);

    for (0..BUF_Y) |by| {
        const wy: i32 = base_y + @as(i32, @intCast(by));

        if (chunk_ptr) |ptr| {
            if (by >= 1 and by <= 15) {
                prefetch_y_slice(ptr, @intCast(by));
            }
        }

        for (0..BUF_Z) |bz| {
            const wz_raw: i32 = @as(i32, @intCast(cz)) * 16 + @as(i32, @intCast(bz)) - 1;
            buf[by][bz] = if (all_opaque and by >= 1 and by <= 16 and bz >= 1 and bz <= 16)
                pack_row_opaque(cx, wy, wz_raw)
            else
                pack_row(cx, wy, wz_raw);
        }
    }
    // All-opaque chunks have no leaves; skip the solid-leaf pass.
    if (!all_opaque) compute_solid_leaves(buf, near_lod);

    return count_section(buf);
}

/// Fast path for inner rows of all-opaque chunks. The 16 inner blocks are
/// known to be opaque+visible with no other flags, so we only need to
/// classify the 2 boundary blocks from neighboring chunks.
fn pack_row_opaque(cx: u32, y: i32, wz_raw: i32) Row {
    var opq: u32 = SECTION_MASK; // bits 1..16
    var vis: u32 = SECTION_MASK;
    var flu: u32 = 0;
    var cross: u32 = 0;
    var leaf: u32 = 0;
    var slab: u32 = 0;
    var glass: u32 = 0;
    const wy: u16 = @intCast(y);
    const wz: u16 = @intCast(wz_raw);

    // Left boundary (bit 0)
    const left_x: i32 = @as(i32, @intCast(cx)) * 16 - 1;
    if (left_x < 0) {
        opq |= 1;
    } else {
        classify_block(World.get_block(@intCast(left_x), wy, wz), 0, &opq, &vis, &flu, &cross, &leaf, &slab, &glass);
    }

    // Right boundary (bit 17)
    const right_x: u32 = cx * 16 + 16;
    if (right_x >= WORLD_W) {
        opq |= @as(u32, 1) << 17;
    } else {
        classify_block(World.get_block(@intCast(right_x), wy, wz), 17, &opq, &vis, &flu, &cross, &leaf, &slab, &glass);
    }

    return .{ .opq = opq, .vis = vis, .flu = flu, .cross = cross, .leaf = leaf, .slab = slab, .glass = glass, .solid_leaf = 0 };
}

inline fn classify_block(block: Block, bit_pos: u5, opq: *u32, vis: *u32, flu: *u32, cross_: *u32, leaf_: *u32, slab_: *u32, glass_: *u32) void {
    const p = BlockRegistry.global.mesh_props[@intFromEnum(block.id)];
    const bit: u32 = @as(u32, 1) << bit_pos;
    if (p.@"opaque") opq.* |= bit;
    if (p.visible) vis.* |= bit;
    if (p.fluid) flu.* |= bit;
    if (p.cross) cross_.* |= bit;
    if (p.leaf) leaf_.* |= bit;
    if (p.slab) slab_.* |= bit;
    if (p.glass) glass_.* |= bit;
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
    // Solid-leaf faces - always emitted to the opaque mesh. Only nonzero where
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
    // Per-direction fluid masks for separate fluid mesh routing.
    flu_xp: u32,
    flu_xn: u32,
    flu_yp: u32,
    flu_yn: u32,
    flu_zp: u32,
    flu_zn: u32,
    // Transparent blocks with fluid neighbors - emit water overlay on fluid mesh.
    tfl_xp: u32,
    tfl_xn: u32,
    tfl_yp: u32,
    tfl_yn: u32,
    tfl_zp: u32,
    tfl_zn: u32,
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
    // an opaque barrier for face culling - so a dirt block adjacent to a
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

    // Glass-against-glass: cull the shared face on both sides. A bit is set
    // here only when the block at that bit is glass and its neighbor in that
    // direction is also glass - used to mask out those faces below.
    const g = cur.glass;
    const g_xp = g & (g >> 1);
    const g_xn = g & (g << 1);
    const g_zp = g & n_zp.glass;
    const g_zn = g & n_zn.glass;
    const g_yp = g & n_yp.glass;
    const g_yn = g & n_yn.glass;

    const x_pos = (std_vis & ~(eff_cur >> 1) & ~g_xp) & SECTION_MASK;
    const x_neg = (std_vis & ~(eff_cur << 1) & ~g_xn) & SECTION_MASK;
    const z_pos = (std_vis & ~eff_zp & ~g_zp) & SECTION_MASK;
    const z_neg = (std_vis & ~eff_zn & ~g_zn) & SECTION_MASK;
    // Slab top sits at y+0.5 with a half-block air gap below the next block,
    // so it can never be occluded by its y+1 neighbor - force-emit unconditionally.
    const y_pos = ((std_vis & ~eff_yp & ~g_yp) | slab) & SECTION_MASK;
    const y_neg = (std_vis & ~eff_yn & ~g_yn) & SECTION_MASK;

    // Fluid faces: cull against eff (so fluid against solid-leaf is culled)
    // and against same-fluid neighbors (water-against-water looks like bulk).
    const flu_xp = (flu & ~(eff_cur >> 1) & ~(flu >> 1)) & SECTION_MASK;
    const flu_xn = (flu & ~(eff_cur << 1) & ~(flu << 1)) & SECTION_MASK;
    const flu_zp = (flu & ~eff_zp & ~n_zp.flu) & SECTION_MASK;
    const flu_zn = (flu & ~eff_zn & ~n_zn.flu) & SECTION_MASK;
    // Water/lava tops are inset (~0.9 blocks). Naked tops (block above is
    // not fluid and not opaque) always emit. Tops with opaque above only
    // emit when adjacent (within 1 block horizontally) to a naked top, to
    // form a one-plane border that hides the inset seam. Deep-covered
    // interior culls — huge win in water/lava-filled caves.
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
    const flu_yp_bits = (flu & ~n_yp.flu & (~eff_yp | naked_border)) & SECTION_MASK;
    const flu_yn = (flu & ~eff_yn & ~n_yn.flu) & SECTION_MASK;

    // Solid-leaf faces. By construction, all 6 neighbors of a solid leaf are
    // leaf-or-opaque, so a face is only emitted where the neighbor is an
    // outer leaf (not in eff). That's exactly the boundary you'd see through
    // the transparent outer leaf - drawn here on the opaque mesh.
    const sl_xp = (sleaf & ~(eff_cur >> 1)) & SECTION_MASK;
    const sl_xn = (sleaf & ~(eff_cur << 1)) & SECTION_MASK;
    const sl_zp = (sleaf & ~eff_zp) & SECTION_MASK;
    const sl_zn = (sleaf & ~eff_zn) & SECTION_MASK;
    const sl_yp = (sleaf & ~eff_yp) & SECTION_MASK;
    const sl_yn = (sleaf & ~eff_yn) & SECTION_MASK;

    // Transparent blocks (including slabs) with fluid neighbors. Emit a
    // water-textured overlay on the fluid mesh so the water surface is
    // visible from the fluid side.
    const trans = std_vis & ~opq;
    const tfl_xp = (trans & (flu >> 1)) & SECTION_MASK;
    const tfl_xn = (trans & (flu << 1)) & SECTION_MASK;
    const tfl_zp = (trans & n_zp.flu) & SECTION_MASK;
    const tfl_zn = (trans & n_zn.flu) & SECTION_MASK;
    const tfl_yp = (trans & n_yp.flu) & SECTION_MASK;
    const tfl_yn = (trans & n_yn.flu) & SECTION_MASK;

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
        .flu_xp = flu_xp,
        .flu_xn = flu_xn,
        .flu_yp = flu_yp_bits,
        .flu_yn = flu_yn,
        .flu_zp = flu_zp,
        .flu_zn = flu_zn,
        .tfl_xp = tfl_xp,
        .tfl_xn = tfl_xn,
        .tfl_yp = tfl_yp,
        .tfl_yn = tfl_yn,
        .tfl_zp = tfl_zp,
        .tfl_zn = tfl_zn,
    };
}

/// Derive vertex counts for a single row from its precomputed face masks.
/// Used by emit_section to size ArrayList capacity per row before appending.
fn counts_from_masks(f: FaceMasks) SectionCounts {
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
    const flu_count = pop(f.flu_xp) + pop(f.flu_xn) +
        pop(f.flu_zp) + pop(f.flu_zn) +
        pop(f.flu_yp) + pop(f.flu_yn);
    const flu_top_extra = pop(f.flu_yp);
    const tfl_count = pop(f.tfl_xp) + pop(f.tfl_xn) +
        pop(f.tfl_zp) + pop(f.tfl_zn) +
        pop(f.tfl_yp) + pop(f.tfl_yn);

    return .{
        .opaque_verts = (opq_count + sl_count) * 6,
        .transparent_verts = (all_count - opq_count - flu_count) * 6 + cross_count * 24,
        .fluid_verts = flu_count * 6 + flu_top_extra * 6 + tfl_count * 6,
    };
}

/// Standalone counting pass. Retained for parity tests; emit_section now
/// derives counts in-line from the same FaceMasks it consumes, so rebuild()
/// no longer calls this on the hot path.
pub fn count_section(buf: *const SectionBuf) SectionCounts {
    var total: SectionCounts = .{ .opaque_verts = 0, .transparent_verts = 0, .fluid_verts = 0 };
    for (1..BUF_Y - 1) |by| {
        for (1..BUF_Z - 1) |bz| {
            const f = compute_face_masks(@intCast(by), @intCast(bz), buf);
            const row = counts_from_masks(f);
            total.opaque_verts += row.opaque_verts;
            total.transparent_verts += row.transparent_verts;
            total.fluid_verts += row.fluid_verts;
        }
    }
    return total;
}

// -- Emit ---------------------------------------------------------------------

fn assert_has_room(verts: *const std.ArrayList(Vertex), n: u32) void {
    std.debug.assert(verts.items.len + n <= verts.capacity);
}

// -- Ambient Occlusion --------------------------------------------------------
// Per-vertex AO: sample 3 neighbors in the face's neighbor plane (two tangent
// edges + the diagonal), classify to a 4-level brightness ramp, and modulate
// the base directional face tint. Opaque-eff = opq | solid_leaf so solid-leaf
// clusters cast AO just like real opaque blocks (matches the cull logic).

const AO_MUL: [4]u8 = .{ 128, 170, 212, 255 };

fn eff_bit(buf: *const SectionBuf, by: u32, bz: u32, bit: u32) u32 {
    const row = &buf[by][bz];
    const eff = row.opq | row.solid_leaf;
    return (eff >> @intCast(bit)) & 1;
}

fn ao_level(t1: u32, t2: u32, d: u32) u32 {
    if (t1 != 0 and t2 != 0) return 0;
    return 3 - (t1 + t2 + d);
}

fn ao_modulate(color: u32, level: u32) u32 {
    const m: u32 = AO_MUL[level];
    const a = color & 0xFF000000;
    const r = (color >> 16) & 0xFF;
    const g = (color >> 8) & 0xFF;
    const b = color & 0xFF;
    return a | (((r * m) >> 8) << 16) | (((g * m) >> 8) << 8) | ((b * m) >> 8);
}

/// Compute the 4 per-corner colors for a cube face at buffer position
/// (by, bz, bit). Vertex order matches `make_quad` for the given face.
fn compute_ao_colors(buf: *const SectionBuf, by: u32, bz: u32, bit: u5, face: Face, shadowed: bool) [4]u32 {
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
    @"opaque": *std.ArrayList(Vertex),
    transparent: *std.ArrayList(Vertex),
    fluid: *std.ArrayList(Vertex),
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
    chunk_row: *const [c.ChunkSize]Block,
    buf: *const SectionBuf,
    by: u32,
    bz: u32,
    ao: bool,
) void {
    const local_y: u32 = y % SECTION_H;
    var bits = mask;
    while (bits != 0) {
        const bit_pos: u5 = @intCast(@ctz(bits));
        bits &= bits - 1;

        const lx: u32 = @as(u32, bit_pos) - 1;
        const wx: u16 = @intCast(cx * 16 + lx);
        const wz: u16 = @intCast(cz * 16 + lz);
        const block = chunk_row[lx];
        const reg = &BlockRegistry.global;
        const tile = reg.get_face_tile(block, face);

        const p = reg.mesh_props[@intFromEnum(block.id)];
        const is_slab = p.slab;
        const is_fluid = p.fluid;
        const mesh = if (p.@"opaque" or is_slab)
            m.@"opaque"
        else if (is_fluid)
            m.fluid
        else
            m.transparent;

        const shadowed = !face_sunlit(wx, y, wz, face) and !p.emits_light;

        if (face == .y_pos and is_fluid) {
            assert_has_room(mesh, 12);
            face_mod.emit_fluid_top(mesh, lx, local_y, lz, tile, atlas, shadowed);
        } else if (is_slab) {
            assert_has_room(mesh, 6);
            face_mod.emit_slab_face(mesh, face, lx, local_y, lz, tile, atlas, shadowed);
        } else if (ao and !is_fluid) {
            assert_has_room(mesh, 6);
            const colors = compute_ao_colors(buf, by, bz, bit_pos, face, shadowed);
            face_mod.emit_face_colors(mesh, face, lx, local_y, lz, tile, atlas, colors);
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
    chunk_row: *const [c.ChunkSize]Block,
    buf: *const SectionBuf,
    by: u32,
    bz: u32,
    ao: bool,
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
        const block = chunk_row[lx];
        const tile = BlockRegistry.global.get_face_tile(block, face);
        const shadowed = !face_sunlit(wx, y, wz, face);
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
    y: u32,
    lz: u32,
    cx: u32,
    cz: u32,
    transparent_mesh: *std.ArrayList(Vertex),
    atlas: *const TextureAtlas,
    chunk_row: *const [c.ChunkSize]Block,
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
        const block = chunk_row[lx];
        const tile = BlockRegistry.global.get_face_tile(block, .y_pos);
        face_mod.emit_cross(transparent_mesh, lx, local_y, lz, tile, atlas, !World.is_sunlit(wx, @intCast(y), wz));
    }
}

/// Emit fluid-overlay faces for transparent blocks adjacent to fluid.
/// Looks up the neighbor fluid block's tile and emits an inset face on the
/// fluid mesh so the water surface is visible from the fluid side.
fn emit_fluid_overlay_mask(
    mask: u32,
    y: u32,
    lz: u32,
    cx: u32,
    cz: u32,
    face: Face,
    fluid_mesh: *std.ArrayList(Vertex),
    atlas: *const TextureAtlas,
) void {
    const local_y: u32 = y % SECTION_H;
    const dx: i32 = switch (face) {
        .x_pos => 1,
        .x_neg => -1,
        else => 0,
    };
    const dy: i32 = switch (face) {
        .y_pos => 1,
        .y_neg => -1,
        else => 0,
    };
    const dz: i32 = switch (face) {
        .z_pos => 1,
        .z_neg => -1,
        else => 0,
    };
    var bits = mask;
    while (bits != 0) {
        const bit_pos: u5 = @intCast(@ctz(bits));
        bits &= bits - 1;
        assert_has_room(fluid_mesh, 6);

        const lx: u32 = @as(u32, bit_pos) - 1;
        const wx: u16 = @intCast(cx * 16 + lx);
        const wz: u16 = @intCast(cz * 16 + lz);
        // Look up the neighboring fluid block's texture.
        const nx: u16 = @intCast(@as(i32, wx) + dx);
        const ny: u16 = @intCast(@as(i32, @intCast(y)) + dy);
        const nz: u16 = @intCast(@as(i32, wz) + dz);
        const neighbor = World.get_block(nx, ny, nz);
        const tile = BlockRegistry.global.get_face_tile(neighbor, face);
        const neighbor_emits = BlockRegistry.global.mesh_props[@intFromEnum(neighbor.id)].emits_light;
        const shadowed = !face_sunlit(wx, y, wz, face) and !neighbor_emits;
        face_mod.emit_fluid_overlay(fluid_mesh, face, lx, local_y, lz, tile, atlas, shadowed);
    }
}

/// Walks the SectionBuf and emits faces. Caller pre-allocates the three
/// meshes from the SectionCounts pack_section returned, so emit can use
/// appendAssumeCapacity without any per-row growth checks. Recomputes face
/// masks per cell (cheaper than caching them on PSP -- see pack_section).
pub fn emit_section(
    buf: *const SectionBuf,
    cx: u32,
    sy: u32,
    cz: u32,
    m: Meshes,
    atlas: *const TextureAtlas,
    ao: bool,
) void {
    const base_y: u32 = sy * SECTION_H;
    for (0..SECTION_H) |ly| {
        const by: u32 = @as(u32, @intCast(ly)) + 1;
        const world_y: u32 = base_y + @as(u32, @intCast(ly));
        for (0..16) |lz| {
            const bz: u32 = @as(u32, @intCast(lz)) + 1;
            const f = compute_face_masks(by, bz, buf);

            // Skip rows that emit nothing. Avoids the chunk_row fetch.
            const any = f.x_pos | f.x_neg | f.y_pos | f.y_neg | f.z_pos | f.z_neg |
                f.sl_xp | f.sl_xn | f.sl_yp | f.sl_yn | f.sl_zp | f.sl_zn |
                f.cross |
                f.tfl_xp | f.tfl_xn | f.tfl_yp | f.tfl_yn | f.tfl_zp | f.tfl_zn;
            if (any == 0) continue;

            const chunk_row = World.get_chunk_row(@intCast(cx * 16), @intCast(world_y), @intCast(cz * 16 + lz));

            // Standard faces - emit_mask routes opaque blocks to the opaque
            // mesh and outer leaves / glass / fluids to the transparent mesh.
            if (f.x_pos != 0) emit_mask(f.x_pos, world_y, @intCast(lz), cx, cz, .x_pos, m, atlas, chunk_row, buf, by, bz, ao);
            if (f.x_neg != 0) emit_mask(f.x_neg, world_y, @intCast(lz), cx, cz, .x_neg, m, atlas, chunk_row, buf, by, bz, ao);
            if (f.z_pos != 0) emit_mask(f.z_pos, world_y, @intCast(lz), cx, cz, .z_pos, m, atlas, chunk_row, buf, by, bz, ao);
            if (f.z_neg != 0) emit_mask(f.z_neg, world_y, @intCast(lz), cx, cz, .z_neg, m, atlas, chunk_row, buf, by, bz, ao);
            if (f.y_pos != 0) emit_mask(f.y_pos, world_y, @intCast(lz), cx, cz, .y_pos, m, atlas, chunk_row, buf, by, bz, ao);
            if (f.y_neg != 0) emit_mask(f.y_neg, world_y, @intCast(lz), cx, cz, .y_neg, m, atlas, chunk_row, buf, by, bz, ao);

            // Emit solid-leaf faces -> opaque mesh
            if (f.sl_xp != 0) emit_opaque_leaf_mask(f.sl_xp, world_y, @intCast(lz), cx, cz, .x_pos, m.@"opaque", atlas, chunk_row, buf, by, bz, ao);
            if (f.sl_xn != 0) emit_opaque_leaf_mask(f.sl_xn, world_y, @intCast(lz), cx, cz, .x_neg, m.@"opaque", atlas, chunk_row, buf, by, bz, ao);
            if (f.sl_zp != 0) emit_opaque_leaf_mask(f.sl_zp, world_y, @intCast(lz), cx, cz, .z_pos, m.@"opaque", atlas, chunk_row, buf, by, bz, ao);
            if (f.sl_zn != 0) emit_opaque_leaf_mask(f.sl_zn, world_y, @intCast(lz), cx, cz, .z_neg, m.@"opaque", atlas, chunk_row, buf, by, bz, ao);
            if (f.sl_yp != 0) emit_opaque_leaf_mask(f.sl_yp, world_y, @intCast(lz), cx, cz, .y_pos, m.@"opaque", atlas, chunk_row, buf, by, bz, ao);
            if (f.sl_yn != 0) emit_opaque_leaf_mask(f.sl_yn, world_y, @intCast(lz), cx, cz, .y_neg, m.@"opaque", atlas, chunk_row, buf, by, bz, ao);

            if (f.cross != 0) emit_cross_mask(f.cross, world_y, @intCast(lz), cx, cz, m.transparent, atlas, chunk_row);

            // Emit fluid-overlay faces for transparent blocks with fluid neighbors.
            // These look up neighbor blocks which may cross chunk boundaries,
            // so they still use get_block internally.
            if (f.tfl_xp != 0) emit_fluid_overlay_mask(f.tfl_xp, world_y, @intCast(lz), cx, cz, .x_pos, m.fluid, atlas);
            if (f.tfl_xn != 0) emit_fluid_overlay_mask(f.tfl_xn, world_y, @intCast(lz), cx, cz, .x_neg, m.fluid, atlas);
            if (f.tfl_zp != 0) emit_fluid_overlay_mask(f.tfl_zp, world_y, @intCast(lz), cx, cz, .z_pos, m.fluid, atlas);
            if (f.tfl_zn != 0) emit_fluid_overlay_mask(f.tfl_zn, world_y, @intCast(lz), cx, cz, .z_neg, m.fluid, atlas);
            if (f.tfl_yp != 0) emit_fluid_overlay_mask(f.tfl_yp, world_y, @intCast(lz), cx, cz, .y_pos, m.fluid, atlas);
            if (f.tfl_yn != 0) emit_fluid_overlay_mask(f.tfl_yn, world_y, @intCast(lz), cx, cz, .y_neg, m.fluid, atlas);
        }
    }
}
