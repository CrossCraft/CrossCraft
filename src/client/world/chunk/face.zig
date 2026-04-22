const std = @import("std");
const common = @import("common");
const BlockRegistry = common.BlockRegistry;
const TextureAtlas = @import("../../graphics/TextureAtlas.zig").TextureAtlas;
const Vertex = @import("../../graphics/Vertex.zig").Vertex;

pub const Face = common.consts.Face;

/// Map local coordinate [0, 16] to SNORM16 [0, 32767].
pub fn encode_pos(local: u32) i16 {
    std.debug.assert(local <= 16);
    return @intCast(@min(@as(i32, @intCast(local)) * 2048, 32767));
}

/// Encode position with fractional offset (units of 1/256 block).
pub fn encode_pos_frac(local: u32, frac256: u32) i16 {
    std.debug.assert(local <= 16);
    return @intCast(@min(@as(i32, @intCast(local)) * 2048 + @as(i32, @intCast(frac256)) * 8, 32767));
}

/// Directional face shading.
pub fn face_color(face: Face) u32 {
    return switch (face) {
        .y_pos => 0xFFFFFFFF,
        .y_neg => 0xFF7F7F7F,
        .x_neg, .x_pos => 0xFF999999,
        .z_neg, .z_pos => 0xFFCCCCCC,
    };
}

/// Darken a color for shadowed geometry. Multiplies RGB by 153/256 (~0.6).
pub fn apply_shadow(color: u32) u32 {
    const r = (color >> 16) & 0xFF;
    const g = (color >> 8) & 0xFF;
    const b = color & 0xFF;
    const a = color & 0xFF000000;
    return a | (((r * 153) >> 8) << 16) | (((g * 153) >> 8) << 8) | ((b * 153) >> 8);
}

const UVRect = struct { tu0: i16, tv0: i16, tu1: i16, tv1: i16 };

fn tile_uvs(tile: BlockRegistry.Tile, atlas: *const TextureAtlas) UVRect {
    const base_u = atlas.tileU(tile.col);
    const base_v = atlas.tileV(tile.row);
    return .{
        .tu0 = @intCast(@as(i32, base_u) + @as(i32, atlas.tileWidth())),
        .tv0 = base_v,
        .tu1 = base_u,
        .tv1 = @intCast(@as(i32, base_v) + @as(i32, atlas.tileHeight())),
    };
}

/// Four identical corner colors for paths without per-vertex AO.
pub fn uniform_colors(c: u32) [4]u32 {
    return .{ c, c, c, c };
}

fn make_quad(face: Face, px: i16, px1: i16, py: i16, py1: i16, pz: i16, pz1: i16, tu0: i16, tv0: i16, tu1: i16, tv1: i16, colors: [4]u32) [4]Vertex {
    return switch (face) {
        .x_pos => .{
            .{ .pos = .{ px1, py, pz }, .uv = .{ tu0, tv1 }, .color = colors[0] },
            .{ .pos = .{ px1, py, pz1 }, .uv = .{ tu1, tv1 }, .color = colors[1] },
            .{ .pos = .{ px1, py1, pz1 }, .uv = .{ tu1, tv0 }, .color = colors[2] },
            .{ .pos = .{ px1, py1, pz }, .uv = .{ tu0, tv0 }, .color = colors[3] },
        },
        .x_neg => .{
            .{ .pos = .{ px, py, pz1 }, .uv = .{ tu0, tv1 }, .color = colors[0] },
            .{ .pos = .{ px, py, pz }, .uv = .{ tu1, tv1 }, .color = colors[1] },
            .{ .pos = .{ px, py1, pz }, .uv = .{ tu1, tv0 }, .color = colors[2] },
            .{ .pos = .{ px, py1, pz1 }, .uv = .{ tu0, tv0 }, .color = colors[3] },
        },
        .y_pos => .{
            .{ .pos = .{ px, py1, pz }, .uv = .{ tu1, tv0 }, .color = colors[0] },
            .{ .pos = .{ px1, py1, pz }, .uv = .{ tu0, tv0 }, .color = colors[1] },
            .{ .pos = .{ px1, py1, pz1 }, .uv = .{ tu0, tv1 }, .color = colors[2] },
            .{ .pos = .{ px, py1, pz1 }, .uv = .{ tu1, tv1 }, .color = colors[3] },
        },
        .y_neg => .{
            .{ .pos = .{ px, py, pz1 }, .uv = .{ tu1, tv0 }, .color = colors[0] },
            .{ .pos = .{ px1, py, pz1 }, .uv = .{ tu0, tv0 }, .color = colors[1] },
            .{ .pos = .{ px1, py, pz }, .uv = .{ tu0, tv1 }, .color = colors[2] },
            .{ .pos = .{ px, py, pz }, .uv = .{ tu1, tv1 }, .color = colors[3] },
        },
        .z_pos => .{
            .{ .pos = .{ px1, py, pz1 }, .uv = .{ tu0, tv1 }, .color = colors[0] },
            .{ .pos = .{ px, py, pz1 }, .uv = .{ tu1, tv1 }, .color = colors[1] },
            .{ .pos = .{ px, py1, pz1 }, .uv = .{ tu1, tv0 }, .color = colors[2] },
            .{ .pos = .{ px1, py1, pz1 }, .uv = .{ tu0, tv0 }, .color = colors[3] },
        },
        .z_neg => .{
            .{ .pos = .{ px, py, pz }, .uv = .{ tu0, tv1 }, .color = colors[0] },
            .{ .pos = .{ px1, py, pz }, .uv = .{ tu1, tv1 }, .color = colors[1] },
            .{ .pos = .{ px1, py1, pz }, .uv = .{ tu1, tv0 }, .color = colors[2] },
            .{ .pos = .{ px, py1, pz }, .uv = .{ tu0, tv0 }, .color = colors[3] },
        },
    };
}

/// Pick the triangulation diagonal so the split runs along the brighter pair
/// of corners - avoids the Gouraud shadow ridge on AO-darkened inside corners.
fn brighter_along_02(verts: [4]Vertex) bool {
    const g0: u32 = (verts[0].color >> 8) & 0xFF;
    const g1: u32 = (verts[1].color >> 8) & 0xFF;
    const g2: u32 = (verts[2].color >> 8) & 0xFF;
    const g3: u32 = (verts[3].color >> 8) & 0xFF;
    return (g0 + g2) >= (g1 + g3);
}

fn emit_quad(vertices: *std.ArrayList(Vertex), verts: [4]Vertex) void {
    if (brighter_along_02(verts)) {
        // Diagonal 0-2 (original winding).
        vertices.appendAssumeCapacity(verts[0]);
        vertices.appendAssumeCapacity(verts[2]);
        vertices.appendAssumeCapacity(verts[1]);
        vertices.appendAssumeCapacity(verts[0]);
        vertices.appendAssumeCapacity(verts[3]);
        vertices.appendAssumeCapacity(verts[2]);
    } else {
        // Diagonal 1-3 (flipped, same winding orientation).
        vertices.appendAssumeCapacity(verts[0]);
        vertices.appendAssumeCapacity(verts[3]);
        vertices.appendAssumeCapacity(verts[1]);
        vertices.appendAssumeCapacity(verts[1]);
        vertices.appendAssumeCapacity(verts[3]);
        vertices.appendAssumeCapacity(verts[2]);
    }
}

/// Specialization of emit_quad for uniform corner colors. brighter_along_02
/// always picks diagonal 0-2 when the four greens match, so the per-quad
/// 4 byte-extracts + add + compare are pure waste on the non-AO path. Any
/// caller that builds verts via uniform_colors should use this.
fn emit_quad_uniform(vertices: *std.ArrayList(Vertex), verts: [4]Vertex) void {
    vertices.appendAssumeCapacity(verts[0]);
    vertices.appendAssumeCapacity(verts[2]);
    vertices.appendAssumeCapacity(verts[1]);
    vertices.appendAssumeCapacity(verts[0]);
    vertices.appendAssumeCapacity(verts[3]);
    vertices.appendAssumeCapacity(verts[2]);
}

fn emit_quad_reversed(vertices: *std.ArrayList(Vertex), verts: [4]Vertex) void {
    vertices.appendAssumeCapacity(verts[0]);
    vertices.appendAssumeCapacity(verts[1]);
    vertices.appendAssumeCapacity(verts[2]);
    vertices.appendAssumeCapacity(verts[0]);
    vertices.appendAssumeCapacity(verts[2]);
    vertices.appendAssumeCapacity(verts[3]);
}

fn emit_quad_uniform_double_sided(vertices: *std.ArrayList(Vertex), verts: [4]Vertex) void {
    emit_quad_uniform(vertices, verts);
    emit_quad_reversed(vertices, verts);
}

// -- Public emission functions ------------------------------------------------

/// Emit one block face (6 vertices). All 4 corners share `color`, so the
/// AO-aware brighter-diagonal pick is skipped.
pub fn emit_face(
    vertices: *std.ArrayList(Vertex),
    face: Face,
    x: u32,
    y: u32,
    z: u32,
    tile: BlockRegistry.Tile,
    atlas: *const TextureAtlas,
    shadowed: bool,
) void {
    const base = face_color(face);
    const color = if (shadowed) apply_shadow(base) else base;
    const uv = tile_uvs(tile, atlas);
    emit_quad_uniform(vertices, make_quad(
        face,
        encode_pos(x),
        encode_pos(x + 1),
        encode_pos(y),
        encode_pos(y + 1),
        encode_pos(z),
        encode_pos(z + 1),
        uv.tu0,
        uv.tv0,
        uv.tu1,
        uv.tv1,
        uniform_colors(color),
    ));
}

/// Emit one block face (6 vertices) with per-corner colors. Used by the AO
/// path; `colors[i]` is applied to vertex `i` as laid out by `make_quad`.
pub fn emit_face_colors(
    vertices: *std.ArrayList(Vertex),
    face: Face,
    x: u32,
    y: u32,
    z: u32,
    tile: BlockRegistry.Tile,
    atlas: *const TextureAtlas,
    colors: [4]u32,
) void {
    const uv = tile_uvs(tile, atlas);
    emit_quad(vertices, make_quad(
        face,
        encode_pos(x),
        encode_pos(x + 1),
        encode_pos(y),
        encode_pos(y + 1),
        encode_pos(z),
        encode_pos(z + 1),
        uv.tu0,
        uv.tv0,
        uv.tu1,
        uv.tv1,
        colors,
    ));
}

/// Emit one face of a half-height slab (6 vertices). Top face sits at
/// y + 0.5; side faces span [y, y + 0.5]; bottom face is unchanged.
pub fn emit_slab_face(
    vertices: *std.ArrayList(Vertex),
    face: Face,
    x: u32,
    y: u32,
    z: u32,
    tile: BlockRegistry.Tile,
    atlas: *const TextureAtlas,
    shadowed: bool,
) void {
    const base = face_color(face);
    const color = if (shadowed) apply_shadow(base) else base;
    const uv = tile_uvs(tile, atlas);
    // 128/256 = 0.5 block. Top face sits at y + 0.5; sides span [y, y+0.5].
    const py_top: i16 = encode_pos_frac(y, 128);
    const py_bot: i16 = encode_pos(y);
    // make_quad uses only py1 for y_pos and only py for y_neg, so the
    // unused bound on those faces is harmless.
    const py0: i16 = if (face == .y_pos) py_top else py_bot;
    const py1: i16 = py_top;

    // Side faces sample only the lower half of the tile so the texture
    // matches the geometry rather than getting squashed.
    const use_lower_half = face != .y_pos and face != .y_neg;
    const half_v: i16 = @intCast(@divTrunc(@as(i32, uv.tv1) - @as(i32, uv.tv0), 2));
    const tv0: i16 = if (use_lower_half) @intCast(@as(i32, uv.tv0) + half_v) else uv.tv0;

    emit_quad_uniform(vertices, make_quad(
        face,
        encode_pos(x),
        encode_pos(x + 1),
        py0,
        py1,
        encode_pos(z),
        encode_pos(z + 1),
        uv.tu0,
        tv0,
        uv.tu1,
        uv.tv1,
        uniform_colors(color),
    ));
}

/// Emit one side face of a fluid block (6 vertices). The top of the quad
/// matches the fluid top plane (inset ~0.9 blocks) when the block above is
/// not also fluid; otherwise it spans the full block so stacked fluid
/// columns remain flush. Not valid for y_pos / y_neg faces.
pub fn emit_fluid_side_face(
    vertices: *std.ArrayList(Vertex),
    face: Face,
    x: u32,
    y: u32,
    z: u32,
    tile: BlockRegistry.Tile,
    atlas: *const TextureAtlas,
    shadowed: bool,
    above_is_fluid: bool,
) void {
    std.debug.assert(face != .y_pos and face != .y_neg);
    const base = face_color(face);
    const color = if (shadowed) apply_shadow(base) else base;
    const uv = tile_uvs(tile, atlas);
    const py_top: i16 = if (above_is_fluid) encode_pos(y + 1) else encode_pos_frac(y, 230);
    const tile_h: i32 = @as(i32, uv.tv1) - @as(i32, uv.tv0);
    const tv0: i16 = if (above_is_fluid) uv.tv0 else @intCast(@as(i32, uv.tv1) - @divTrunc(tile_h * 230, 256));
    emit_quad_uniform(vertices, make_quad(
        face,
        encode_pos(x),
        encode_pos(x + 1),
        encode_pos(y),
        py_top,
        encode_pos(z),
        encode_pos(z + 1),
        uv.tu0,
        tv0,
        uv.tu1,
        uv.tv1,
        uniform_colors(color),
    ));
}

/// Emit fluid top face at 0.9 block height, double-sided (12 vertices).
pub fn emit_fluid_top(
    vertices: *std.ArrayList(Vertex),
    x: u32,
    y: u32,
    z: u32,
    tile: BlockRegistry.Tile,
    atlas: *const TextureAtlas,
    shadowed: bool,
) void {
    const color: u32 = if (shadowed) apply_shadow(0xFFFFFFFF) else 0xFFFFFFFF;
    const uv = tile_uvs(tile, atlas);
    emit_quad_uniform_double_sided(vertices, make_quad(
        .y_pos,
        encode_pos(x),
        encode_pos(x + 1),
        encode_pos(y),
        encode_pos_frac(y, 230),
        encode_pos(z),
        encode_pos(z + 1),
        uv.tu0,
        uv.tv0,
        uv.tu1,
        uv.tv1,
        uniform_colors(color),
    ));
}

/// Emit a fluid-overlay face on a transparent block's boundary with fluid.
/// Inset 1/256 block past the boundary toward the fluid so the face sits
/// just in front of the transparent block's own face when viewed from the
/// fluid side, passing the depth test. Perpendicular axes are expanded by
/// the same amount to close hairline seams at block corners. (6 vertices)
pub fn emit_fluid_overlay(
    vertices: *std.ArrayList(Vertex),
    face: Face,
    x: u32,
    y: u32,
    z: u32,
    tile: BlockRegistry.Tile,
    atlas: *const TextureAtlas,
    shadowed: bool,
) void {
    const base = face_color(face);
    const color = if (shadowed) apply_shadow(base) else base;
    const uv = tile_uvs(tile, atlas);

    var px = encode_pos(x);
    var px1 = encode_pos(x + 1);
    var py = encode_pos(y);
    var py1 = encode_pos(y + 1);
    var pz = encode_pos(z);
    var pz1 = encode_pos(z + 1);

    // Shift the face plane 1/256 block past the boundary (toward the fluid)
    // and expand perpendicular axes by the same amount to close corner seams.
    const INSET: i16 = 8; // 1/256 block in SNORM16 encoding
    switch (face) {
        .x_pos => {
            px1 = px1 +| INSET;
            py = py -| INSET;
            py1 = py1 +| INSET;
            pz = pz -| INSET;
            pz1 = pz1 +| INSET;
        },
        .x_neg => {
            px = px -| INSET;
            py = py -| INSET;
            py1 = py1 +| INSET;
            pz = pz -| INSET;
            pz1 = pz1 +| INSET;
        },
        .y_pos => {
            py1 = py1 +| INSET;
            px = px -| INSET;
            px1 = px1 +| INSET;
            pz = pz -| INSET;
            pz1 = pz1 +| INSET;
        },
        .y_neg => {
            py = py -| INSET;
            px = px -| INSET;
            px1 = px1 +| INSET;
            pz = pz -| INSET;
            pz1 = pz1 +| INSET;
        },
        .z_pos => {
            pz1 = pz1 +| INSET;
            px = px -| INSET;
            px1 = px1 +| INSET;
            py = py -| INSET;
            py1 = py1 +| INSET;
        },
        .z_neg => {
            pz = pz -| INSET;
            px = px -| INSET;
            px1 = px1 +| INSET;
            py = py -| INSET;
            py1 = py1 +| INSET;
        },
    }

    emit_quad_uniform(vertices, make_quad(face, px, px1, py, py1, pz, pz1, uv.tu0, uv.tv0, uv.tu1, uv.tv1, uniform_colors(color)));
}

/// Emit two intersecting diagonal planes for cross-plants (24 vertices).
pub fn emit_cross(
    vertices: *std.ArrayList(Vertex),
    x: u32,
    y: u32,
    z: u32,
    tile: BlockRegistry.Tile,
    atlas: *const TextureAtlas,
    shadowed: bool,
) void {
    const color: u32 = if (shadowed) apply_shadow(0xFFFFFFFF) else 0xFFFFFFFF;
    const uv = tile_uvs(tile, atlas);
    const px = encode_pos(x);
    const px1 = encode_pos(x + 1);
    const py = encode_pos(y);
    const py1 = encode_pos(y + 1);
    const pz = encode_pos(z);
    const pz1 = encode_pos(z + 1);

    // Back faces swap tu0/tu1 so the reversed winding does not mirror the
    // texture when the quad is viewed from behind.
    emit_quad_uniform(vertices, .{
        .{ .pos = .{ px, py, pz }, .uv = .{ uv.tu0, uv.tv1 }, .color = color },
        .{ .pos = .{ px1, py, pz1 }, .uv = .{ uv.tu1, uv.tv1 }, .color = color },
        .{ .pos = .{ px1, py1, pz1 }, .uv = .{ uv.tu1, uv.tv0 }, .color = color },
        .{ .pos = .{ px, py1, pz }, .uv = .{ uv.tu0, uv.tv0 }, .color = color },
    });
    emit_quad_reversed(vertices, .{
        .{ .pos = .{ px, py, pz }, .uv = .{ uv.tu1, uv.tv1 }, .color = color },
        .{ .pos = .{ px1, py, pz1 }, .uv = .{ uv.tu0, uv.tv1 }, .color = color },
        .{ .pos = .{ px1, py1, pz1 }, .uv = .{ uv.tu0, uv.tv0 }, .color = color },
        .{ .pos = .{ px, py1, pz }, .uv = .{ uv.tu1, uv.tv0 }, .color = color },
    });

    emit_quad_uniform(vertices, .{
        .{ .pos = .{ px1, py, pz }, .uv = .{ uv.tu0, uv.tv1 }, .color = color },
        .{ .pos = .{ px, py, pz1 }, .uv = .{ uv.tu1, uv.tv1 }, .color = color },
        .{ .pos = .{ px, py1, pz1 }, .uv = .{ uv.tu1, uv.tv0 }, .color = color },
        .{ .pos = .{ px1, py1, pz }, .uv = .{ uv.tu0, uv.tv0 }, .color = color },
    });
    emit_quad_reversed(vertices, .{
        .{ .pos = .{ px1, py, pz }, .uv = .{ uv.tu1, uv.tv1 }, .color = color },
        .{ .pos = .{ px, py, pz1 }, .uv = .{ uv.tu0, uv.tv1 }, .color = color },
        .{ .pos = .{ px, py1, pz1 }, .uv = .{ uv.tu0, uv.tv0 }, .color = color },
        .{ .pos = .{ px1, py1, pz }, .uv = .{ uv.tu1, uv.tv0 }, .color = color },
    });
}
