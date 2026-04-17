//! Controller-prompt glyph layout.
//!
//! Owns the translation from "show the Place prompt" to the texture rect
//! that should appear, given the active `Options.controller_tooltips`
//! style.  Pure data + lookups -- no allocation, no draw calls.
//!
//! Sheet conventions (see resources/default/assets/crosscraft/textures/
//! interface/controller_glyphs/):
//!   pc.png  (256x256, 32x32 tiles).  Rows come in pairs: Nintendo 0-1,
//!           Xbox 2-3, PlayStation 4-5, KB+M 6-7.  Row N has face+dpad
//!           (B, A, X, Y, DpadUp, DpadDown, DpadLeft, DpadRight); row
//!           N+1 has LStick, RStick, LButton, RButton, LTrigger, RTrigger,
//!           Start, Select.  The KB+M row uses its first five tiles for
//!           LMB, RMB, Blank key, Enter, Escape.
//!   psp.png (64x64).  Row 0 is 8x8 face/dpad tiles (Cross, Circle,
//!           Square, Triangle, DpadUp/Down/Left/Right).  Row 1 is 16x8
//!           (LTrigger, RTrigger, Start, Select).  Row 2 is 16x8 (Home).

const ae = @import("aether");
const Options = @import("../Options.zig");

pub const Rect = struct {
    /// Source rect in the glyph sheet.
    tex_x: i16,
    tex_y: i16,
    tex_w: i16,
    tex_h: i16,
    /// On-screen rendered size in logical pixels.  May differ from the
    /// source size when the desktop sheet is sampled at a smaller size
    /// to sit comfortably next to 8 px font text.
    render_w: i16,
    render_h: i16,
};

pub const Glyph = enum {
    /// Opens the block picker.  Desktop: B key / Y-equivalent face button.
    /// PSP: the L+R chord; callers render both shoulders side-by-side.
    inventory,
    /// Place block.  Desktop: RMB / RButton.  PSP: L shoulder.
    place,
    /// Break block.  Desktop: LMB / LButton.  PSP: R shoulder.
    break_,
};

/// Resolved glyph style actually used for drawing. `.off` is not in this
/// enum -- callers short-circuit before resolving when tooltips are off.
const Style = enum {
    kbm, // desktop keyboard + mouse (pc.png rows 6-7)
    nintendo, // pc.png rows 0-1
    xbox, // pc.png rows 2-3
    playstation, // pc.png rows 4-5
    psp, // psp.png
};

pub fn enabled() bool {
    return Options.current.controller_tooltips != .off;
}

/// Logical-pixel height reserved for the strip, including a small bit of
/// breathing room above the glyph.  Callers shift the hotbar up by this
/// amount when the strip is visible.
pub fn strip_height() i16 {
    return if (ae.platform == .psp) 12 else 20;
}

/// Number of glyph sprites used for the `inventory` prompt.  PSP renders
/// L and R shoulders together for the L+R chord; every other style is a
/// single button.
pub fn inventory_glyph_count() u8 {
    return if (ae.platform == .psp) 2 else 1;
}

/// Text label shown next to the glyph.
pub fn label(g: Glyph) []const u8 {
    return switch (g) {
        .inventory => "Inventory",
        .place => "Place",
        .break_ => "Break",
    };
}

/// Optional letter string to raster on top of the glyph (only used by
/// the desktop KB+M "blank key" art).  Returns null when no overlay is
/// needed.  The returned slice is backed by a static string so it stays
/// valid across frames.
pub fn letter_overlay(g: Glyph) ?[]const u8 {
    if (resolve_style() != .kbm) return null;
    return switch (g) {
        .inventory => "B", // matches bindings.zig: inventory_toggle -> key B
        .place, .break_ => null,
    };
}

/// Rectangle for `g` in the currently-resolved glyph sheet.  For the PSP
/// inventory chord, `chord_index` selects which of the two shoulder
/// glyphs to return (0 = L, 1 = R); callers on other platforms pass 0.
pub fn lookup(g: Glyph, chord_index: u8) Rect {
    const style = resolve_style();
    if (style == .psp) return lookup_psp(g, chord_index);
    return lookup_pc(g, style);
}

// -- resolution --------------------------------------------------------------

fn resolve_style() Style {
    if (ae.platform == .psp) return .psp;
    return switch (Options.current.controller_tooltips) {
        // No runtime gamepad detection yet; auto == KB+M on desktop.
        .auto => .kbm,
        .nintendo => .nintendo,
        .xbox => .xbox,
        .playstation => .playstation,
        // Callers must not reach resolve_style with .off.
        .off => .kbm,
    };
}

// -- pc.png ------------------------------------------------------------------

const PC_TILE: i16 = 32;
/// Desktop sheet tiles are 32x32 in source but rendered at half-size so
/// the glyph sits comfortably next to 8 px font text.
const PC_RENDER: i16 = 16;

fn pc_row_pair_base(style: Style) i16 {
    return switch (style) {
        .nintendo => 0,
        .xbox => 2 * PC_TILE,
        .playstation => 4 * PC_TILE,
        .kbm => 6 * PC_TILE,
        .psp => unreachable,
    };
}

fn pc_tile(col: i16, row_y: i16) Rect {
    return .{
        .tex_x = col * PC_TILE,
        .tex_y = row_y,
        .tex_w = PC_TILE,
        .tex_h = PC_TILE,
        .render_w = PC_RENDER,
        .render_h = PC_RENDER,
    };
}

fn lookup_pc(g: Glyph, style: Style) Rect {
    const base_y = pc_row_pair_base(style);
    if (style == .kbm) {
        // KB+M glyphs: row 7 (the bottom row of the sheet), cols 0..4 =
        // LMB, RMB, Blank key, Enter, Escape.
        const col: i16 = switch (g) {
            .break_ => 0, // LMB
            .place => 1, // RMB
            .inventory => 2, // Blank key -- 'B' rastered on top
        };
        return pc_tile(col, base_y + PC_TILE);
    }
    // Controller layouts: inventory = top face button (slot 3 on row 0),
    // place = RButton (slot 3 on row 1), break = LButton (slot 2 on row 1).
    return switch (g) {
        .inventory => pc_tile(3, base_y),
        .place => pc_tile(3, base_y + PC_TILE),
        .break_ => pc_tile(2, base_y + PC_TILE),
    };
}

// -- psp.png -----------------------------------------------------------------

const PSP_FACE: i16 = 8;
const PSP_WIDE_W: i16 = 16;
const PSP_WIDE_H: i16 = 8;

fn psp_rect(x: i16, y: i16, w: i16, h: i16) Rect {
    return .{ .tex_x = x, .tex_y = y, .tex_w = w, .tex_h = h, .render_w = w, .render_h = h };
}

fn lookup_psp(g: Glyph, chord_index: u8) Rect {
    // Shoulder tiles live on row 1 at y = 8: L = x 0, R = x 16.
    const l_shoulder = psp_rect(0, PSP_FACE, PSP_WIDE_W, PSP_WIDE_H);
    const r_shoulder = psp_rect(PSP_WIDE_W, PSP_FACE, PSP_WIDE_W, PSP_WIDE_H);
    return switch (g) {
        // L+R chord: index 0 = L, 1 = R.
        .inventory => if (chord_index == 0) l_shoulder else r_shoulder,
        // Per bindings.zig: L shoulder places, R shoulder breaks.
        .place => l_shoulder,
        .break_ => r_shoulder,
    };
}
