// Portions adapted from ClassiCube (https://github.com/ClassiCube/ClassiCube) by UnknownShadow200.
// - Isometric block drawer: adapted from ClassiCube's IsometricDrawer
//   (https://github.com/ClassiCube/ClassiCube/blob/master/src/IsometricDrawer.c)
// See THIRD_PARTY_NOTICES.md for the full BSD 3-Clause license text.
//
// Ported to Zig for CrossCraft (GPLv2; uses separate Aether-Engine).
// Modifications Copyright (c) 2026 CrossCraft

// Projects the three visible cube faces into a screen-space SNORM16 mesh.

const std = @import("std");
const assert = std.debug.assert;
const ae = @import("aether");
const UI = ae.UI;
const Math = ae.Math;
const Rendering = ae.Rendering;

const Block = @import("core").blocks.Block;

const Vertex = @import("aether").Rendering.Vertex;
const TextureAtlas = @import("../graphics/TextureAtlas.zig").TextureAtlas;
const Face = @import("../world/chunk/face.zig").Face;
const Scaling = UI.Scaling;

const IsoBlockDrawer = @This();

const ROT_Y_RAD: f32 = std.math.pi * 0.25;
const ROT_X_RAD: f32 = -std.math.pi / 6.0;
const PROJ_HALF: f32 = 0.7071068;

// Keep the HUD pass away from the PSP's +Z clip edge.
pub const ISO_LAYER: u8 = 250;
const ISO_Z: i16 = 32766 - @as(i16, ISO_LAYER);

const QUADS_PER_BLOCK: usize = 3;
const MAX_BLOCKS: usize = 9 + 45;
const QUAD_CAPACITY: usize = MAX_BLOCKS * QUADS_PER_BLOCK;

pub const Payload = struct {
    block: Block,
    cx: f32,
    cy: f32,
    half_extent_px: f32,
};

terrain: *const Rendering.Texture,
atlas: TextureAtlas,
mesh_data: Rendering.MeshDataType(Vertex),
mesh: Rendering.MeshType(Vertex),
iso_xform: Math.Mat4,
allocator: std.mem.Allocator,

pub fn init(
    allocator: std.mem.Allocator,
    terrain: *const Rendering.Texture,
    atlas: TextureAtlas,
) !IsoBlockDrawer {
    const iso = Math.Mat4.rotationY(ROT_Y_RAD).mul(Math.Mat4.rotationX(ROT_X_RAD));
    var self: IsoBlockDrawer = .{
        .terrain = terrain,
        .atlas = atlas,
        .mesh_data = try Rendering.MeshDataType(Vertex).init(allocator),
        .mesh = try Rendering.MeshType(Vertex).init(&.{}),
        .iso_xform = iso,
        .allocator = allocator,
    };
    try self.mesh_data.ensure_quad_capacity(allocator, QUAD_CAPACITY);
    return self;
}

pub fn deinit(self: *IsoBlockDrawer) void {
    self.mesh.deinit();
    self.mesh_data.deinit(self.allocator);
    self.* = undefined;
}

pub fn begin(self: *IsoBlockDrawer) void {
    self.mesh_data.clear_retaining_capacity();
}

pub fn add_payload(self: *IsoBlockDrawer, payload: Payload) void {
    const block = payload.block;
    const cx = payload.cx;
    const cy = payload.cy;
    const half_extent_px = payload.half_extent_px;
    assert(half_extent_px > 0);
    if (block.is_air()) return;

    const p = block.mesh_props();

    if (p.cross) {
        self.add_flat(block, cx, cy, half_extent_px);
        return;
    }

    const is_slab = p.slab;

    const h: f32 = half_extent_px / PROJ_HALF;
    const y_top: f32 = if (is_slab) 0.0 else h;
    const y_bot: f32 = -h;

    self.emit_iso_face(.x_pos, h, y_bot, y_top, cx, cy, block, is_slab);
    self.emit_iso_face(.z_neg, h, y_bot, y_top, cx, cy, block, is_slab);
    self.emit_iso_face(.y_pos, h, y_bot, y_top, cx, cy, block, is_slab);
}

pub fn update(self: *IsoBlockDrawer) void {
    if (self.mesh_data.vertices.items.len == 0) return;
    self.mesh.update(&self.mesh_data);
}

pub fn draw(self: *IsoBlockDrawer) void {
    if (self.mesh_data.vertices.items.len == 0) return;

    Rendering.gfx.api.set_proj_matrix(&Math.Mat4.identity());
    Rendering.gfx.api.set_view_matrix(&Math.Mat4.identity());
    Rendering.set_state(&.{ .texture = self.terrain.handle });

    const ident = Math.Mat4.identity();
    self.mesh.draw(&ident);
}

fn project_xy(self: *const IsoBlockDrawer, vx: f32, vy: f32, vz: f32, cx: f32, cy: f32) [2]f32 {
    const m = self.iso_xform.data;
    const ox = vx * m[0][0] + vy * m[1][0] + vz * m[2][0] + m[3][0];
    const oy = vx * m[0][1] + vy * m[1][1] + vz * m[2][1] + m[3][1];
    return .{ cx + ox, cy - oy };
}

// Convert straight from float logical coordinates to preserve sub-pixel shape.
fn ndc_xy(px_log: f32, py_log: f32) [2]i16 {
    const screen_w = Rendering.gfx.surface.get_width();
    const screen_h = Rendering.gfx.surface.get_height();
    const scale: f32 = @floatFromInt(Scaling.compute(screen_w, screen_h));
    const sw: f32 = @floatFromInt(screen_w);
    const sh: f32 = @floatFromInt(screen_h);
    const max_lx: f32 = sw / scale;
    const max_ly: f32 = sh / scale;
    const x = std.math.clamp(px_log, 0.0, max_lx);
    const y = std.math.clamp(py_log, 0.0, max_ly);
    const fx = (2.0 * x * scale - sw) * 32767.0 / sw;
    const fy = (sh - 2.0 * y * scale) * 32767.0 / sh;
    return .{
        @intFromFloat(@round(std.math.clamp(fx, -32767.0, 32767.0))),
        @intFromFloat(@round(std.math.clamp(fy, -32767.0, 32767.0))),
    };
}

fn emit_iso_face(
    self: *IsoBlockDrawer,
    face: Face,
    h: f32,
    y_bot: f32,
    y_top: f32,
    cx: f32,
    cy: f32,
    block: Block,
    is_slab: bool,
) void {
    const tile = block.face_tile(face);
    const base_u: i32 = self.atlas.tile_u(tile.col);
    const base_v: i32 = self.atlas.tile_v(tile.row);
    const tw: i32 = self.atlas.tile_width();
    const th: i32 = self.atlas.tile_height();

    const tu0: i16 = @intCast(base_u);
    const tu1: i16 = @intCast(base_u + tw);
    const slab_side = is_slab and (face == .x_pos or face == .z_neg);
    const tv0: i16 = if (slab_side) @intCast(base_v + @divTrunc(th, 2)) else @intCast(base_v);
    const tv1: i16 = @intCast(base_v + th);

    const color: u32 = switch (face) {
        .y_pos => 0xFFFFFFFF,
        .x_pos => 0xFF999999,
        .z_neg => 0xFFCCCCCC,
        else => unreachable,
    };

    const corners: [4][3]f32 = switch (face) {
        .x_pos => .{
            .{ h, y_bot, -h },
            .{ h, y_bot, h },
            .{ h, y_top, h },
            .{ h, y_top, -h },
        },
        .z_neg => .{
            .{ -h, y_bot, -h },
            .{ h, y_bot, -h },
            .{ h, y_top, -h },
            .{ -h, y_top, -h },
        },
        .y_pos => .{
            .{ -h, y_top, -h },
            .{ h, y_top, -h },
            .{ h, y_top, h },
            .{ -h, y_top, h },
        },
        else => unreachable,
    };

    const uvs: [4][2]i16 = .{
        .{ tu0, tv1 },
        .{ tu1, tv1 },
        .{ tu1, tv0 },
        .{ tu0, tv0 },
    };

    var verts: [4]Vertex = undefined;
    inline for (0..4) |i| {
        const xy = self.project_xy(corners[i][0], corners[i][1], corners[i][2], cx, cy);
        const ndc = ndc_xy(xy[0], xy[1]);
        verts[i] = .{
            .pos = .{ ndc[0], ndc[1], ISO_Z },
            .uv = uvs[i],
            .color = color,
        };
    }

    self.emit_quad(&verts);
}

fn add_flat(self: *IsoBlockDrawer, block: Block, cx: f32, cy: f32, scale: f32) void {
    const tile = block.face_tile(.z_pos);
    const base_u: i32 = self.atlas.tile_u(tile.col);
    const base_v: i32 = self.atlas.tile_v(tile.row);
    const tw: i32 = self.atlas.tile_width();
    const th: i32 = self.atlas.tile_height();

    const tu0: i16 = @intCast(base_u);
    const tu1: i16 = @intCast(base_u + tw);
    const tv0: i16 = @intCast(base_v);
    const tv1: i16 = @intCast(base_v + th);

    const plane_scale: f32 = 1 + (scale - 4.5) / 4.5;
    const flat_half: f32 = 8 * plane_scale;
    const x0 = cx - flat_half;
    const x1 = cx + flat_half;
    const y0 = cy - flat_half;
    const y1 = cy + flat_half;

    const tl = ndc_xy(x0, y0);
    const tr = ndc_xy(x1, y0);
    const br = ndc_xy(x1, y1);
    const bl = ndc_xy(x0, y1);

    const white: u32 = 0xFFFFFFFF;
    const verts: [4]Vertex = .{
        .{ .pos = .{ tl[0], tl[1], ISO_Z }, .uv = .{ tu0, tv0 }, .color = white },
        .{ .pos = .{ tr[0], tr[1], ISO_Z }, .uv = .{ tu1, tv0 }, .color = white },
        .{ .pos = .{ br[0], br[1], ISO_Z }, .uv = .{ tu1, tv1 }, .color = white },
        .{ .pos = .{ bl[0], bl[1], ISO_Z }, .uv = .{ tu0, tv1 }, .color = white },
    };
    self.emit_quad(&verts);
}

fn emit_quad(self: *IsoBlockDrawer, verts: *const [4]Vertex) void {
    const ax: i32 = verts[1].pos[0] - verts[0].pos[0];
    const ay: i32 = verts[1].pos[1] - verts[0].pos[1];
    const bx: i32 = verts[2].pos[0] - verts[0].pos[0];
    const by: i32 = verts[2].pos[1] - verts[0].pos[1];
    const ccw = ax * by - ay * bx > 0;

    if (ccw) {
        self.mesh_data.add_quad_assume_capacity(verts[0], verts[1], verts[2], verts[3]);
    } else {
        self.mesh_data.add_quad_assume_capacity(verts[0], verts[3], verts[2], verts[1]);
    }
}
