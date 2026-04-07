// Portions adapted from ClassiCube[](https://github.com/ClassiCube/ClassiCube) by UnknownShadow200.
// - Map generation & dig animation: primarily from wiki algorithm descriptions
//   (https://github.com/ClassiCube/ClassiCube/wiki/Minecraft-Classic-map-generation-algorithm
//    https://github.com/ClassiCube/ClassiCube/wiki/Dig-animation-details)
// - Physics & view-bob: cross-referenced in part from source code.
// - World generation also includes minimal cross-checks against the original BSD code
//   (e.g. one-line differences).
// See THIRD-PARTY-NOTICES.md for the full BSD 3-Clause license text.
//
// Ported to Zig for CrossCraft (LGPLv3; uses separate Aether-Engine).
// Modifications Copyright (c) 2026 CrossCraft

// 2D isometric block drawer for the hotbar (and any future inventory grids).
//
// Made with reference to ClassiCube and original CrossCraft source: https://github.com/CrossCraft/CrossCraft-Classic/blob/main/src/Player/BlockRep.cpp
//
// Builds a screen-space mesh that LOOKS 3D by hand-projecting cube vertices
// through Y(45 deg) * X(-30 deg) and dropping the Z component, the same trick
// ClassiCube's IsometricDrawer uses. No projection matrix, no depth buffer
// reasoning per face: the three emitted faces (+X, -Z, +Y) never overlap in
// screen space within a single block, and every block uses the same Z layer
// so the GPU draws them in submission order.
//
// Vertex positions are pre-converted to NDC SNORM16 on the CPU and the draw
// runs with identity proj/view, mirroring SpriteBatcher's pipeline state.

const std = @import("std");
const ae = @import("aether");
const Math = ae.Math;
const Util = ae.Util;
const Rendering = ae.Rendering;

const c = @import("common").consts;
const B = c.Block;

const Vertex = @import("../graphics/Vertex.zig").Vertex;
const TextureAtlas = @import("../graphics/TextureAtlas.zig").TextureAtlas;
const BlockRegistry = @import("../world/block/BlockRegistry.zig");
const Face = @import("../world/chunk/face.zig").Face;
const Scaling = @import("Scaling.zig");
const layout = @import("layout.zig");

const Self = @This();

// Inlined RotateY(+45) * RotateX(-30):
//   x_screen = cos45 * (vx + vz)
//   y_object = vx*sin30*sin(-45) + vy*cos30 + vz*sin30*cos(-45)
// We negate y_object when adding to a logical-pixel center because logical Y
// is positive-down: a vertex with vy = +h (top of cube) needs a SMALLER y in
// pixel space so it sits above the cell center.
const COS30: f32 = 0.8660254;
const SIN30: f32 = 0.5;
const COS45: f32 = 0.7071068;
const SIN30_COS45: f32 = SIN30 * COS45;

// Drawn in its own HUD pass between the hotbar background and selector. The
// z value intentionally stays in the older safe HUD band instead of layers
// 1/2, which sit too close to PSP's +Z clip/depth edge.
pub const ISO_LAYER: u8 = 250;
const ISO_Z: i16 = 32766 - @as(i16, ISO_LAYER);

// 3 faces * 6 verts per face. Cross/flat blocks emit only 6 verts so we size
// by the cube worst case.
const VERTS_PER_BLOCK: usize = 18;
// Hotbar is 9 slots; reserving up front keeps the per-frame path alloc-free.
const MAX_BLOCKS: usize = 9;
const VERT_CAPACITY: usize = MAX_BLOCKS * VERTS_PER_BLOCK;

pipeline: Rendering.Pipeline.Handle,
terrain: *const Rendering.Texture,
atlas: TextureAtlas,
mesh: Rendering.Mesh(Vertex),

pub fn init(
    pipeline: Rendering.Pipeline.Handle,
    terrain: *const Rendering.Texture,
    atlas: TextureAtlas,
) !Self {
    var self: Self = .{
        .pipeline = pipeline,
        .terrain = terrain,
        .atlas = atlas,
        .mesh = try Rendering.Mesh(Vertex).new(pipeline),
    };
    self.mesh.primitive = .triangles;
    try self.mesh.vertices.ensureTotalCapacity(Util.allocator(.render), VERT_CAPACITY);
    return self;
}

pub fn deinit(self: *Self) void {
    self.mesh.deinit();
}

/// Begin a new frame's worth of blocks. Drops everything queued so far.
pub fn begin(self: *Self) void {
    self.mesh.vertices.clearRetainingCapacity();
}

/// Queue an isometric block at logical-pixel center (cx, cy).
/// `half_extent_px` is the half-width of the projected cube footprint in
/// logical pixels: a value of 10 yields a ~20 px wide block.
pub fn add_block(
    self: *Self,
    block: u8,
    cx: f32,
    cy: f32,
    half_extent_px: f32,
) void {
    std.debug.assert(half_extent_px > 0);
    if (block == B.Air) return;

    const reg = &BlockRegistry.global;

    // Cross-plant blocks (saplings, flowers, mushrooms) have no cube faces;
    // ClassiCube draws them as a single front-facing quad.
    if (reg.cross.isSet(block)) {
        self.add_flat(block, cx, cy, half_extent_px);
        return;
    }

    const is_slab = reg.slab.isSet(block);

    // Object-space half-extent: chosen so the projected width along x equals
    // exactly 2 * half_extent_px after the rotation collapses (vx, vz) to
    // x_screen = cos45 * (vx + vz).
    const h: f32 = half_extent_px / COS45;
    const y_top: f32 = if (is_slab) 0.0 else h;
    const y_bot: f32 = -h;

    self.emit_iso_face(.x_pos, h, y_bot, y_top, cx, cy, block, is_slab);
    self.emit_iso_face(.z_neg, h, y_bot, y_top, cx, cy, block, is_slab);
    self.emit_iso_face(.y_pos, h, y_bot, y_top, cx, cy, block, is_slab);
}

/// Upload the queued mesh and render it. Sets identity proj/view (matching
/// SpriteBatcher) and binds the terrain texture before drawing.
pub fn flush(self: *Self) void {
    if (self.mesh.vertices.items.len == 0) return;
    self.mesh.update();

    Rendering.gfx.api.set_proj_matrix(&Math.Mat4.identity());
    Rendering.gfx.api.set_view_matrix(&Math.Mat4.identity());
    Rendering.Pipeline.bind(self.pipeline);
    self.terrain.bind();

    const ident = Math.Mat4.identity();
    self.mesh.draw(&ident);
}

// -- Internals ---------------------------------------------------------------

/// Same per-direction shading the world mesher uses, so the cube's three
/// visible faces read at three distinct brightness levels.
fn face_shading(face: Face) u32 {
    return switch (face) {
        .y_pos => 0xFFFFFFFF,
        .x_pos => 0xFF999999,
        .z_neg => 0xFFCCCCCC,
        else => 0xFFFFFFFF,
    };
}

fn project_xy(vx: f32, vy: f32, vz: f32, cx: f32, cy: f32) [2]f32 {
    const x = cx + COS45 * (vx + vz);
    const y = cy + SIN30_COS45 * (vx - vz) - COS30 * vy;
    return .{ x, y };
}

fn ndc_xy(px_log: f32, py_log: f32) [2]i16 {
    const screen_w = Rendering.gfx.surface.get_width();
    const screen_h = Rendering.gfx.surface.get_height();
    const scale = Scaling.compute(screen_w, screen_h);
    // logical_to_snorm_* only produces values inside i16 when its input is
    // in [0, max_l*]; clamping in i16 space alone is not enough because the
    // helper multiplies by 32767 before dividing by the screen dimension.
    const max_lx: f32 = @floatFromInt(screen_w / scale);
    const max_ly: f32 = @floatFromInt(screen_h / scale);
    const cx_pix = std.math.clamp(@round(px_log), 0.0, max_lx);
    const cy_pix = std.math.clamp(@round(py_log), 0.0, max_ly);
    const sx = layout.logical_to_snorm_x(@intFromFloat(cx_pix), screen_w, scale);
    const sy = layout.logical_to_snorm_y(@intFromFloat(cy_pix), screen_h, scale);
    return .{ sx, sy };
}

fn emit_iso_face(
    self: *Self,
    face: Face,
    h: f32,
    y_bot: f32,
    y_top: f32,
    cx: f32,
    cy: f32,
    block: u8,
    is_slab: bool,
) void {
    const reg = &BlockRegistry.global;
    const tile = reg.get_face_tile(block, face);
    const base_u: i32 = self.atlas.tileU(tile.col);
    const base_v: i32 = self.atlas.tileV(tile.row);
    const tw: i32 = self.atlas.tileWidth();
    const th: i32 = self.atlas.tileHeight();

    const tu0: i16 = @intCast(base_u);
    const tu1: i16 = @intCast(base_u + tw);
    // Slabs sample only the lower half of side tiles, matching emit_slab_face
    // in the chunk mesher so the side texture lines up with the half-height
    // geometry instead of getting stretched.
    const slab_side = is_slab and (face == .x_pos or face == .z_neg);
    const tv0: i16 = if (slab_side) @intCast(base_v + @divTrunc(th, 2)) else @intCast(base_v);
    const tv1: i16 = @intCast(base_v + th);

    const color = face_shading(face);

    // Cube corners for each emitted face. Order is (bot-left, bot-right,
    // top-right, top-left) when viewing the face from outside the cube.
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
        const xy = project_xy(corners[i][0], corners[i][1], corners[i][2], cx, cy);
        const ndc = ndc_xy(xy[0], xy[1]);
        verts[i] = .{
            .pos = .{ ndc[0], ndc[1], ISO_Z },
            .uv = uvs[i],
            .color = color,
        };
    }

    self.emit_quad(&verts);
}

fn add_flat(self: *Self, block: u8, cx: f32, cy: f32, half_extent_px: f32) void {
    const reg = &BlockRegistry.global;
    const tile = reg.get_face_tile(block, .z_pos);
    const base_u: i32 = self.atlas.tileU(tile.col);
    const base_v: i32 = self.atlas.tileV(tile.row);
    const tw: i32 = self.atlas.tileWidth();
    const th: i32 = self.atlas.tileHeight();

    const tu0: i16 = @intCast(base_u);
    const tu1: i16 = @intCast(base_u + tw);
    const tv0: i16 = @intCast(base_v);
    const tv1: i16 = @intCast(base_v + th);

    const x0 = cx - half_extent_px;
    const x1 = cx + half_extent_px;
    const y0 = cy - half_extent_px;
    const y1 = cy + half_extent_px;

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

fn emit_quad(self: *Self, verts: *const [4]Vertex) void {
    const ax: i32 = verts[1].pos[0] - verts[0].pos[0];
    const ay: i32 = verts[1].pos[1] - verts[0].pos[1];
    const bx: i32 = verts[2].pos[0] - verts[0].pos[0];
    const by: i32 = verts[2].pos[1] - verts[0].pos[1];
    const ccw = ax * by - ay * bx > 0;

    if (ccw) {
        self.mesh.vertices.appendSliceAssumeCapacity(&.{
            verts[0], verts[1], verts[2],
            verts[0], verts[2], verts[3],
        });
    } else {
        self.mesh.vertices.appendSliceAssumeCapacity(&.{
            verts[0], verts[2], verts[1],
            verts[0], verts[3], verts[2],
        });
    }
}
