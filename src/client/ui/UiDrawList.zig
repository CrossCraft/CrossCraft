//! Per-screen UI command buffer. Widgets emit typed commands; `flush_into`
//! replays them in order, lowering each into the SpriteBatcher / FontBatcher
//! / IsoBlockDrawer. The buffer is a value type built fresh per draw.

const std = @import("std");
const ae = @import("aether");
const Rendering = ae.Rendering;

const consts = @import("common").consts;

const SpriteBatcher = @import("SpriteBatcher.zig");
const FontBatcher = @import("FontBatcher.zig");
const IsoBlockDrawer = @import("IsoBlockDrawer.zig");
const layout = @import("layout.zig");

pub const Color = @import("../graphics/Color.zig").Color;
pub const Anchor = layout.Anchor;
pub const Point = layout.Point;

const Self = @This();

// --- Command types ---

pub const SpriteCmd = SpriteBatcher.Sprite;
pub const ElidedSpriteCmd = SpriteBatcher.ElidedSprite;
pub const TextCmd = FontBatcher.TextEntry;

pub const RectCmd = struct {
    pos_offset: Point,
    pos_extent: Point,
    color: Color,
    layer: u8,
    reference: Anchor = .top_left,
    origin: Anchor = .top_left,
};

pub const IsoBlockCmd = struct {
    block: consts.Block,
    cx: f32,
    cy: f32,
    half_extent_px: f32,
};

pub const DrawCmd = union(enum) {
    sprite: SpriteCmd,
    elided_sprite: ElidedSpriteCmd,
    rect: RectCmd,
    text: TextCmd,
    iso_block: IsoBlockCmd,
    clip_push: layout.LogicalRect,
    clip_pop: void,
};

// --- Capacity ---

pub const MAX_CMDS: u16 = if (ae.platform == .psp) 96 else 192;

// --- Fields ---

cmds: [MAX_CMDS]DrawCmd = undefined,
count: u16 = 0,

// --- Producers ---

pub fn add_sprite(self: *Self, cmd: *const SpriteCmd) void {
    std.debug.assert(self.count < MAX_CMDS);
    self.cmds[self.count] = .{ .sprite = cmd.* };
    self.count += 1;
}

pub fn add_sprite_elided(self: *Self, cmd: *const ElidedSpriteCmd) void {
    std.debug.assert(self.count < MAX_CMDS);
    self.cmds[self.count] = .{ .elided_sprite = cmd.* };
    self.count += 1;
}

pub fn add_rect(self: *Self, cmd: *const RectCmd) void {
    std.debug.assert(self.count < MAX_CMDS);
    self.cmds[self.count] = .{ .rect = cmd.* };
    self.count += 1;
}

pub fn add_text(self: *Self, cmd: *const TextCmd) void {
    std.debug.assert(self.count < MAX_CMDS);
    self.cmds[self.count] = .{ .text = cmd.* };
    self.count += 1;
}

pub fn add_iso_block(self: *Self, cmd: *const IsoBlockCmd) void {
    std.debug.assert(self.count < MAX_CMDS);
    self.cmds[self.count] = .{ .iso_block = cmd.* };
    self.count += 1;
}

pub fn push_clip(self: *Self, rect: layout.LogicalRect) void {
    std.debug.assert(self.count < MAX_CMDS);
    self.cmds[self.count] = .{ .clip_push = rect };
    self.count += 1;
}

pub fn pop_clip(self: *Self) void {
    std.debug.assert(self.count < MAX_CMDS);
    self.cmds[self.count] = .{ .clip_pop = {} };
    self.count += 1;
}

pub fn offset_range(self: *Self, start: u16, end: u16, dx: i16, dy: i16) void {
    std.debug.assert(start <= end);
    std.debug.assert(end <= self.count);
    if (dx == 0 and dy == 0) return;

    var i: u16 = start;
    while (i < end) : (i += 1) {
        switch (self.cmds[i]) {
            .sprite => |*s| {
                s.pos_offset.x += dx;
                s.pos_offset.y += dy;
            },
            .elided_sprite => |*s| {
                s.pos_offset.x += dx;
                s.pos_offset.y += dy;
            },
            .rect => |*r| {
                r.pos_offset.x += dx;
                r.pos_offset.y += dy;
            },
            .text => |*t| {
                t.pos_x += dx;
                t.pos_y += dy;
            },
            .iso_block => |*b| {
                b.cx += @floatFromInt(dx);
                b.cy += @floatFromInt(dy);
            },
            .clip_push => |*r| {
                r.x0 += dx;
                r.x1 += dx;
                r.y0 += dy;
                r.y1 += dy;
            },
            .clip_pop => {},
        }
    }
}

// --- Backend adapter ---

/// `iso` is optional: screens that never emit `iso_block` commands (menus,
/// pause) pass null. Lists carrying an `iso_block` require it.
pub fn flush_into(
    self: *const Self,
    sprites: *SpriteBatcher,
    fonts: *FontBatcher,
    iso: ?*IsoBlockDrawer,
) void {
    var stack: [MAX_CLIP_DEPTH]layout.LogicalRect = undefined;
    var depth: u8 = 0;

    var i: u16 = 0;
    while (i < self.count) : (i += 1) {
        switch (self.cmds[i]) {
            .clip_push => |r| {
                std.debug.assert(depth < MAX_CLIP_DEPTH);
                stack[depth] = if (depth == 0) r else intersect(stack[depth - 1], r);
                depth += 1;
            },
            .clip_pop => {
                std.debug.assert(depth > 0);
                depth -= 1;
            },
            .sprite => |*s| {
                if (clip_sprite(s.*, active_clip(stack[0..], depth))) |out| {
                    sprites.add_sprite(&out);
                }
            },
            .elided_sprite => |*s| flush_elided(sprites, s, active_clip(stack[0..], depth)),
            .rect => |*r| {
                const lowered = lower_rect(r);
                if (clip_sprite(lowered, active_clip(stack[0..], depth))) |out| {
                    sprites.add_sprite(&out);
                }
            },
            .text => |*t| {
                if (text_inside(t, active_clip(stack[0..], depth))) {
                    fonts.add_text(t);
                }
            },
            // Iso blocks bypass CPU clipping; the iso drawer flushes as
            // its own pass, with no Z interaction with sprite/text.
            .iso_block => |*b| {
                const drawer = iso.?;
                drawer.add_block(b.block, b.cx, b.cy, b.half_extent_px);
            },
        }
    }
    std.debug.assert(depth == 0);
}

const MAX_CLIP_DEPTH: u8 = 4;

fn active_clip(stack: []const layout.LogicalRect, depth: u8) ?layout.LogicalRect {
    if (depth == 0) return null;
    return stack[depth - 1];
}

fn intersect(a: layout.LogicalRect, b: layout.LogicalRect) layout.LogicalRect {
    return .{
        .x0 = @max(a.x0, b.x0),
        .y0 = @max(a.y0, b.y0),
        .x1 = @min(a.x1, b.x1),
        .y1 = @min(a.y1, b.y1),
    };
}

/// Trim a sprite to the active clip rect, scaling its UV span to match the
/// kept fraction of the destination. Returns null when fully outside.
/// Only top_left/top_left anchored sprites are clipped; others fall through
/// unclipped (no scroll-listed widget emits a different anchor today).
fn clip_sprite(s: SpriteCmd, clip: ?layout.LogicalRect) ?SpriteCmd {
    const c = clip orelse return s;
    if (c.x1 <= c.x0 or c.y1 <= c.y0) return null;
    if (s.reference != .top_left or s.origin != .top_left) return s;

    const x0: i32 = s.pos_offset.x;
    const y0: i32 = s.pos_offset.y;
    const x1: i32 = x0 + s.pos_extent.x;
    const y1: i32 = y0 + s.pos_extent.y;

    const cx0: i32 = c.x0;
    const cy0: i32 = c.y0;
    const cx1: i32 = c.x1;
    const cy1: i32 = c.y1;

    if (x1 <= cx0 or y1 <= cy0 or x0 >= cx1 or y0 >= cy1) return null;

    const nx0: i32 = @max(x0, cx0);
    const ny0: i32 = @max(y0, cy0);
    const nx1: i32 = @min(x1, cx1);
    const ny1: i32 = @min(y1, cy1);

    const orig_w: i32 = s.pos_extent.x;
    const orig_h: i32 = s.pos_extent.y;
    const new_w: i32 = nx1 - nx0;
    const new_h: i32 = ny1 - ny0;
    if (new_w <= 0 or new_h <= 0) return null;
    if (new_w == orig_w and new_h == orig_h) return s;

    const tex_x0: i32 = s.tex_offset.x;
    const tex_y0: i32 = s.tex_offset.y;
    const tex_w: i32 = s.tex_extent.x;
    const tex_h: i32 = s.tex_extent.y;

    const left_trim: i32 = nx0 - x0;
    const top_trim: i32 = ny0 - y0;

    const new_tex_x0: i32 = tex_x0 + @divTrunc(left_trim * tex_w, orig_w);
    const new_tex_y0: i32 = tex_y0 + @divTrunc(top_trim * tex_h, orig_h);
    const new_tex_w: i32 = @divTrunc(new_w * tex_w, orig_w);
    const new_tex_h: i32 = @divTrunc(new_h * tex_h, orig_h);

    var out = s;
    out.pos_offset = .{ .x = @intCast(nx0), .y = @intCast(ny0) };
    out.pos_extent = .{ .x = @intCast(new_w), .y = @intCast(new_h) };
    out.tex_offset = .{ .x = @intCast(new_tex_x0), .y = @intCast(new_tex_y0) };
    out.tex_extent = .{ .x = @intCast(new_tex_w), .y = @intCast(new_tex_h) };
    return out;
}

fn flush_elided(sprites: *SpriteBatcher, e: *const ElidedSpriteCmd, clip: ?layout.LogicalRect) void {
    if (clip == null) {
        sprites.add_sprite_elided(e);
        return;
    }
    const left_w: i16 = @divTrunc(e.dst_w, 2);
    const right_w: i16 = e.dst_w - left_w;
    const src_w: i16 = e.region.w;

    const left_sprite: SpriteCmd = .{
        .texture = e.texture,
        .pos_offset = .{ .x = e.pos_offset.x, .y = e.pos_offset.y },
        .pos_extent = .{ .x = left_w, .y = e.dst_h },
        .tex_offset = .{ .x = e.region.x, .y = e.region.y },
        .tex_extent = .{ .x = left_w, .y = e.region.h },
        .color = e.color,
        .layer = e.layer,
        .reference = .top_left,
        .origin = .top_left,
    };
    const right_sprite: SpriteCmd = .{
        .texture = e.texture,
        .pos_offset = .{ .x = e.pos_offset.x + left_w, .y = e.pos_offset.y },
        .pos_extent = .{ .x = right_w, .y = e.dst_h },
        .tex_offset = .{ .x = e.region.x + (src_w - right_w), .y = e.region.y },
        .tex_extent = .{ .x = right_w, .y = e.region.h },
        .color = e.color,
        .layer = e.layer,
        .reference = .top_left,
        .origin = .top_left,
    };
    if (clip_sprite(left_sprite, clip)) |out| sprites.add_sprite(&out);
    if (clip_sprite(right_sprite, clip)) |out| sprites.add_sprite(&out);
}

/// All-or-nothing text clipping against a conservative bbox; partial-glyph
/// trimming is not needed since row sprites are already clipped above.
fn text_inside(t: *const TextCmd, clip: ?layout.LogicalRect) bool {
    const c = clip orelse return true;

    const text_h: i32 = 8 * @as(i32, t.scale);
    const pad_x: i32 = 256;
    const min_x: i32 = @as(i32, t.pos_x) - pad_x;
    const max_x: i32 = @as(i32, t.pos_x) + pad_x;
    const min_y: i32 = @as(i32, t.pos_y) - text_h;
    const max_y: i32 = @as(i32, t.pos_y) + text_h * 2;

    return min_x < c.x1 and max_x > c.x0 and min_y < c.y1 and max_y > c.y0;
}

fn lower_rect(r: *const RectCmd) SpriteCmd {
    return .{
        .texture = &Rendering.Texture.Default,
        .pos_offset = .{ .x = r.pos_offset.x, .y = r.pos_offset.y },
        .pos_extent = .{ .x = r.pos_extent.x, .y = r.pos_extent.y },
        .tex_offset = .{ .x = 0, .y = 0 },
        .tex_extent = .{ .x = 1, .y = 1 },
        .color = r.color,
        .layer = r.layer,
        .reference = r.reference,
        .origin = r.origin,
    };
}
