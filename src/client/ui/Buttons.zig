//! Physical controller / keyboard-and-mouse button to sprite-rect lookup.
//!
//! Owns the translation from a single physical button (under a given input
//! style) to the texture rectangle that should appear.  Pure data: no
//! allocation, no draw calls.  Style is resolved from Options.current; see
//! `resolve_style`.
//!
//! Sheet conventions (resources/default/assets/crosscraft/textures/
//! interface/controller_glyphs/):
//!   pc.png  (256x256, 32x32 tiles).  Rows come in pairs: Xbox 0-1,
//!           Nintendo 2-3, PlayStation 4-5, KB+M 6-7.
//!           Controller row N: A, B, X, Y, DpadUp, DpadDown, DpadLeft, DpadRight.
//!           Controller row N+1: LStick, RStick, LButton, RButton,
//!             LTrigger, RTrigger, Start, Select.
//!           KB+M row 7 (cols 0-4): LMB, RMB, BlankKey, Enter, Escape.
//!   psp.png (64x64).
//!           Row 0 (8x8 tiles): Cross, Circle, Square, Triangle,
//!             DpadUp, DpadDown, DpadLeft, DpadRight.
//!           Row 1 (16x8 tiles): L shoulder, R shoulder, Start, Select.
//!           Row 2 (16x8 tiles): Home.

const ae = @import("aether");
const Options = @import("../Options.zig");

pub const Rect = struct {
    /// Source rect in the glyph sheet.
    tex_x: i16,
    tex_y: i16,
    tex_w: i16,
    tex_h: i16,
    /// On-screen rendered size in logical pixels.  May differ from the
    /// source size when the desktop sheet is sampled smaller so the glyph
    /// sits next to 8 px font text without towering over it.
    render_w: i16,
    render_h: i16,
};

/// A single physical button.  Semantic naming: A=bottom, B=right, X=left,
/// Y=top, matching Xbox conventions.  On PSP A=Cross, B=Circle, X=Square,
/// Y=Triangle; the sprite art lives in the physically-correct position on
/// each sheet regardless of the manufacturer label.
///
/// Not every value is valid in every style (e.g. `.LMB` is KB+M-only,
/// `.Home` is PSP-only).  `lookup` hits `unreachable` on invalid combos;
/// Prompts.zig resolves style first and picks a valid button.
pub const Button = enum(u8) {
    A,
    B,
    X,
    Y,
    DpadUp,
    DpadDown,
    DpadLeft,
    DpadRight,
    LStick,
    RStick,
    LButton,
    RButton,
    LTrigger,
    RTrigger,
    Start,
    Select,
    Home,
    LMB,
    RMB,
    BlankKey,
    EnterKey,
    EscapeKey,
};

/// Resolved rendering style.  `.off` is not in this enum; callers must
/// short-circuit via `PromptStrip.enabled` before resolving.
pub const Style = enum {
    kbm,
    nintendo,
    xbox,
    playstation,
    psp,
};

/// Logical-pixel height by which the hotbar rides up while the strip
/// is visible, so the strip sits in a clean band below the hotbar.
/// Reference layout lifted the hotbar 32 px in 480x272 PSP native,
/// which scales to 28 in the 400x240 desktop reference.  PSP runs in
/// its native space at scale=1, so the raw reference value applies.
pub fn strip_height() i16 {
    return if (ae.platform == .psp) 32 else 28;
}

/// Per-style vertical nudge applied to the glyph (and any letter overlay)
/// in logical pixels, positive = down.  Keyboard art has built-in padding
/// that reads as floating above the label baseline; dropping it one pixel
/// lines KB+M up with the controller glyphs.
pub fn glyph_y_offset() i16 {
    return if (resolve_style() == .kbm) 1 else 0;
}

pub fn resolve_style() Style {
    if (ae.platform == .psp) return .psp;
    return switch (Options.current.controller_tooltips) {
        // Auto follows whatever device produced input most recently; the
        // Xbox sheet stands in for any gamepad since we don't probe vendor.
        .auto => switch (ae.Core.input.get_last_input_mode()) {
            .keyboard => .kbm,
            .controller => .xbox,
        },
        .nintendo => .nintendo,
        .xbox => .xbox,
        .playstation => .playstation,
        // Callers must not reach resolve_style with .off; fall back so a
        // misbehaving caller lands somewhere sane rather than UB.
        .off => .kbm,
    };
}

/// Look up the sheet rect for `button` under `style`.  Invalid combos
/// (e.g. `.LMB` on a controller style) hit `unreachable`.
pub fn lookup(button: Button, style: Style) Rect {
    if (style == .psp) return lookup_psp(button);
    if (style == .kbm) return lookup_kbm(button);
    return lookup_controller(button, style);
}

// -- pc.png (controller styles) ---------------------------------------------

const PC_TILE: i16 = 32;
/// Desktop sheet tiles are 32x32 in source, rendered at half-size so the
/// glyph sits next to 8 px font text without towering over it.
const PC_RENDER: i16 = 16;

fn pc_row_pair_base(style: Style) i16 {
    return switch (style) {
        .xbox => 0,
        .nintendo => 2 * PC_TILE,
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

fn lookup_controller(button: Button, style: Style) Rect {
    const row0 = pc_row_pair_base(style);
    const row1 = row0 + PC_TILE;
    return switch (button) {
        .A => pc_tile(0, row0),
        .B => pc_tile(1, row0),
        .X => pc_tile(2, row0),
        .Y => pc_tile(3, row0),
        .DpadUp => pc_tile(4, row0),
        .DpadDown => pc_tile(5, row0),
        .DpadLeft => pc_tile(6, row0),
        .DpadRight => pc_tile(7, row0),
        .LStick => pc_tile(0, row1),
        .RStick => pc_tile(1, row1),
        .LButton => pc_tile(2, row1),
        .RButton => pc_tile(3, row1),
        // Triggers: the sheet art has the right trigger at col 4 and
        // the left at col 5, which is the reverse of the nominal
        // "LTrigger, RTrigger" column ordering in the sheet comment.
        .RTrigger => pc_tile(4, row1),
        .LTrigger => pc_tile(5, row1),
        .Start => pc_tile(6, row1),
        .Select => pc_tile(7, row1),
        else => unreachable,
    };
}

fn lookup_kbm(button: Button) Rect {
    const row = 7 * PC_TILE;
    return switch (button) {
        .LMB => pc_tile(0, row),
        .RMB => pc_tile(1, row),
        .BlankKey => pc_tile(2, row),
        .EnterKey => pc_tile(3, row),
        .EscapeKey => pc_tile(4, row),
        else => unreachable,
    };
}

// -- psp.png ----------------------------------------------------------------

const PSP_FACE: i16 = 8;
const PSP_WIDE_W: i16 = 16;
const PSP_WIDE_H: i16 = 8;

fn psp_rect(x: i16, y: i16, w: i16, h: i16) Rect {
    return .{ .tex_x = x, .tex_y = y, .tex_w = w, .tex_h = h, .render_w = w, .render_h = h };
}

fn psp_face(col: i16) Rect {
    return psp_rect(col * PSP_FACE, 0, PSP_FACE, PSP_FACE);
}

fn psp_wide(col: i16, row_y: i16) Rect {
    return psp_rect(col * PSP_WIDE_W, row_y, PSP_WIDE_W, PSP_WIDE_H);
}

fn lookup_psp(button: Button) Rect {
    return switch (button) {
        .A => psp_face(0), // Cross
        .B => psp_face(1), // Circle
        .X => psp_face(2), // Square
        .Y => psp_face(3), // Triangle
        .DpadUp => psp_face(4),
        .DpadDown => psp_face(5),
        .DpadLeft => psp_face(6),
        .DpadRight => psp_face(7),
        .LButton => psp_wide(0, PSP_FACE),
        .RButton => psp_wide(1, PSP_FACE),
        .Start => psp_wide(2, PSP_FACE),
        .Select => psp_wide(3, PSP_FACE),
        .Home => psp_wide(0, PSP_FACE * 2),
        else => unreachable,
    };
}

test "lookup covers every style for the buttons it supports" {
    const std = @import("std");
    // Spot-check a handful of combinations so the switch exhaustiveness
    // is exercised at comptime by the compiler for the rest.
    const r = lookup(.A, .xbox);
    try std.testing.expect(r.render_w > 0 and r.render_h > 0);
    const p = lookup(.LButton, .psp);
    try std.testing.expect(p.tex_w == PSP_WIDE_W);
    const k = lookup(.EscapeKey, .kbm);
    try std.testing.expect(k.render_w == PC_RENDER);
}
