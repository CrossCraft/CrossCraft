/// Screen-level UI state and dispatch.
///
/// A Screen owns a slice of components (caller-allocated, lifetime >= Screen)
/// and handles input, focus, navigation, activation, and draw ordering across
/// them. Individual component data and rendering live in component.zig.
const std = @import("std");
const ae = @import("aether");
const Rendering = ae.Rendering;

const SpriteBatcher = @import("SpriteBatcher.zig");
const FontBatcher = @import("FontBatcher.zig");
const Scaling = @import("Scaling.zig");
const component = @import("component.zig");
const ui_input = @import("input.zig");
const UiInput = ui_input.UiInput;
const NavDir = ui_input.NavDir;

const Self = @This();

const Component = component.Component;
pub const NavTopology = enum { stack, grid };
pub const FocusSource = enum { mouse, pad };
pub const DrawFn = *const fn (
    ctx: *anyopaque,
    sprites: *SpriteBatcher,
    fonts: *FontBatcher,
    gui_tex: *const Rendering.Texture,
) void;

components: []const Component,
ctx: *anyopaque,
nav: NavTopology = .stack,
row_width: u8 = 1,
hovered: ?u8 = null,
focused: ?u8 = null,
focus_source: FocusSource = .mouse,
/// Set by `update` when ui_cancel was pressed; the owning state reads it
/// after `update` returns to drive back/pop transitions.
cancel_pressed: bool = false,
/// Added to every drawn component's layer. Lets the pause screen sit above an
/// in-game darkening overlay without colliding with HUD layers.
layer_base: u8 = 0,
draw_underlay: ?DrawFn = null,

pub fn open(self: *Self, seed_focus: bool) void {
    self.hovered = null;
    self.focused = if (seed_focus) self.first_focusable() else null;
    self.focus_source = if (seed_focus) .pad else .mouse;
    self.cancel_pressed = false;
}

pub fn update(self: *Self, in: *const UiInput) void {
    std.debug.assert(self.components.len > 0);
    std.debug.assert(self.components.len <= std.math.maxInt(u8));

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
    // source; confirm dispatches the focused component.
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

fn activate(self: *Self, idx: u8) void {
    std.debug.assert(idx < self.components.len);
    self.components[idx].activate(self.ctx);
}

fn hover_pick(self: *const Self, cx: i16, cy: i16) ?u8 {
    const screen_w = Rendering.gfx.surface.get_width();
    const screen_h = Rendering.gfx.surface.get_height();
    const ui_scale = Scaling.compute(screen_w, screen_h);
    const max_lx: i16 = @intCast(screen_w / ui_scale);
    const max_ly: i16 = @intCast(screen_h / ui_scale);

    for (self.components, 0..) |c, i| {
        if (!c.focusable()) continue;
        const rect = c.hit_rect(max_lx, max_ly) orelse continue;
        if (rect.contains(cx, cy)) return @intCast(i);
    }
    return null;
}

fn nav_advance(self: *Self, dir: NavDir) void {
    switch (self.nav) {
        .stack => self.nav_stack(dir),
        .grid => self.nav_grid(dir),
    }
}

fn nav_stack(self: *Self, dir: NavDir) void {
    if (dir != .up and dir != .down) return;
    const first = self.first_focusable() orelse return;

    // Walk component indices in the requested direction, skipping non-focusable.
    const len: i32 = @intCast(self.components.len);
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
        if (self.components[@intCast(i)].focusable()) {
            self.focused = @intCast(i);
            return;
        }
    }
}

fn nav_grid(self: *Self, dir: NavDir) void {
    std.debug.assert(self.row_width > 0);
    const rw: i32 = @intCast(self.row_width);
    const len: i32 = @intCast(self.components.len);
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
        if (self.components[@intCast(next)].focusable()) {
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

fn first_focusable(self: *const Self) ?u8 {
    for (self.components, 0..) |c, i| {
        if (c.focusable()) return @intCast(i);
    }
    return null;
}

pub fn draw(
    self: *const Self,
    sprites: *SpriteBatcher,
    fonts: *FontBatcher,
    gui_tex: *const Rendering.Texture,
) void {
    if (self.draw_underlay) |draw_underlay| {
        draw_underlay(self.ctx, sprites, fonts, gui_tex);
    }
    for (self.components, 0..) |c, i| {
        c.draw(sprites, fonts, gui_tex, self.is_highlighted(@intCast(i)), self.layer_base);
    }
}

fn activation_target(self: *const Self) ?u8 {
    if (self.focus_source == .mouse and self.hovered != null) return self.hovered;
    return self.focused;
}

fn is_highlighted(self: *const Self, idx: u8) bool {
    if (self.focus_source == .mouse and self.hovered != null) {
        return self.hovered.? == idx;
    }
    return self.focused != null and self.focused.? == idx;
}
