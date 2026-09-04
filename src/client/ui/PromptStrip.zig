//! Controller and keyboard prompt-strip layout.

const std = @import("std");
const assert = std.debug.assert;
const ae = @import("aether");
const Rendering = ae.Rendering;

const Buttons = @import("Buttons.zig");
const FontBatcher = ae.UI.FontBatcher;
const UiDrawList = @import("UiDrawList.zig");
const layout = ae.UI.layout;
const Options = @import("../Options.zig");
const Colors = @import("../graphics/Color.zig");

pub const Anchor = layout.Anchor;

pub const Prompt = struct {
    /// One button or a two-button chord, drawn left to right.
    chord: [2]?Buttons.Button,
    label: []const u8,
    /// Optional ASCII string drawn centered on top of the glyph, used by
    /// KB+M BlankKey prompts (e.g. "B" for inventory, "T" for chat).  The
    /// slice must outlive the FontBatcher flush, so pass a string literal.
    letter_overlay: ?[]const u8 = null,
};

comptime {
    // Guard against accidental Prompt bloat -- PSP-friendly budget.
    assert(@sizeOf(Prompt) <= 64);
}

pub fn enabled() bool {
    return Options.current.controller_tooltips != .off;
}

/// Shared bottom-left position, adjusted for the PSP viewport.
pub const DEFAULT_POS_X: i16 = 20;
pub const DEFAULT_POS_Y: i16 = 23 - if (@import("aether").platform == .psp) 8 else 16;

const GLYPH_PAD: i16 = 4;
const ENTRY_PAD: i16 = 12;
const CHORD_PAD: i16 = 2;

/// For bottom anchors, `y_base` is measured inward from the reference edge.
pub fn draw_into(
    list: *UiDrawList,
    glyphs_tex: *const Rendering.Texture,
    fonts: *const FontBatcher,
    prompts: []const Prompt,
    anchor: Anchor,
    pos_x: i16,
    y_base: i16,
    sprite_layer: u8,
    text_layer: u8,
) void {
    if (!enabled() or prompts.len == 0) return;

    const style = Buttons.resolve_style();
    const y_offset = Buttons.glyph_y_offset();

    var cursor_x: i16 = pos_x;
    for (prompts, 0..) |p, i| {
        if (i > 0) cursor_x += ENTRY_PAD;
        draw_one_into(
            list,
            &p,
            style,
            y_offset,
            glyphs_tex,
            fonts,
            anchor,
            &cursor_x,
            y_base,
            sprite_layer,
            text_layer,
        );
    }
}

fn draw_one_into(
    list: *UiDrawList,
    prompt: *const Prompt,
    style: Buttons.Style,
    y_offset: i16,
    glyphs_tex: *const Rendering.Texture,
    fonts: *const FontBatcher,
    anchor: Anchor,
    cursor_x: *i16,
    y_base: i16,
    sprite_layer: u8,
    text_layer: u8,
) void {
    const glyph_y = y_base - y_offset;

    var last_rect: Buttons.Rect = undefined;
    for (prompt.chord, 0..) |maybe_btn, idx| {
        const btn = maybe_btn orelse continue;
        if (idx > 0) cursor_x.* += CHORD_PAD;
        const rect = Buttons.lookup(btn, style);
        last_rect = rect;
        list.add_sprite(&.{
            .texture = glyphs_tex,
            .pos_offset = .{ .x = cursor_x.*, .y = -glyph_y },
            .pos_extent = .{ .x = rect.render_w, .y = rect.render_h },
            .tex_offset = .{ .x = rect.tex_x, .y = rect.tex_y },
            .tex_extent = .{ .x = rect.tex_w, .y = rect.tex_h },
            .color = Colors.white_fg,
            .layer = sprite_layer,
            .reference = anchor,
            .origin = .bottom_left,
        });
        if (prompt.letter_overlay) |overlay| {
            list.add_text(&.{
                .str = overlay,
                .pos_x = cursor_x.* + @divTrunc(rect.render_w, 2),
                .pos_y = -(glyph_y + @divTrunc(rect.render_h, 2) - 1),
                .color = Colors.white_fg,
                .shadow_color = Colors.menu_gray,
                .spacing = 0,
                .layer = text_layer,
                .reference = anchor,
                .origin = .middle_center,
            });
        }
        cursor_x.* += rect.render_w;
    }

    const kbm_label_nudge: i16 = if (style == .kbm) 1 else 0;
    const label_y_center: i16 = y_base + @divTrunc(last_rect.render_h, 2) - 1 - kbm_label_nudge;
    cursor_x.* += GLYPH_PAD;
    list.add_text(&.{
        .str = prompt.label,
        .pos_x = cursor_x.*,
        .pos_y = -label_y_center,
        .color = Colors.white_fg,
        .shadow_color = Colors.menu_gray,
        .spacing = 0,
        .layer = text_layer,
        .reference = anchor,
        .origin = .middle_left,
    });
    cursor_x.* += fonts.string_width(prompt.label, 0, 1);
}
