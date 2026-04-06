/// Widget tagged union + Screen container.
///
/// A Screen owns a slice of widgets (caller-allocated, lifetime ≥ Screen) and
/// dispatches input + draw across them. The widget array layout is declarative:
/// each widget carries its position, callbacks, and tag-specific data.
///
/// Navigation has two topologies — `stack` (vertical menus) and `grid` (block
/// pickers, hotbars). The `focused` index plus `focus_source` (mouse vs pad)
/// gives hybrid input coherence: whichever device touched the UI most recently
/// owns the highlight, but the other device can take over instantly.
const std = @import("std");
const ae = @import("aether");
const Rendering = ae.Rendering;

const SpriteBatcher = @import("SpriteBatcher.zig");
const FontBatcher = @import("FontBatcher.zig");
const layout = @import("layout.zig");
const Color = @import("../graphics/Color.zig").Color;
const ui_input = @import("input.zig");
const UiInput = ui_input.UiInput;
const NavDir = ui_input.NavDir;

pub const Anchor = layout.Anchor;

pub const ActivateFn = *const fn (ctx: *anyopaque) void;
pub const DrawFn = *const fn (
    ctx: *anyopaque,
    sprites: *SpriteBatcher,
    fonts: *FontBatcher,
    gui_tex: *const Rendering.Texture,
) void;

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

pub const Widget = union(enum) {
    button: Button,
    label: Label,
    spacer: void,

    pub fn focusable(self: Widget) bool {
        return switch (self) {
            .button => |b| b.enabled,
            else => false,
        };
    }
};

pub const NavTopology = enum { stack, grid };

pub const FocusSource = enum { mouse, pad };

pub const Screen = struct {
    widgets: []const Widget,
    ctx: *anyopaque,
    nav: NavTopology = .stack,
    row_width: u8 = 1,
    hovered: ?u8 = null,
    focused: ?u8 = null,
    focus_source: FocusSource = .mouse,
    /// Set by `update` when ui_cancel was pressed; the owning state reads it
    /// after `update` returns to drive back/pop transitions.
    cancel_pressed: bool = false,
    /// Added to every drawn widget's layer. Lets the pause screen sit above an
    /// in-game darkening overlay without colliding with HUD layers.
    layer_base: u8 = 0,
    draw_underlay: ?DrawFn = null,

    pub fn open(self: *Screen, seed_focus: bool) void {
        self.hovered = null;
        self.focused = if (seed_focus) self.first_focusable() else null;
        self.focus_source = if (seed_focus) .pad else .mouse;
        self.cancel_pressed = false;
    }

    pub fn update(self: *Screen, in: *const UiInput) void {
        std.debug.assert(self.widgets.len > 0);
        std.debug.assert(self.widgets.len <= std.math.maxInt(u8));

        self.cancel_pressed = in.cancel_edge;

        // Mouse hover takes the highlight whenever the cursor moves.
        if (in.cursor_available and in.cursor_moved) {
            const hit = self.hover_pick(in.cursor_x, in.cursor_y);
            self.hovered = hit;
            if (hit) |idx| {
                self.focused = idx;
                self.focus_source = .mouse;
            } else if (self.focus_source == .mouse) {
                self.focused = null;
            }
        }

        // Gamepad/keyboard nav takes the highlight whenever a direction fires.
        if (in.nav != .none) {
            self.focus_source = .pad;
            self.nav_advance(in.nav);
        }

        // Activation: clicks dispatch by cursor position regardless of focus
        // source; confirm dispatches the focused widget.
        if (in.cursor_available and in.click_edge) {
            if (self.hover_pick(in.cursor_x, in.cursor_y)) |idx| {
                self.hovered = idx;
                self.focused = idx;
                self.focus_source = .mouse;
                self.activate(idx);
                return;
            }
        }
        if (in.confirm_edge) {
            if (self.activation_target()) |idx| self.activate(idx);
        }
    }

    fn activate(self: *Screen, idx: u8) void {
        std.debug.assert(idx < self.widgets.len);
        const w = self.widgets[idx];
        switch (w) {
            .button => |b| if (b.enabled) b.on_activate(self.ctx),
            else => {},
        }
    }

    fn hover_pick(self: *const Screen, cx: i16, cy: i16) ?u8 {
        const screen_w = Rendering.gfx.surface.get_width();
        const screen_h = Rendering.gfx.surface.get_height();
        const ui_scale = @import("Scaling.zig").compute(screen_w, screen_h);
        const max_lx: i16 = @intCast(screen_w / ui_scale);
        const max_ly: i16 = @intCast(screen_h / ui_scale);

        for (self.widgets, 0..) |w, i| {
            if (!w.focusable()) continue;
            const b = w.button;
            const ref = layout.anchor_point(b.reference, max_lx, max_ly);
            const orig = layout.anchor_point(b.origin, b.width, b.height);
            const x0: i16 = ref.x + b.pos_x - orig.x;
            const y0: i16 = ref.y + b.pos_y - orig.y;
            const x1: i16 = x0 + b.width;
            const y1: i16 = y0 + b.height;
            if (cx >= x0 and cx < x1 and cy >= y0 and cy < y1) {
                return @intCast(i);
            }
        }
        return null;
    }

    fn nav_advance(self: *Screen, dir: NavDir) void {
        switch (self.nav) {
            .stack => self.nav_stack(dir),
            .grid => self.nav_grid(dir),
        }
    }

    fn nav_stack(self: *Screen, dir: NavDir) void {
        if (dir != .up and dir != .down) return;
        const first = self.first_focusable() orelse return;

        // Walk widget indices in the requested direction, skipping non-focusable.
        const len: i32 = @intCast(self.widgets.len);
        const step: i32 = if (dir == .down) 1 else -1;
        const start: i32 = if (self.focused) |f|
            @intCast(f)
        else if (dir == .down)
            @as(i32, @intCast(first)) - 1
        else
            @as(i32, @intCast(first)) + 1;

        var i: i32 = start;
        var tries: i32 = 0;
        while (tries < len) : (tries += 1) {
            i += step;
            if (i < 0) i = len - 1;
            if (i >= len) i = 0;
            if (self.widgets[@intCast(i)].focusable()) {
                self.focused = @intCast(i);
                return;
            }
        }
    }

    fn nav_grid(self: *Screen, dir: NavDir) void {
        std.debug.assert(self.row_width > 0);
        const rw: i32 = @intCast(self.row_width);
        const len: i32 = @intCast(self.widgets.len);
        const cur: i32 = if (self.focused) |f|
            @intCast(f)
        else blk: {
            const first = self.first_focusable() orelse return;
            self.focused = first;
            break :blk @as(i32, @intCast(first));
        };
        const col: i32 = @mod(cur, rw);
        const row: i32 = @divTrunc(cur, rw);

        var nx: i32 = col;
        var ny: i32 = row;
        switch (dir) {
            .left => nx -= 1,
            .right => nx += 1,
            .up => ny -= 1,
            .down => ny += 1,
            .none => return,
        }
        while (true) {
            if (nx < 0 or nx >= rw or ny < 0) return;
            const next = ny * rw + nx;
            if (next < 0 or next >= len) return;
            if (self.widgets[@intCast(next)].focusable()) {
                self.focused = @intCast(next);
                return;
            }

            switch (dir) {
                .left => nx -= 1,
                .right => nx += 1,
                .up => ny -= 1,
                .down => ny += 1,
                .none => return,
            }
        }
    }

    fn first_focusable(self: *const Screen) ?u8 {
        for (self.widgets, 0..) |w, i| {
            if (w.focusable()) return @intCast(i);
        }
        return null;
    }

    pub fn draw(
        self: *const Screen,
        sprites: *SpriteBatcher,
        fonts: *FontBatcher,
        gui_tex: *const Rendering.Texture,
    ) void {
        if (self.draw_underlay) |draw_underlay| {
            draw_underlay(self.ctx, sprites, fonts, gui_tex);
        }
        for (self.widgets, 0..) |w, i| {
            switch (w) {
                .button => |b| draw_button(sprites, fonts, gui_tex, &b, self.is_highlighted(@intCast(i)), self.layer_base),
                .label => |l| draw_label(fonts, &l, self.layer_base),
                .spacer => {},
            }
        }
    }

    fn activation_target(self: *const Screen) ?u8 {
        if (self.focus_source == .mouse and self.hovered != null) return self.hovered;
        return self.focused;
    }

    fn is_highlighted(self: *const Screen, idx: u8) bool {
        if (self.focus_source == .mouse and self.hovered != null) {
            return self.hovered.? == idx;
        }
        return self.focused != null and self.focused.? == idx;
    }
};

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
    // Catch accidental growth of the widget union — keeps PSP-friendly.
    std.debug.assert(@sizeOf(Widget) <= 64);
}
