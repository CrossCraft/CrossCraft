const std = @import("std");
const ae = @import("aether");
const Math = ae.Math;
const Util = ae.Util;
const Rendering = ae.Rendering;

const Scaling = @import("Scaling.zig");

pub const Color = @import("../Color.zig").Color;
pub const Vertex = @import("../Vertex.zig").Vertex;
pub const BatchMesh = Rendering.Mesh(Vertex);

const Self = @This();

pub const Anchor = enum(u8) {
    top_left,
    top_center,
    top_right,
    middle_left,
    middle_center,
    middle_right,
    bottom_left,
    bottom_center,
    bottom_right,
};

pub const Sprite = extern struct {
    pub const Range = extern struct { x: i16, y: i16 };

    texture: *const Rendering.Texture,
    pos_offset: Range,
    pos_extent: Range,
    tex_offset: Range,
    tex_extent: Range,
    color: Color,
    layer: u8,
    reference: Anchor = .top_left,
    origin: Anchor = .top_left,
    _pad: u8 = 0,
};

const TextureBatch = struct {
    texture: *const Rendering.Texture,
    mesh: BatchMesh,
};

const MAX_SPRITES: u16 = if (ae.platform == .psp) 256 else 1024;
const VERTS_PER_SPRITE: u16 = 6;

sprites: [2][MAX_SPRITES]Sprite,
count: u16,
prev_count: u16,
current: u1,
last_screen_w: u32,
last_screen_h: u32,
batches: std.ArrayList(TextureBatch),
pipeline_handle: Rendering.Pipeline.Handle,

pub fn init(pipeline: Rendering.Pipeline.Handle) !Self {
    return Self{
        .sprites = undefined,
        .count = 0,
        .prev_count = 0,
        .current = 0,
        .last_screen_w = 0,
        .last_screen_h = 0,
        .batches = try std.ArrayList(TextureBatch).initCapacity(Util.allocator(.render), 4),
        .pipeline_handle = pipeline,
    };
}

pub fn deinit(self: *Self) void {
    for (self.batches.items) |*batch| {
        batch.mesh.deinit();
    }
    self.batches.deinit(Util.allocator(.render));
}

pub fn add_sprite(self: *Self, sprite: *const Sprite) void {
    std.debug.assert(self.count < MAX_SPRITES);
    self.sprites[self.current][self.count] = sprite.*;
    self.count += 1;
}

pub fn clear(self: *Self) void {
    self.prev_count = self.count;
    self.current ^= 1;
    self.count = 0;
}

pub fn flush(self: *Self) !void {
    if (self.count == 0) return;

    const screen_w = Rendering.gfx.surface.get_width();
    const screen_h = Rendering.gfx.surface.get_height();

    const curr = std.mem.sliceAsBytes(self.sprites[self.current][0..self.count]);
    const prev = std.mem.sliceAsBytes(self.sprites[self.current ^ 1][0..self.prev_count]);
    const sprites_changed = curr.len != prev.len or !std.mem.eql(u8, curr, prev);
    const size_changed = screen_w != self.last_screen_w or screen_h != self.last_screen_h;

    if (sprites_changed or size_changed) {
        sort_sprites(self.sprites[self.current][0..self.count]);
        try self.rebuild_batches(screen_w, screen_h);
        self.last_screen_w = screen_w;
        self.last_screen_h = screen_h;
    }

    Rendering.gfx.api.set_proj_matrix(&Math.Mat4.identity());
    Rendering.gfx.api.set_view_matrix(&Math.Mat4.identity());
    Rendering.Pipeline.bind(self.pipeline_handle);

    const ident = Math.Mat4.identity();
    for (self.batches.items) |*batch| {
        batch.texture.bind();
        batch.mesh.draw(&ident);
    }
}

fn rebuild_batches(self: *Self, screen_w: u32, screen_h: u32) !void {
    const sprites = self.sprites[self.current][0..self.count];
    const scale = Scaling.compute(screen_w, screen_h);
    var batch_idx: u16 = 0;
    var i: u16 = 0;

    while (i < self.count) {
        const tex = sprites[i].texture;
        const group_start = i;
        while (i < self.count and sprites[i].texture == tex) : (i += 1) {}
        const group_count: u16 = i - group_start;

        if (batch_idx >= self.batches.items.len) {
            const mesh = try BatchMesh.new(self.pipeline_handle);
            try self.batches.append(Util.allocator(.render), .{ .texture = tex, .mesh = mesh });
        }

        var batch = &self.batches.items[batch_idx];
        batch.texture = tex;
        batch.mesh.vertices.clearRetainingCapacity();
        try batch.mesh.vertices.ensureTotalCapacity(
            Util.allocator(.render),
            @as(usize, group_count) * VERTS_PER_SPRITE,
        );

        for (sprites[group_start..i]) |sprite| {
            emit_sprite_vertices(&batch.mesh, &sprite, screen_w, screen_h, scale);
        }

        batch.mesh.update();
        batch_idx += 1;
    }

    while (self.batches.items.len > batch_idx) {
        var old = self.batches.pop().?;
        old.mesh.deinit();
    }
}

fn emit_sprite_vertices(mesh: *BatchMesh, sprite: *const Sprite, screen_w: u32, screen_h: u32, scale: u32) void {
    // Clip to screen bounds in logical pixels so snorm stays in i16 range.
    const max_lx: i16 = @intCast(screen_w / scale);
    const max_ly: i16 = @intCast(screen_h / scale);

    const ref = anchor_point(sprite.reference, max_lx, max_ly);
    const orig = anchor_point(sprite.origin, sprite.pos_extent.x, sprite.pos_extent.y);
    const raw_x0: i16 = ref.x + sprite.pos_offset.x - orig.x;
    const raw_y0: i16 = ref.y + sprite.pos_offset.y - orig.y;
    // Clip all four edges to [0, max_l*] so snorm conversion stays in i16 range.
    // Sprites partially or fully outside the viewport are trimmed correctly.
    const x0: i16 = @max(raw_x0, 0);
    const y0: i16 = @max(raw_y0, 0);
    const x1: i16 = @intCast(@min(@as(i32, raw_x0) + @as(i32, sprite.pos_extent.x), @as(i32, max_lx)));
    const y1: i16 = @intCast(@min(@as(i32, raw_y0) + @as(i32, sprite.pos_extent.y), @as(i32, max_ly)));

    if (x0 >= x1 or y0 >= y1) return;

    const sx0 = logical_to_snorm_x(x0, screen_w, scale);
    const sy0 = logical_to_snorm_y(y0, screen_h, scale);
    const sx1 = logical_to_snorm_x(x1, screen_w, scale);
    const sy1 = logical_to_snorm_y(y1, screen_h, scale);
    // Layer 0 maps to z just below the far plane (1.0); each higher layer gets a
    // smaller z so it passes GL_LESS after the previous layer has written its z.
    const z: i16 = 32766 - @as(i16, sprite.layer);

    // All four UV edges use raw_x0/raw_y0 as the unclipped origin so left/top
    // clipping maps into the correct texel region, matching the right/bottom logic.
    const irx: i32 = raw_x0;
    const iry: i32 = raw_y0;
    const iw: i32 = sprite.pos_extent.x;
    const ih: i32 = sprite.pos_extent.y;
    const uv_l = texel_to_snorm(@as(i32, sprite.tex_offset.x) + @divTrunc(@as(i32, sprite.tex_extent.x) * (@as(i32, x0) - irx), iw), sprite.texture.width);
    const uv_t = texel_to_snorm(@as(i32, sprite.tex_offset.y) + @divTrunc(@as(i32, sprite.tex_extent.y) * (@as(i32, y0) - iry), ih), sprite.texture.height);
    const uv_r = texel_to_snorm(@as(i32, sprite.tex_offset.x) + @divTrunc(@as(i32, sprite.tex_extent.x) * (@as(i32, x1) - irx), iw), sprite.texture.width);
    const uv_b = texel_to_snorm(@as(i32, sprite.tex_offset.y) + @divTrunc(@as(i32, sprite.tex_extent.y) * (@as(i32, y1) - iry), ih), sprite.texture.height);

    const color: u32 = @bitCast(sprite.color);

    mesh.vertices.appendSliceAssumeCapacity(&.{
        Vertex{ .pos = .{ sx0, sy0, z }, .uv = .{ uv_l, uv_t }, .color = color },
        Vertex{ .pos = .{ sx1, sy1, z }, .uv = .{ uv_r, uv_b }, .color = color },
        Vertex{ .pos = .{ sx1, sy0, z }, .uv = .{ uv_r, uv_t }, .color = color },
        Vertex{ .pos = .{ sx0, sy0, z }, .uv = .{ uv_l, uv_t }, .color = color },
        Vertex{ .pos = .{ sx0, sy1, z }, .uv = .{ uv_l, uv_b }, .color = color },
        Vertex{ .pos = .{ sx1, sy1, z }, .uv = .{ uv_r, uv_b }, .color = color },
    });
}

fn anchor_point(anchor: Anchor, ex: i16, ey: i16) Sprite.Range {
    return switch (anchor) {
        .top_left => .{ .x = 0, .y = 0 },
        .top_center => .{ .x = @divTrunc(ex, 2), .y = 0 },
        .top_right => .{ .x = ex, .y = 0 },
        .middle_left => .{ .x = 0, .y = @divTrunc(ey, 2) },
        .middle_center => .{ .x = @divTrunc(ex, 2), .y = @divTrunc(ey, 2) },
        .middle_right => .{ .x = ex, .y = @divTrunc(ey, 2) },
        .bottom_left => .{ .x = 0, .y = ey },
        .bottom_center => .{ .x = @divTrunc(ex, 2), .y = ey },
        .bottom_right => .{ .x = ex, .y = ey },
    };
}

/// Converts a logical X pixel to snorm NDC.
/// Origin (0,0) is the top-left corner of the window.
fn logical_to_snorm_x(x: i16, screen_w: u32, scale: u32) i16 {
    const s: i32 = @intCast(scale);
    const sw: i32 = @intCast(screen_w);
    return @intCast(@divTrunc((2 * @as(i32, x) * s - sw) * 32767, sw));
}

/// Converts a logical Y pixel to snorm NDC (Y-flipped for top-left origin).
/// Origin (0,0) is the top-left corner of the window.
fn logical_to_snorm_y(y: i16, screen_h: u32, scale: u32) i16 {
    const s: i32 = @intCast(scale);
    const sh: i32 = @intCast(screen_h);
    return @intCast(@divTrunc((sh - 2 * @as(i32, y) * s) * 32767, sh));
}

fn texel_to_snorm(texel: i32, dim: u32) i16 {
    return @intCast(@divTrunc(texel * 32767, @as(i32, @intCast(dim))));
}

/// Sorts by layer (primary) then texture pointer (secondary) for correct draw
/// order and texture batching.
fn sort_sprites(sprites: []Sprite) void {
    var i: u16 = 1;
    while (i < @as(u16, @intCast(sprites.len))) : (i += 1) {
        const key = sprites[i];
        var j: u16 = i;
        while (j > 0 and sprite_before(&key, &sprites[j - 1])) : (j -= 1) {
            sprites[j] = sprites[j - 1];
        }
        sprites[j] = key;
    }
}

fn sprite_before(a: *const Sprite, b: *const Sprite) bool {
    if (a.layer != b.layer) return a.layer < b.layer;
    return @intFromPtr(a.texture) < @intFromPtr(b.texture);
}
