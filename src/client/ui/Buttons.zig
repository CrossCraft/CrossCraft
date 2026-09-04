//! Physical controller / keyboard-and-mouse button to sprite-rect lookup.
//! `pc.png` uses paired 32px rows for Xbox, Nintendo, PlayStation, and KBM.
//! `psp.png` uses 8px face buttons and 16x8 wide buttons.

const ae = @import("aether");
const Options = @import("../Options.zig");
const input = ae.Core.input;

pub const Rect = struct {
    tex_x: i16,
    tex_y: i16,
    tex_w: i16,
    tex_h: i16,
    render_w: i16,
    render_h: i16,
};

/// Face buttons use physical positions: A=bottom, B=right, X=left, Y=top.
/// Some values are only valid for one style (`Home`, `LMB`, and so on).
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

pub const Style = enum {
    kbm,
    nintendo,
    xbox,
    playstation,
    psp,
};

pub fn strip_height() i16 {
    return if (ae.platform == .psp) 32 else 28;
}

pub fn glyph_y_offset() i16 {
    return if (resolve_style() == .kbm) 1 else 0;
}

var last_mode: input.InputMode = .keyboard_mouse;

pub fn note_input_mode(mode: input.InputMode) void {
    last_mode = mode;
}

pub fn resolve_style() Style {
    if (ae.platform == .psp) return .psp;
    if ((ae.platform == .nintendo_3ds or ae.platform == .nintendo_switch) and Options.current.controller_tooltips != .off) return .nintendo;
    return switch (Options.current.controller_tooltips) {
        // Xbox stands in for gamepads whose vendor is unknown.
        .auto => switch (last_mode) {
            .keyboard_mouse => .kbm,
            .gamepad => .xbox,
        },
        .nintendo => .nintendo,
        .xbox => .xbox,
        .playstation => .playstation,
        .off => .kbm,
    };
}

pub fn lookup(button: Button, style: Style) Rect {
    if (style == .psp) return lookup_psp(button);
    if (style == .kbm) return lookup_kbm(button);
    return lookup_controller(button, style);
}

const PC_TILE: i16 = 32;
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
        .A => pc_tile(if (style == .nintendo) 1 else 0, row0),
        .B => pc_tile(if (style == .nintendo) 0 else 1, row0),
        .X => pc_tile(if (style == .nintendo) 3 else 2, row0),
        .Y => pc_tile(if (style == .nintendo) 2 else 3, row0),
        .DpadUp => pc_tile(4, row0),
        .DpadDown => pc_tile(5, row0),
        .DpadLeft => pc_tile(6, row0),
        .DpadRight => pc_tile(7, row0),
        .LStick => pc_tile(0, row1),
        .RStick => pc_tile(1, row1),
        .LButton => pc_tile(2, row1),
        .RButton => pc_tile(3, row1),
        // Trigger art is ordered right, then left.
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

test "glyph sheets map platform-specific controls" {
    const std = @import("std");
    const r = lookup(.A, .xbox);
    try std.testing.expect(r.render_w > 0 and r.render_h > 0);
    try std.testing.expect(lookup(.A, .nintendo).tex_x == PC_TILE);
    try std.testing.expect(lookup(.B, .nintendo).tex_x == 0);
    try std.testing.expect(lookup(.X, .nintendo).tex_x == 3 * PC_TILE);
    try std.testing.expect(lookup(.Y, .nintendo).tex_x == 2 * PC_TILE);
    const p = lookup(.LButton, .psp);
    try std.testing.expect(p.tex_w == PSP_WIDE_W);
    const k = lookup(.EscapeKey, .kbm);
    try std.testing.expect(k.render_w == PC_RENDER);
}
