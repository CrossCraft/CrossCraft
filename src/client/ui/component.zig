/// Reusable UI component definitions and rendering helpers.
///
/// Components own their tag-specific data, activation callback, hit bounds, and
/// draw behavior. Screen-level focus, navigation, and lifecycle state live in
/// Screen.zig.
const std = @import("std");
const ae = @import("aether");
const Rendering = ae.Rendering;

const SpriteBatcher = @import("SpriteBatcher.zig");
const FontBatcher = @import("FontBatcher.zig");
const layout = @import("layout.zig");
const Color = @import("../graphics/Color.zig").Color;

pub const Anchor = layout.Anchor;

pub const ActivateFn = *const fn (ctx: *anyopaque) void;

pub const Button = struct {
    label: []const u8,
    width: i16,
    height: i16,
    pos_x: i16,
    pos_y: i16,
    reference: Anchor = .top_center,
    origin: Anchor = .top_center,
    enabled: bool = true,
    on_activate: ActivateFn,
};

pub const Label = struct {
    text: []const u8,
    pos_x: i16,
    pos_y: i16,
    color: Color = Color.white,
    shadow_color: Color = Color.menu_gray,
    reference: Anchor = .top_left,
    origin: Anchor = .top_left,
    layer: u8 = 2,
};

pub const Rect = struct {
    x0: i16,
    y0: i16,
    x1: i16,
    y1: i16,

    pub fn contains(self: Rect, x: i16, y: i16) bool {
        return x >= self.x0 and x < self.x1 and y >= self.y0 and y < self.y1;
    }
};

pub const Component = union(enum) {
    button: Button,
    label: Label,
    spacer: void,

    pub fn focusable(self: Component) bool {
        return switch (self) {
            .button => |b| b.enabled,
            else => false,
        };
    }

    pub fn activate(self: Component, ctx: *anyopaque) void {
        switch (self) {
            .button => |b| if (b.enabled) b.on_activate(ctx),
            else => {},
        }
    }

    pub fn hit_rect(self: Component, max_lx: i16, max_ly: i16) ?Rect {
        return switch (self) {
            .button => |b| if (b.enabled) button_rect(&b, max_lx, max_ly) else null,
            else => null,
        };
    }

    pub fn draw(
        self: Component,
        sprites: *SpriteBatcher,
        fonts: *FontBatcher,
        gui_tex: *const Rendering.Texture,
        highlighted: bool,
        layer_base: u8,
    ) void {
        switch (self) {
            .button => |b| draw_button(sprites, fonts, gui_tex, &b, highlighted, layer_base),
            .label => |l| draw_label(fonts, &l, layer_base),
            .spacer => {},
        }
    }
};

fn button_rect(b: *const Button, max_lx: i16, max_ly: i16) Rect {
    const ref = layout.anchor_point(b.reference, max_lx, max_ly);
    const orig = layout.anchor_point(b.origin, b.width, b.height);
    const x0: i16 = ref.x + b.pos_x - orig.x;
    const y0: i16 = ref.y + b.pos_y - orig.y;
    return .{
        .x0 = x0,
        .y0 = y0,
        .x1 = x0 + b.width,
        .y1 = y0 + b.height,
    };
}

/// GUI atlas Y offsets for the three button states (Minecraft Classic gui.png).
const BTN_TEX_DISABLED_Y: i16 = 46;
const BTN_TEX_NORMAL_Y: i16 = 66;
const BTN_TEX_HIGHLIGHT_Y: i16 = 86;
const BTN_TEX_W: i16 = 200;
const BTN_TEX_H: i16 = 20;

fn draw_button(
    sprites: *SpriteBatcher,
    fonts: *FontBatcher,
    gui_tex: *const Rendering.Texture,
    b: *const Button,
    focused: bool,
    layer_base: u8,
) void {
    std.debug.assert(b.width > 0 and b.height > 0);
    const tex_y: i16 = if (!b.enabled)
        BTN_TEX_DISABLED_Y
    else if (focused)
        BTN_TEX_HIGHLIGHT_Y
    else
        BTN_TEX_NORMAL_Y;

    sprites.add_sprite(&.{
        .texture = gui_tex,
        .pos_offset = .{ .x = b.pos_x, .y = b.pos_y },
        .pos_extent = .{ .x = b.width, .y = b.height },
        .tex_offset = .{ .x = 0, .y = tex_y },
        .tex_extent = .{ .x = BTN_TEX_W, .y = BTN_TEX_H },
        .color = .white,
        .layer = layer_base + 2,
        .reference = b.reference,
        .origin = b.origin,
    });

    const label_color: Color = if (!b.enabled)
        Color.light_gray
    else if (focused)
        Color.select_front
    else
        Color.white;
    const shadow_color: Color = if (focused) Color.select_back else Color.menu_gray;
    fonts.add_text(&.{
        .str = b.label,
        .pos_x = b.pos_x,
        .pos_y = b.pos_y + @divTrunc(b.height - 8, 2),
        .color = label_color,
        .shadow_color = shadow_color,
        .spacing = 0,
        .layer = layer_base + 3,
        .reference = b.reference,
        .origin = .top_center,
    });
}

fn draw_label(fonts: *FontBatcher, l: *const Label, layer_base: u8) void {
    fonts.add_text(&.{
        .str = l.text,
        .pos_x = l.pos_x,
        .pos_y = l.pos_y,
        .color = l.color,
        .shadow_color = l.shadow_color,
        .spacing = 0,
        .layer = layer_base + l.layer,
        .reference = l.reference,
        .origin = l.origin,
    });
}

comptime {
    // Catch accidental growth of the component union -- keeps PSP-friendly.
    std.debug.assert(@sizeOf(Component) <= 64);
}
