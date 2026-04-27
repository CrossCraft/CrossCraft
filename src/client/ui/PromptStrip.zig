//! Portable controller / KB+M prompt strip renderer.
//!
//! Given an array of Prompt entries, draws each as [glyph(s)] [label] laid
//! out left-to-right with consistent padding.  The caller owns the batchers
//! and the glyphs texture reference, so both the in-game HUD and any menu
//! Screen can render prompts without duplicating layout math.

const std = @import("std");
const ae = @import("aether");
const Rendering = ae.Rendering;

const Buttons = @import("Buttons.zig");
const SpriteBatcher = @import("SpriteBatcher.zig");
const FontBatcher = @import("FontBatcher.zig");
const layout = @import("layout.zig");
const Options = @import("../Options.zig");

pub const Anchor = layout.Anchor;

pub const Prompt = struct {
    /// Physical buttons drawn left-to-right.  [1] is null for the common
    /// single-button case; set both for chords (PSP L+R for "inventory").
    chord: [2]?Buttons.Button,
    /// Text shown immediately after the final glyph.
    label: []const u8,
    /// Optional ASCII string drawn centered on top of the glyph, used by
    /// KB+M BlankKey prompts (e.g. "B" for inventory, "T" for chat).  The
    /// slice must outlive the FontBatcher flush, so pass a string literal.
    letter_overlay: ?[]const u8 = null,
};

comptime {
    // Guard against accidental Prompt bloat -- PSP-friendly budget.
    std.debug.assert(@sizeOf(Prompt) <= 64);
}

/// True when prompt strips should render at all.  `.off` in Options means
/// the user wants a minimal UI without glyph hints anywhere.
pub fn enabled() bool {
    return Options.current.controller_tooltips != .off;
}

// --- Layout constants (logical pixels) ---

/// Canonical bottom-left offset used by every prompt strip site (menu
/// screens and the in-game HUD) so the strip lands in the same visual
/// spot across platforms and modes.  Reference layout was (20, 23) in
/// 480x272 PSP-native space; x carries over unchanged (left margin
/// reads the same on both targets), y scales to 20 in the 400x240
/// reference.  Kept in one place so a tweak here moves every strip.
pub const DEFAULT_POS_X: i16 = 20;
pub const DEFAULT_POS_Y: i16 = 23 - if (@import("aether").platform == .psp) 8 else 16;

const GLYPH_PAD: i16 = 4; // glyph -> its label
const ENTRY_PAD: i16 = 12; // previous label -> next glyph
const CHORD_PAD: i16 = 2; // glyph -> next glyph inside a chord

/// Draw `prompts` as a horizontal strip starting at (`pos_x`, `pos_y`)
/// relative to `anchor`.  `y_base` behaves like a bottom offset: the
/// glyph sits `y_base` above the reference edge when `anchor` is one of
/// the `bottom_*` variants.  Sprite / text layers are passed explicitly
/// so callers can slot the strip into the appropriate Z band.
pub fn draw(
    prompts: []const Prompt,
    sprites: *SpriteBatcher,
    fonts: *FontBatcher,
    glyphs_tex: *const Rendering.Texture,
    anchor: Anchor,
    pos_x: i16,
    y_base: i16,
    sprite_layer: u8,
    text_layer: u8,
) void {
    if (prompts.len == 0) return;

    const style = Buttons.resolve_style();
    const y_offset = Buttons.glyph_y_offset();

    var cursor_x: i16 = pos_x;
    for (prompts, 0..) |p, i| {
        if (i > 0) cursor_x += ENTRY_PAD;
        draw_one(
            &p,
            style,
            y_offset,
            sprites,
            fonts,
            glyphs_tex,
            anchor,
            &cursor_x,
            y_base,
            sprite_layer,
            text_layer,
        );
    }
}

fn draw_one(
    prompt: *const Prompt,
    style: Buttons.Style,
    y_offset: i16,
    sprites: *SpriteBatcher,
    fonts: *FontBatcher,
    glyphs_tex: *const Rendering.Texture,
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
        sprites.add_sprite(&.{
            .texture = glyphs_tex,
            .pos_offset = .{ .x = cursor_x.*, .y = -glyph_y },
            .pos_extent = .{ .x = rect.render_w, .y = rect.render_h },
            .tex_offset = .{ .x = rect.tex_x, .y = rect.tex_y },
            .tex_extent = .{ .x = rect.tex_w, .y = rect.tex_h },
            .color = .white_fg,
            .layer = sprite_layer,
            .reference = anchor,
            .origin = .bottom_left,
        });
        if (prompt.letter_overlay) |overlay| {
            // Glyph center from bottom-left: (x + w/2, glyph_y + h/2).  The
            // font's cap line sits above its bbox center, so dropping one
            // pixel visually centers the letter on the key face.
            fonts.add_text(&.{
                .str = overlay,
                .pos_x = cursor_x.* + @divTrunc(rect.render_w, 2),
                .pos_y = -(glyph_y + @divTrunc(rect.render_h, 2) - 1),
                .color = .white_fg,
                .shadow_color = .menu_gray,
                .spacing = 0,
                .layer = text_layer,
                .reference = anchor,
                .origin = .middle_center,
            });
        }
        cursor_x.* += rect.render_w;
    }

    // KB+M key art has built-in padding that reads as the label
    // floating above the glyph center; dropping one extra pixel there
    // brings the text in line.  Controller and PSP art sit flush.
    const kbm_label_nudge: i16 = if (style == .kbm) 1 else 0;
    const label_y_center: i16 = y_base + @divTrunc(last_rect.render_h, 2) - 1 - kbm_label_nudge;
    cursor_x.* += GLYPH_PAD;
    fonts.add_text(&.{
        .str = prompt.label,
        .pos_x = cursor_x.*,
        .pos_y = -label_y_center,
        .color = .white_fg,
        .shadow_color = .menu_gray,
        .spacing = 0,
        .layer = text_layer,
        .reference = anchor,
        .origin = .middle_left,
    });
    cursor_x.* += fonts.string_width(prompt.label, 0, 1);
}
