const std = @import("std");
const ae = @import("aether");
const Math = ae.Math;
const Rendering = ae.Rendering;

const Scaling = @import("Scaling.zig");
const layout = @import("layout.zig");
const TextureAtlas = @import("../graphics/TextureAtlas.zig").TextureAtlas;

pub const Anchor = layout.Anchor;
pub const Color = @import("../graphics/Color.zig").Color;
pub const Vertex = @import("../graphics/Vertex.zig").Vertex;
pub const BatchMesh = Rendering.Mesh(Vertex);

const Self = @This();

// --- Constants ---

const GLYPH_COLS: u32 = 16;
const GLYPH_ROWS: u32 = 16;
const GLYPH_COUNT: u32 = 256;
const GLYPH_SIZE: u32 = 8;
const SPACE_WIDTH: u8 = 4;
const DEFAULT_SPACING: i8 = 1;
const VERTS_PER_CHAR: u32 = 6;
const MAX_ENTRIES: u16 = 1024;

// --- Input Primitive ---

pub const TextEntry = struct {
    str: []const u8,
    color: Color,
    shadow_color: Color,
    pos_x: i16,
    pos_y: i16,
    spacing: i8,
    layer: u8,
    scale: u8 = 1,
    reference: Anchor,
    origin: Anchor,
};

// --- Fields ---

glyph_widths: [GLYPH_COUNT]u8,
atlas: TextureAtlas,
texture: *const Rendering.Texture,
entries: [2][MAX_ENTRIES]TextEntry,
count: u16,
prev_count: u16,
current: u1,
last_screen_w: u32,
last_screen_h: u32,
mesh: BatchMesh,
pipeline_handle: Rendering.Pipeline.Handle,
allocator: std.mem.Allocator,

// --- Public API ---

pub fn init(allocator: std.mem.Allocator, pipeline: Rendering.Pipeline.Handle, texture: *const Rendering.Texture) !Self {
    std.debug.assert(texture.width == 128);
    std.debug.assert(texture.height == 128);
    return .{
        .glyph_widths = compute_glyph_widths(texture),
        .atlas = TextureAtlas.init(128, 128, GLYPH_ROWS, GLYPH_COLS),
        .texture = texture,
        .entries = undefined,
        .count = 0,
        .prev_count = 0,
        .current = 0,
        .last_screen_w = 0,
        .last_screen_h = 0,
        .mesh = try BatchMesh.new(allocator, pipeline),
        .pipeline_handle = pipeline,
        .allocator = allocator,
    };
}

pub fn deinit(self: *Self) void {
    self.mesh.deinit(self.allocator);
}

pub fn clear(self: *Self) void {
    self.prev_count = self.count;
    self.current ^= 1;
    self.count = 0;
}

pub fn add_text(self: *Self, entry: *const TextEntry) void {
    std.debug.assert(self.count < MAX_ENTRIES);
    std.debug.assert(entry.str.len > 0);
    self.entries[self.current][self.count] = entry.*;
    self.count += 1;
}

pub fn flush(self: *Self) !void {
    if (self.count == 0) return;

    const screen_w = Rendering.gfx.surface.get_width();
    const screen_h = Rendering.gfx.surface.get_height();

    const curr = self.entries[self.current][0..self.count];
    const prev = self.entries[self.current ^ 1][0..self.prev_count];
    const changed = !entries_equal(curr, prev);
    const resized = screen_w != self.last_screen_w or screen_h != self.last_screen_h;

    if (changed or resized) {
        try self.rebuild(screen_w, screen_h);
        self.last_screen_w = screen_w;
        self.last_screen_h = screen_h;
    }

    Rendering.gfx.api.set_proj_matrix(&Math.Mat4.identity());
    Rendering.gfx.api.set_view_matrix(&Math.Mat4.identity());
    Rendering.Pipeline.bind(self.pipeline_handle);
    self.texture.bind();
    self.mesh.draw(&Math.Mat4.identity());
}

/// Returns the width of a string in logical pixels, accounting for per-glyph
/// variable widths, inter-character spacing, and text scale.
pub fn string_width(self: *const Self, str: []const u8, spacing: i8, text_scale: u8) i16 {
    if (str.len == 0) return 0;
    std.debug.assert(text_scale > 0);
    const s: i32 = text_scale;
    var total: i32 = 0;
    for (str) |byte| {
        total += @as(i32, self.glyph_widths[byte]) * s;
    }
    const gaps: i32 = @intCast(str.len - 1);
    total += gaps * (@as(i32, DEFAULT_SPACING) + @as(i32, spacing)) * s;
    return @intCast(@min(total, std.math.maxInt(i16)));
}

/// Creates a standalone mesh for a rendered string in normalized [-1,1] space.
/// The caller owns the returned mesh and must call `mesh.deinit()` when done.
/// Draw with `mesh.draw(&model_matrix)` after binding a compatible pipeline and
/// the font texture.
pub fn build_mesh(
    self: *const Self,
    str: []const u8,
    color: Color,
    shadow_color: Color,
    spacing: i8,
    text_scale: u8,
) !BatchMesh {
    std.debug.assert(str.len > 0);
    std.debug.assert(text_scale > 0);
    var mesh = try BatchMesh.new(self.allocator, self.pipeline_handle);
    errdefer mesh.deinit(self.allocator);

    const has_shadow = shadow_color.a > 0;
    const n_chars: u32 = @intCast(str.len);
    const mult: u32 = if (has_shadow) 2 else 1;
    try mesh.vertices.ensureTotalCapacity(
        self.allocator,
        @as(usize, n_chars * VERTS_PER_CHAR * mult),
    );

    const s: i32 = text_scale;
    const text_w: i32 = self.string_width(str, spacing, text_scale);
    const text_h: i32 = @as(i32, GLYPH_SIZE) * s;
    std.debug.assert(text_w > 0);

    // Extend extent to include shadow so all vertices stay within [-1,1].
    const pad: i32 = if (has_shadow) s else 0;
    const ext_w = text_w + pad;
    const ext_h = text_h + pad;

    if (has_shadow) {
        emit_string_local(self, &mesh, str, spacing, s, s, 32766, @bitCast(shadow_color), ext_w, ext_h, text_scale);
    }
    emit_string_local(self, &mesh, str, spacing, 0, 0, 32765, @bitCast(color), ext_w, ext_h, text_scale);

    mesh.update();
    return mesh;
}

/// Computes a model matrix that positions and scales an exported mesh using
/// the same logical-pixel coordinate system and anchoring as batched text.
/// Applies R * S * T order (rotate in unit space, then aspect-correct scale,
/// then translate) so non-uniform aspect scaling does not shear the rotation.
pub fn mesh_matrix(
    self: *const Self,
    str: []const u8,
    spacing: i8,
    text_scale: u8,
    pos_x: i16,
    pos_y: i16,
    reference: Anchor,
    origin: Anchor,
    rot_z: f32,
    extra_scale: f32,
    layer: u8,
) Math.Mat4 {
    const screen_w = Rendering.gfx.surface.get_width();
    const screen_h = Rendering.gfx.surface.get_height();
    const ui_scale = Scaling.compute(screen_w, screen_h);
    const sw: f32 = @floatFromInt(screen_w);
    const sh: f32 = @floatFromInt(screen_h);
    const us: f32 = @floatFromInt(ui_scale);

    const ts: i16 = text_scale;
    const tw_i = self.string_width(str, spacing, text_scale);
    const th_i: i16 = @as(i16, GLYPH_SIZE) * ts;
    const max_lx: i16 = @intCast(screen_w / ui_scale);
    const max_ly: i16 = @intCast(screen_h / ui_scale);

    const ref = anchor_point(reference, max_lx, max_ly);
    const orig = anchor_point(origin, tw_i, th_i);
    const tw: f32 = @floatFromInt(tw_i);
    const th: f32 = @floatFromInt(th_i);
    const tl_x: i16 = ref.x + pos_x - orig.x;
    const tl_y: i16 = ref.y + pos_y - orig.y;
    const cx: f32 = @as(f32, @floatFromInt(tl_x)) + tw / 2.0;
    const cy: f32 = @as(f32, @floatFromInt(tl_y)) + th / 2.0;

    // S_pixel: scale mesh from [-1,1] to pixel proportions for correct rotation.
    const s_pixel = Math.Mat4.scaling(tw / 2.0, th / 2.0, 1);
    // R: rotate in pixel space (uniform, no distortion).
    const r = Math.Mat4.rotationZ(std.math.degreesToRadians(rot_z));
    // S_ndc: convert pixel space to NDC, apply extra scale.
    const s_ndc = Math.Mat4.scaling(2.0 * us * extra_scale / sw, 2.0 * us * extra_scale / sh, 1);
    // T: translate to final NDC position with layer depth.
    // The mesh vertices are at layer 0 (z = 32765..32766 SNORM). Shift to target layer.
    const z: f32 = -@as(f32, @floatFromInt(layer)) * 2.0 / 32767.0;
    const t = Math.Mat4.translation(2.0 * cx * us / sw - 1.0, 1.0 - 2.0 * cy * us / sh, z);
    return s_pixel.mul(r).mul(s_ndc).mul(t);
}

// --- Private ---

fn entries_equal(a: []const TextEntry, b: []const TextEntry) bool {
    if (a.len != b.len) return false;
    for (a, b) |*x, *y| {
        if (!std.meta.eql(x.*, y.*)) return false;
    }
    return true;
}

fn rebuild(self: *Self, screen_w: u32, screen_h: u32) !void {
    const scale = Scaling.compute(screen_w, screen_h);
    const entries = self.entries[self.current][0..self.count];

    var total_verts: u32 = 0;
    for (entries) |*e| {
        const mult: u32 = if (e.shadow_color.a > 0) 2 else 1;
        total_verts += @as(u32, @intCast(e.str.len)) * VERTS_PER_CHAR * mult;
    }

    self.mesh.vertices.clearRetainingCapacity();
    try self.mesh.vertices.ensureTotalCapacity(self.allocator, @as(usize, total_verts));

    for (entries) |*e| {
        emit_text(self, &self.mesh, e, screen_w, screen_h, scale);
    }
    self.mesh.update();
}

fn emit_text(
    self: *const Self,
    mesh: *BatchMesh,
    entry: *const TextEntry,
    screen_w: u32,
    screen_h: u32,
    ui_scale: u32,
) void {
    std.debug.assert(entry.scale > 0);
    const str = entry.str;
    const ts: i16 = entry.scale;
    const text_w = self.string_width(str, entry.spacing, entry.scale);
    const text_h: i16 = @as(i16, GLYPH_SIZE) * ts;

    const max_lx: i16 = @intCast(screen_w / ui_scale);
    const max_ly: i16 = @intCast(screen_h / ui_scale);

    const ref = anchor_point(entry.reference, max_lx, max_ly);
    const orig = anchor_point(entry.origin, text_w, text_h);
    const base_x: i16 = ref.x + entry.pos_x - orig.x;
    const base_y: i16 = ref.y + entry.pos_y - orig.y;

    // Two z-levels per layer: shadow behind, text in front.
    const shadow_z: i16 = 32766 - @as(i16, entry.layer) * 2;
    const text_z: i16 = shadow_z - 1;

    if (entry.shadow_color.a > 0) {
        emit_string_screen(self, mesh, str, entry.spacing, @as(i32, base_x) + ts, @as(i32, base_y) + ts, shadow_z, @bitCast(entry.shadow_color), screen_w, screen_h, ui_scale, entry.scale);
    }
    emit_string_screen(self, mesh, str, entry.spacing, @as(i32, base_x), @as(i32, base_y), text_z, @bitCast(entry.color), screen_w, screen_h, ui_scale, entry.scale);
}

fn emit_string_screen(
    self: *const Self,
    mesh: *BatchMesh,
    str: []const u8,
    spacing: i8,
    start_x: i32,
    start_y: i32,
    z: i16,
    color: u32,
    screen_w: u32,
    screen_h: u32,
    ui_scale: u32,
    text_scale: u8,
) void {
    const max_lx: i16 = @intCast(screen_w / ui_scale);
    const max_ly: i16 = @intCast(screen_h / ui_scale);
    const ts: i32 = text_scale;

    // Y bounds are constant across all characters - hoist out of loop.
    const y0: i16 = @intCast(@min(@max(start_y, 0), @as(i32, max_ly)));
    const y1: i16 = @intCast(@min(start_y + @as(i32, GLYPH_SIZE) * ts, @as(i32, max_ly)));
    if (y0 >= y1) return;
    const sy0 = logical_to_snorm_y(y0, screen_h, ui_scale);
    const sy1 = logical_to_snorm_y(y1, screen_h, ui_scale);
    const advance: i32 = (@as(i32, DEFAULT_SPACING) + @as(i32, spacing)) * ts;
    var cursor: i32 = start_x;

    for (str) |byte| {
        if (cursor >= @as(i32, max_lx)) break;
        const gw = self.glyph_widths[byte];
        if (gw == 0) {
            cursor += advance;
            continue;
        }
        const scaled_w: i32 = @as(i32, gw) * ts;
        const x0: i16 = @intCast(@max(cursor, 0));
        const x1: i16 = @intCast(@min(cursor + scaled_w, @as(i32, max_lx)));
        if (x0 < x1) {
            const base = glyph_uvs(self, byte, gw);
            // Adjust UVs for horizontal clipping so partially-visible glyphs
            // sample the correct texel region.
            const uv_span: i32 = @as(i32, base[2]) - @as(i32, base[0]);
            const vis_l: i32 = @as(i32, x0) - cursor;
            const vis_r: i32 = @as(i32, x1) - cursor;
            const uv_l: i16 = @intCast(@as(i32, base[0]) + @divTrunc(uv_span * vis_l, scaled_w));
            const uv_r: i16 = @intCast(@as(i32, base[0]) + @divTrunc(uv_span * vis_r, scaled_w));
            emit_quad(mesh, logical_to_snorm_x(x0, screen_w, ui_scale), sy0, logical_to_snorm_x(x1, screen_w, ui_scale), sy1, z, uv_l, base[1], uv_r, base[3], color);
        }
        cursor += scaled_w + advance;
    }
}

fn emit_string_local(
    self: *const Self,
    mesh: *BatchMesh,
    str: []const u8,
    spacing: i8,
    offset_x: i32,
    offset_y: i32,
    z: i16,
    color: u32,
    extent_w: i32,
    extent_h: i32,
    text_scale: u8,
) void {
    const ts: i32 = text_scale;
    const advance: i32 = (@as(i32, DEFAULT_SPACING) + @as(i32, spacing)) * ts;
    const sy0 = local_to_snorm_y(offset_y, extent_h);
    const sy1 = local_to_snorm_y(offset_y + @as(i32, GLYPH_SIZE) * ts, extent_h);
    var cursor: i32 = offset_x;

    for (str) |byte| {
        const gw = self.glyph_widths[byte];
        if (gw == 0) {
            cursor += advance;
            continue;
        }
        const scaled_w: i32 = @as(i32, gw) * ts;
        const base = glyph_uvs(self, byte, gw);
        const sx0 = local_to_snorm_x(cursor, extent_w);
        const sx1 = local_to_snorm_x(cursor + scaled_w, extent_w);
        emit_quad(mesh, sx0, sy0, sx1, sy1, z, base[0], base[1], base[2], base[3], color);
        cursor += scaled_w + advance;
    }
}

fn glyph_uvs(self: *const Self, byte: u8, gw: u8) [4]i16 {
    const gx: u32 = @as(u32, byte) % GLYPH_COLS;
    const gy: u32 = @as(u32, byte) / GLYPH_COLS;
    const stride_u: i32 = @as(i32, 32767) >> self.atlas.col_log2;
    const stride_v: i32 = @as(i32, 32767) >> self.atlas.row_log2;
    const base_u: i32 = @as(i32, @intCast(gx)) * stride_u;
    const base_v: i32 = @as(i32, @intCast(gy)) * stride_v;
    return .{
        @intCast(base_u),
        @intCast(base_v),
        @intCast(base_u + @divTrunc(stride_u * @as(i32, gw), GLYPH_SIZE)),
        @intCast(base_v + stride_v),
    };
}

fn emit_quad(
    mesh: *BatchMesh,
    sx0: i16,
    sy0: i16,
    sx1: i16,
    sy1: i16,
    z: i16,
    uv_l: i16,
    uv_t: i16,
    uv_r: i16,
    uv_b: i16,
    color: u32,
) void {
    mesh.vertices.appendSliceAssumeCapacity(&.{
        Vertex{ .pos = .{ sx0, sy0, z }, .uv = .{ uv_l, uv_t }, .color = color },
        Vertex{ .pos = .{ sx1, sy1, z }, .uv = .{ uv_r, uv_b }, .color = color },
        Vertex{ .pos = .{ sx1, sy0, z }, .uv = .{ uv_r, uv_t }, .color = color },
        Vertex{ .pos = .{ sx0, sy0, z }, .uv = .{ uv_l, uv_t }, .color = color },
        Vertex{ .pos = .{ sx0, sy1, z }, .uv = .{ uv_l, uv_b }, .color = color },
        Vertex{ .pos = .{ sx1, sy1, z }, .uv = .{ uv_r, uv_b }, .color = color },
    });
}

/// Scans each glyph tile in the font texture to find the rightmost column
/// containing a non-transparent pixel. This gives per-character variable widths.
fn compute_glyph_widths(texture: *const Rendering.Texture) [GLYPH_COUNT]u8 {
    std.debug.assert(texture.width == 128);
    std.debug.assert(texture.height == 128);

    var widths: [GLYPH_COUNT]u8 = [1]u8{0} ** GLYPH_COUNT;

    var code: u32 = 0;
    while (code < GLYPH_COUNT) : (code += 1) {
        if (code == 0x20) {
            widths[code] = SPACE_WIDTH;
            continue;
        }
        const gx = code % GLYPH_COLS;
        const gy = code / GLYPH_COLS;
        const bx = gx * GLYPH_SIZE;
        const by = gy * GLYPH_SIZE;

        // Scan columns right-to-left; first non-transparent pixel sets width.
        var max_col: u8 = 0;
        var col: u32 = GLYPH_SIZE;
        while (col > 0) {
            col -= 1;
            var row: u32 = 0;
            while (row < GLYPH_SIZE) : (row += 1) {
                const rgba = texture.get_pixel(bx + col, by + row);
                if (rgba[3] > 0) {
                    max_col = @intCast(col + 1);
                    break;
                }
            }
            if (max_col > 0) break;
        }
        widths[code] = max_col;
    }
    return widths;
}

const anchor_point = layout.anchor_point;
const logical_to_snorm_x = layout.logical_to_snorm_x;
const logical_to_snorm_y = layout.logical_to_snorm_y;

/// Maps [0, extent] to [-32767, 32767] for normalized mesh export.
fn local_to_snorm_x(x: i32, extent_w: i32) i16 {
    return @intCast(@divTrunc((2 * x - extent_w) * 32767, extent_w));
}

/// Maps [0, extent] to [32767, -32767] (Y-flipped for top-left origin).
fn local_to_snorm_y(y: i32, extent_h: i32) i16 {
    return @intCast(@divTrunc((extent_h - 2 * y) * 32767, extent_h));
}
