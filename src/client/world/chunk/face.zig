const std = @import("std");
const assert = std.debug.assert;
const core = @import("core");
const blocks = core.blocks;
const TextureAtlas = @import("../../graphics/TextureAtlas.zig").TextureAtlas;
const Rendering = @import("aether").Rendering;
const Vertex = Rendering.Vertex;
const BatchMesh = Rendering.MeshDataType(Vertex);

pub const Face = blocks.Face;

/// Map local coordinate [0, 16] to SNORM16 [0, 32767].
pub fn encode_pos(local: u32) i16 {
    assert(local <= 16);
    return @intCast(@min(@as(i32, @intCast(local)) * 2048, 32767));
}

/// Encode position with fractional offset (units of 1/256 block).
pub fn encode_pos_frac(local: u32, frac256: u32) i16 {
    assert(local <= 16);
    assert(frac256 <= 256);
    assert(local < 16 or frac256 == 0);
    return @intCast(@min(@as(i32, @intCast(local)) * 2048 + @as(i32, @intCast(frac256)) * 8, 32767));
}

pub fn face_color(face: Face) u32 {
    return switch (face) {
        .y_pos => 0xFFFFFFFF,
        .y_neg => 0xFF7F7F7F,
        .x_neg, .x_pos => 0xFF999999,
        .z_neg, .z_pos => 0xFFCCCCCC,
    };
}

pub fn apply_shadow(color: u32) u32 {
    const r = (color >> 16) & 0xFF;
    const g = (color >> 8) & 0xFF;
    const b = color & 0xFF;
    const a = color & 0xFF000000;
    return a | (((r * 153) >> 8) << 16) | (((g * 153) >> 8) << 8) | ((b * 153) >> 8);
}

const UVRect = struct { tu0: i16, tv0: i16, tu1: i16, tv1: i16 };

fn tile_uvs(tile: blocks.Tile, atlas: *const TextureAtlas) UVRect {
    const base_u = atlas.tile_u(tile.col);
    const base_v = atlas.tile_v(tile.row);
    return .{
        .tu0 = @intCast(@as(i32, base_u) + @as(i32, atlas.tile_width())),
        .tv0 = base_v,
        .tu1 = base_u,
        .tv1 = @intCast(@as(i32, base_v) + @as(i32, atlas.tile_height())),
    };
}

pub fn uniform_colors(c: u32) [4]u32 {
    return .{ c, c, c, c };
}

fn make_quad(face: Face, px: i16, px1: i16, py: i16, py1: i16, pz: i16, pz1: i16, tu0: i16, tv0: i16, tu1: i16, tv1: i16, colors: [4]u32) [4]Vertex {
    // The face-normal interval may collapse (for example a slab's top).
    assert(px <= px1 and (face == .x_pos or face == .x_neg or px < px1));
    assert(py <= py1 and (face == .y_pos or face == .y_neg or py < py1));
    assert(pz <= pz1 and (face == .z_pos or face == .z_neg or pz < pz1));
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

fn emit_quad(mesh: *BatchMesh, verts: [4]Vertex) void {
    if (brighter_along_02(verts)) {
        mesh.add_quad_assume_capacity(verts[0], verts[3], verts[2], verts[1]);
    } else {
        mesh.add_quad_assume_capacity(verts[3], verts[2], verts[1], verts[0]);
    }
}

/// Uniform colors always select diagonal 0-2, so bypass the AO comparison.
fn emit_quad_uniform(mesh: *BatchMesh, verts: [4]Vertex) void {
    mesh.add_quad_assume_capacity(verts[0], verts[3], verts[2], verts[1]);
}

fn emit_quad_reversed(mesh: *BatchMesh, verts: [4]Vertex) void {
    mesh.add_quad_assume_capacity(verts[0], verts[1], verts[2], verts[3]);
}

fn emit_quad_uniform_double_sided(mesh: *BatchMesh, verts: [4]Vertex) void {
    emit_quad_uniform(mesh, verts);
    emit_quad_reversed(mesh, verts);
}

pub fn emit_face(
    mesh: *BatchMesh,
    face: Face,
    x: u32,
    y: u32,
    z: u32,
    tile: blocks.Tile,
    atlas: *const TextureAtlas,
    shadowed: bool,
) void {
    const base = face_color(face);
    const color = if (shadowed) apply_shadow(base) else base;
    const uv = tile_uvs(tile, atlas);
    emit_quad_uniform(mesh, make_quad(
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

/// `colors` follows the vertex order produced by `make_quad`.
pub fn emit_face_colors(
    mesh: *BatchMesh,
    face: Face,
    x: u32,
    y: u32,
    z: u32,
    tile: blocks.Tile,
    atlas: *const TextureAtlas,
    colors: [4]u32,
) void {
    const uv = tile_uvs(tile, atlas);
    emit_quad(mesh, make_quad(
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

pub fn emit_slab_face(
    mesh: *BatchMesh,
    face: Face,
    x: u32,
    y: u32,
    z: u32,
    tile: blocks.Tile,
    atlas: *const TextureAtlas,
    shadowed: bool,
) void {
    const base = face_color(face);
    const color = if (shadowed) apply_shadow(base) else base;
    const uv = tile_uvs(tile, atlas);
    const py_top: i16 = encode_pos_frac(y, 128);
    const py_bot: i16 = encode_pos(y);
    const py0: i16 = if (face == .y_pos) py_top else py_bot;
    const py1: i16 = py_top;

    // Crop the lower half of the tile rather than squash its texture.
    const use_lower_half = face != .y_pos and face != .y_neg;
    const half_v: i16 = @intCast(@divTrunc(@as(i32, uv.tv1) - @as(i32, uv.tv0), 2));
    const tv0: i16 = if (use_lower_half) @intCast(@as(i32, uv.tv0) + half_v) else uv.tv0;

    emit_quad_uniform(mesh, make_quad(
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

/// Exposed sides meet the inset fluid top; stacked sides span the full block.
pub fn emit_fluid_side_face(
    mesh: *BatchMesh,
    face: Face,
    x: u32,
    y: u32,
    z: u32,
    tile: blocks.Tile,
    atlas: *const TextureAtlas,
    shadowed: bool,
    above_is_fluid: bool,
) void {
    assert(face != .y_pos and face != .y_neg);
    const base = face_color(face);
    const color = if (shadowed) apply_shadow(base) else base;
    const uv = tile_uvs(tile, atlas);
    const py_top: i16 = if (above_is_fluid) encode_pos(y + 1) else encode_pos_frac(y, 230);
    const tile_h: i32 = @as(i32, uv.tv1) - @as(i32, uv.tv0);
    const tv0: i16 = if (above_is_fluid) uv.tv0 else @intCast(@as(i32, uv.tv1) - @divTrunc(tile_h * 230, 256));
    emit_quad_uniform(mesh, make_quad(
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

/// Double-sided fluid surface at 0.9 block height.
pub fn emit_fluid_top(
    mesh: *BatchMesh,
    x: u32,
    y: u32,
    z: u32,
    tile: blocks.Tile,
    atlas: *const TextureAtlas,
    shadowed: bool,
) void {
    const color: u32 = if (shadowed) apply_shadow(0xFFFFFFFF) else 0xFFFFFFFF;
    const uv = tile_uvs(tile, atlas);
    emit_quad_uniform_double_sided(mesh, make_quad(
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

/// Offset 1/256 block toward the fluid to pass the transparent face's depth
/// test, and expand the other axes by the same amount to close corner seams.
pub fn emit_fluid_overlay(
    mesh: *BatchMesh,
    face: Face,
    x: u32,
    y: u32,
    z: u32,
    tile: blocks.Tile,
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

    const Inset: i16 = 8;
    switch (face) {
        .x_pos => {
            px1 = px1 +| Inset;
            py = py -| Inset;
            py1 = py1 +| Inset;
            pz = pz -| Inset;
            pz1 = pz1 +| Inset;
        },
        .x_neg => {
            px = px -| Inset;
            py = py -| Inset;
            py1 = py1 +| Inset;
            pz = pz -| Inset;
            pz1 = pz1 +| Inset;
        },
        .y_pos => {
            py1 = py1 +| Inset;
            px = px -| Inset;
            px1 = px1 +| Inset;
            pz = pz -| Inset;
            pz1 = pz1 +| Inset;
        },
        .y_neg => {
            py = py -| Inset;
            px = px -| Inset;
            px1 = px1 +| Inset;
            pz = pz -| Inset;
            pz1 = pz1 +| Inset;
        },
        .z_pos => {
            pz1 = pz1 +| Inset;
            px = px -| Inset;
            px1 = px1 +| Inset;
            py = py -| Inset;
            py1 = py1 +| Inset;
        },
        .z_neg => {
            pz = pz -| Inset;
            px = px -| Inset;
            px1 = px1 +| Inset;
            py = py -| Inset;
            py1 = py1 +| Inset;
        },
    }

    emit_quad_uniform(mesh, make_quad(face, px, px1, py, py1, pz, pz1, uv.tu0, uv.tv0, uv.tu1, uv.tv1, uniform_colors(color)));
}

pub fn emit_cross(
    mesh: *BatchMesh,
    x: u32,
    y: u32,
    z: u32,
    tile: blocks.Tile,
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
    emit_quad_uniform(mesh, .{
        .{ .pos = .{ px, py, pz }, .uv = .{ uv.tu0, uv.tv1 }, .color = color },
        .{ .pos = .{ px1, py, pz1 }, .uv = .{ uv.tu1, uv.tv1 }, .color = color },
        .{ .pos = .{ px1, py1, pz1 }, .uv = .{ uv.tu1, uv.tv0 }, .color = color },
        .{ .pos = .{ px, py1, pz }, .uv = .{ uv.tu0, uv.tv0 }, .color = color },
    });
    emit_quad_reversed(mesh, .{
        .{ .pos = .{ px, py, pz }, .uv = .{ uv.tu1, uv.tv1 }, .color = color },
        .{ .pos = .{ px1, py, pz1 }, .uv = .{ uv.tu0, uv.tv1 }, .color = color },
        .{ .pos = .{ px1, py1, pz1 }, .uv = .{ uv.tu0, uv.tv0 }, .color = color },
        .{ .pos = .{ px, py1, pz }, .uv = .{ uv.tu1, uv.tv0 }, .color = color },
    });

    emit_quad_uniform(mesh, .{
        .{ .pos = .{ px1, py, pz }, .uv = .{ uv.tu0, uv.tv1 }, .color = color },
        .{ .pos = .{ px, py, pz1 }, .uv = .{ uv.tu1, uv.tv1 }, .color = color },
        .{ .pos = .{ px, py1, pz1 }, .uv = .{ uv.tu1, uv.tv0 }, .color = color },
        .{ .pos = .{ px1, py1, pz }, .uv = .{ uv.tu0, uv.tv0 }, .color = color },
    });
    emit_quad_reversed(mesh, .{
        .{ .pos = .{ px1, py, pz }, .uv = .{ uv.tu1, uv.tv1 }, .color = color },
        .{ .pos = .{ px, py, pz1 }, .uv = .{ uv.tu0, uv.tv1 }, .color = color },
        .{ .pos = .{ px, py1, pz1 }, .uv = .{ uv.tu0, uv.tv0 }, .color = color },
        .{ .pos = .{ px1, py1, pz }, .uv = .{ uv.tu1, uv.tv0 }, .color = color },
    });
}

test "vertical faces preserve their U orientation" {
    const faces = [_]Face{ .x_neg, .x_pos, .z_neg, .z_pos };
    const expected_u = [_]i16{ 20, 10, 10, 20 };

    for (faces) |face| {
        const verts = make_quad(face, 0, 1, 2, 3, 4, 5, 20, 30, 10, 40, uniform_colors(0));
        for (expected_u, 0..) |u, i| {
            try std.testing.expectEqual(u, verts[i].uv[0]);
        }
    }
}
