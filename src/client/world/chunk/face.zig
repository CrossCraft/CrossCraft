const std = @import("std");
const lut = @import("lut.zig");
const TextureAtlas = @import("../../graphics/TextureAtlas.zig").TextureAtlas;
const Vertex = @import("../../graphics/Vertex.zig").Vertex;

pub const Face = enum(u3) {
    x_neg = 0,
    x_pos = 1,
    y_neg = 2,
    y_pos = 3,
    z_neg = 4,
    z_pos = 5,
};

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
fn face_color(face: Face) u32 {
    return switch (face) {
        .y_pos => 0xFFFFFFFF,
        .y_neg => 0xFF7F7F7F,
        .x_neg, .x_pos => 0xFFBFBFBF,
        .z_neg, .z_pos => 0xFFCCCCCC,
    };
}

const UVRect = struct { tu0: i16, tv0: i16, tu1: i16, tv1: i16 };

fn tile_uvs(tile: lut.Tile, atlas: *const TextureAtlas) UVRect {
    const base_u = atlas.tileU(tile.col);
    const base_v = atlas.tileV(tile.row);
    return .{
        .tu0 = base_u,
        .tv0 = base_v,
        .tu1 = @intCast(@as(i32, base_u) + @as(i32, atlas.tileWidth())),
        .tv1 = @intCast(@as(i32, base_v) + @as(i32, atlas.tileHeight())),
    };
}

fn make_quad(face: Face, px: i16, px1: i16, py: i16, py1: i16, pz: i16, pz1: i16, tu0: i16, tv0: i16, tu1: i16, tv1: i16, color: u32) [4]Vertex {
    return switch (face) {
        .x_pos => .{
            .{ .pos = .{ px1, py, pz }, .uv = .{ tu0, tv1 }, .color = color },
            .{ .pos = .{ px1, py, pz1 }, .uv = .{ tu1, tv1 }, .color = color },
            .{ .pos = .{ px1, py1, pz1 }, .uv = .{ tu1, tv0 }, .color = color },
            .{ .pos = .{ px1, py1, pz }, .uv = .{ tu0, tv0 }, .color = color },
        },
        .x_neg => .{
            .{ .pos = .{ px, py, pz1 }, .uv = .{ tu0, tv1 }, .color = color },
            .{ .pos = .{ px, py, pz }, .uv = .{ tu1, tv1 }, .color = color },
            .{ .pos = .{ px, py1, pz }, .uv = .{ tu1, tv0 }, .color = color },
            .{ .pos = .{ px, py1, pz1 }, .uv = .{ tu0, tv0 }, .color = color },
        },
        .y_pos => .{
            .{ .pos = .{ px, py1, pz }, .uv = .{ tu0, tv0 }, .color = color },
            .{ .pos = .{ px1, py1, pz }, .uv = .{ tu1, tv0 }, .color = color },
            .{ .pos = .{ px1, py1, pz1 }, .uv = .{ tu1, tv1 }, .color = color },
            .{ .pos = .{ px, py1, pz1 }, .uv = .{ tu0, tv1 }, .color = color },
        },
        .y_neg => .{
            .{ .pos = .{ px, py, pz1 }, .uv = .{ tu0, tv0 }, .color = color },
            .{ .pos = .{ px1, py, pz1 }, .uv = .{ tu1, tv0 }, .color = color },
            .{ .pos = .{ px1, py, pz }, .uv = .{ tu1, tv1 }, .color = color },
            .{ .pos = .{ px, py, pz }, .uv = .{ tu0, tv1 }, .color = color },
        },
        .z_pos => .{
            .{ .pos = .{ px1, py, pz1 }, .uv = .{ tu0, tv1 }, .color = color },
            .{ .pos = .{ px, py, pz1 }, .uv = .{ tu1, tv1 }, .color = color },
            .{ .pos = .{ px, py1, pz1 }, .uv = .{ tu1, tv0 }, .color = color },
            .{ .pos = .{ px1, py1, pz1 }, .uv = .{ tu0, tv0 }, .color = color },
        },
        .z_neg => .{
            .{ .pos = .{ px, py, pz }, .uv = .{ tu0, tv1 }, .color = color },
            .{ .pos = .{ px1, py, pz }, .uv = .{ tu1, tv1 }, .color = color },
            .{ .pos = .{ px1, py1, pz }, .uv = .{ tu1, tv0 }, .color = color },
            .{ .pos = .{ px, py1, pz }, .uv = .{ tu0, tv0 }, .color = color },
        },
    };
}

fn emit_quad(vertices: *std.ArrayList(Vertex), verts: [4]Vertex) void {
    vertices.appendAssumeCapacity(verts[0]);
    vertices.appendAssumeCapacity(verts[2]);
    vertices.appendAssumeCapacity(verts[1]);
    vertices.appendAssumeCapacity(verts[0]);
    vertices.appendAssumeCapacity(verts[3]);
    vertices.appendAssumeCapacity(verts[2]);
}

fn emit_quad_double_sided(vertices: *std.ArrayList(Vertex), verts: [4]Vertex) void {
    emit_quad(vertices, verts);
    // Back face (reversed winding)
    vertices.appendAssumeCapacity(verts[0]);
    vertices.appendAssumeCapacity(verts[1]);
    vertices.appendAssumeCapacity(verts[2]);
    vertices.appendAssumeCapacity(verts[0]);
    vertices.appendAssumeCapacity(verts[2]);
    vertices.appendAssumeCapacity(verts[3]);
}

// -- Public emission functions ------------------------------------------------

/// Emit one block face (6 vertices).
pub fn emit_face(
    vertices: *std.ArrayList(Vertex),
    face: Face,
    x: u32,
    y: u32,
    z: u32,
    tile: lut.Tile,
    atlas: *const TextureAtlas,
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
        face_color(face),
    ));
}

/// Emit fluid top face at 0.9 block height (6 vertices).
pub fn emit_fluid_top(
    vertices: *std.ArrayList(Vertex),
    x: u32,
    y: u32,
    z: u32,
    tile: lut.Tile,
    atlas: *const TextureAtlas,
) void {
    const uv = tile_uvs(tile, atlas);
    emit_quad(vertices, make_quad(
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
        0xFFFFFFFF,
    ));
}

/// Emit two intersecting diagonal planes for cross-plants (24 vertices).
pub fn emit_cross(
    vertices: *std.ArrayList(Vertex),
    x: u32,
    y: u32,
    z: u32,
    tile: lut.Tile,
    atlas: *const TextureAtlas,
) void {
    const color: u32 = 0xFFFFFFFF;
    const uv = tile_uvs(tile, atlas);
    const px = encode_pos(x);
    const px1 = encode_pos(x + 1);
    const py = encode_pos(y);
    const py1 = encode_pos(y + 1);
    const pz = encode_pos(z);
    const pz1 = encode_pos(z + 1);

    emit_quad_double_sided(vertices, .{
        .{ .pos = .{ px, py, pz }, .uv = .{ uv.tu0, uv.tv1 }, .color = color },
        .{ .pos = .{ px1, py, pz1 }, .uv = .{ uv.tu1, uv.tv1 }, .color = color },
        .{ .pos = .{ px1, py1, pz1 }, .uv = .{ uv.tu1, uv.tv0 }, .color = color },
        .{ .pos = .{ px, py1, pz }, .uv = .{ uv.tu0, uv.tv0 }, .color = color },
    });

    emit_quad_double_sided(vertices, .{
        .{ .pos = .{ px1, py, pz }, .uv = .{ uv.tu0, uv.tv1 }, .color = color },
        .{ .pos = .{ px, py, pz1 }, .uv = .{ uv.tu1, uv.tv1 }, .color = color },
        .{ .pos = .{ px, py1, pz1 }, .uv = .{ uv.tu1, uv.tv0 }, .color = color },
        .{ .pos = .{ px1, py1, pz }, .uv = .{ uv.tu0, uv.tv0 }, .color = color },
    });
}
