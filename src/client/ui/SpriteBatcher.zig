const std = @import("std");
const ae = @import("aether");
const Math = ae.Math;
const Util = ae.Util;
const Rendering = ae.Rendering;

const vertex = @import("../vertex.zig");
pub const Vertex = vertex.Vertex;
pub const BatchMesh = Rendering.Mesh(Vertex);

const Self = @This();

pub const Sprite = extern struct {
    pub const Range = extern struct { x: i16, y: i16 };

    texture: *const Rendering.Texture,
    pos_offset: Range,
    pos_extent: Range,
    tex_offset: Range,
    tex_extent: Range,
    color: Color,
    layer: u8,
    _pad: [3]u8 = .{ 0, 0, 0 },

    pub const Color = packed struct(u32) {
        r: u8,
        g: u8,
        b: u8,
        a: u8,

        pub fn rgba(r: u8, g: u8, b: u8, a: u8) Color {
            return .{ .r = r, .g = g, .b = b, .a = a };
        }

        pub fn white() Color {
            return rgba(255, 255, 255, 255);
        }
    };
};

const TextureBatch = struct {
    texture: *const Rendering.Texture,
    mesh: BatchMesh,
};

const MAX_SPRITES: u16 = if (ae.platform == .psp) 256 else 1024;
const VERTS_PER_SPRITE: u16 = 6;

sprites_a: [MAX_SPRITES]Sprite,
sprites_b: [MAX_SPRITES]Sprite,
count: u16,
prev_count: u16,
current_is_a: bool,
batches: std.ArrayList(TextureBatch),
pipeline_handle: Rendering.Pipeline.Handle,

comptime {
    std.debug.assert(@sizeOf(Sprite.Color) == 4);
}

pub fn init(pipeline: Rendering.Pipeline.Handle) !Self {
    return Self{
        .sprites_a = undefined,
        .sprites_b = undefined,
        .count = 0,
        .prev_count = 0,
        .current_is_a = true,
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
    self.current_buf()[self.count] = sprite.*;
    self.count += 1;
}

pub fn clear(self: *Self) void {
    self.prev_count = self.count;
    self.current_is_a = !self.current_is_a;
    self.count = 0;
}

pub fn flush(self: *Self) !void {
    if (self.count == 0) return;

    const curr = std.mem.sliceAsBytes(self.current_buf()[0..self.count]);
    const prev = std.mem.sliceAsBytes(self.previous_buf()[0..self.prev_count]);
    const changed = curr.len != prev.len or !std.mem.eql(u8, curr, prev);

    if (changed) {
        sort_sprites(self.current_buf()[0..self.count]);
        try self.rebuild_batches();
    }

    const w: u32 = Rendering.gfx.surface.get_width();
    const h: u32 = Rendering.gfx.surface.get_height();
    Rendering.gfx.api.set_proj_matrix(&pixel_ortho(w, h));
    Rendering.gfx.api.set_view_matrix(&Math.Mat4.identity());
    Rendering.Pipeline.bind(self.pipeline_handle);

    const ident = Math.Mat4.identity();
    for (self.batches.items) |*batch| {
        batch.texture.bind();
        batch.mesh.draw(&ident);
    }
}

fn rebuild_batches(self: *Self) !void {
    const sprites = self.current_buf()[0..self.count];
    var batch_idx: u16 = 0;
    var i: u16 = 0;

    while (i < self.count) {
        const tex = sprites[i].texture;
        const group_start = i;
        while (i < self.count and sprites[i].texture == tex) : (i += 1) {}
        const group_count: u16 = i - group_start;

        // Reuse existing batch or create a new one
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
            emit_sprite_vertices(&batch.mesh, &sprite);
        }

        batch.mesh.update();
        batch_idx += 1;
    }

    // Destroy excess batches from previous frames
    while (self.batches.items.len > batch_idx) {
        var old = self.batches.pop().?;
        old.mesh.deinit();
    }
}

fn emit_sprite_vertices(mesh: *BatchMesh, sprite: *const Sprite) void {
    const x0 = sprite.pos_offset.x;
    const y0 = sprite.pos_offset.y;
    const x1 = x0 + sprite.pos_extent.x;
    const y1 = y0 + sprite.pos_extent.y;

    const uv_l = texel_to_snorm(sprite.tex_offset.x, sprite.texture.width);
    const uv_t = texel_to_snorm(sprite.tex_offset.y, sprite.texture.height);
    const uv_r = texel_to_snorm(sprite.tex_offset.x + sprite.tex_extent.x, sprite.texture.width);
    const uv_b = texel_to_snorm(sprite.tex_offset.y + sprite.tex_extent.y, sprite.texture.height);

    const color: u32 = @bitCast(sprite.color);

    mesh.vertices.appendSliceAssumeCapacity(&.{
        Vertex{ .pos = .{ x0, y0, 0 }, .uv = .{ uv_l, uv_t }, .color = color },
        Vertex{ .pos = .{ x1, y1, 0 }, .uv = .{ uv_r, uv_b }, .color = color },
        Vertex{ .pos = .{ x1, y0, 0 }, .uv = .{ uv_r, uv_t }, .color = color },
        Vertex{ .pos = .{ x0, y0, 0 }, .uv = .{ uv_l, uv_t }, .color = color },
        Vertex{ .pos = .{ x0, y1, 0 }, .uv = .{ uv_l, uv_b }, .color = color },
        Vertex{ .pos = .{ x1, y1, 0 }, .uv = .{ uv_r, uv_b }, .color = color },
    });
}

fn texel_to_snorm(texel: i16, dim: u32) i16 {
    return @intCast(@divTrunc(@as(i32, texel) * 32767, @as(i32, @intCast(dim))));
}

fn pixel_ortho(w: u32, h: u32) Math.Mat4 {
    const fw: f32 = @floatFromInt(w);
    const fh: f32 = @floatFromInt(h);
    const s: f32 = 32767.0;
    return .{ .data = .{
        .{ 2.0 * s / fw, 0,              0,  0 },
        .{ 0,            -2.0 * s / fh,  0,  0 },
        .{ 0,            0,             -1,  0 },
        .{ -1,           1,              0,  1 },
    } };
}

/// Sorts by texture pointer (for batching), then by layer within each texture.
fn sort_sprites(sprites: []Sprite) void {
    var i: u16 = 1;
    while (i < @as(u16, @intCast(sprites.len))) : (i += 1) {
        const key = sprites[i];
        var j: u16 = i;
        while (j > 0 and order_greater(&sprites[j - 1], &key)) : (j -= 1) {
            sprites[j] = sprites[j - 1];
        }
        sprites[j] = key;
    }
}

fn order_greater(a: *const Sprite, b: *const Sprite) bool {
    const ta = @intFromPtr(a.texture);
    const tb = @intFromPtr(b.texture);
    if (ta != tb) return ta > tb;
    return a.layer > b.layer;
}

fn current_buf(self: *Self) *[MAX_SPRITES]Sprite {
    return if (self.current_is_a) &self.sprites_a else &self.sprites_b;
}

fn previous_buf(self: *Self) *[MAX_SPRITES]Sprite {
    return if (self.current_is_a) &self.sprites_b else &self.sprites_a;
}
