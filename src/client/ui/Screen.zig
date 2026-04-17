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
/// Text input that is actively receiving keystrokes. Only changes on click
/// or keyboard navigation, NOT on mouse hover - so moving the mouse over
/// another component highlights it without stealing typing focus.
active_input: ?u8 = null,
/// Set when the PSP OSK should be shown for a text input. The owning
/// state must read this after draw/flush (when the GE is idle) and call
/// showOSK, then clear the field. Deferring avoids calling showOSK from
/// update where the GE command buffer is in an unsafe state.
osk_request: ?u8 = null,
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
    self.active_input = null;
    self.osk_request = null;
    self.focus_source = if (seed_focus) .pad else .mouse;
    self.cancel_pressed = false;
}

pub fn update(self: *Self, in: *const UiInput) void {
    std.debug.assert(self.components.len > 0);
    std.debug.assert(self.components.len <= std.math.maxInt(u8));

    self.cancel_pressed = in.cancel_edge;

    const has_active_input = if (self.active_input) |a|
        self.components[a] == .text_input
    else
        false;

    // Mouse hover updates the visual highlight but does NOT change
    // active_input - that only changes on click or keyboard nav.
    if (in.cursor_available and in.cursor_moved) {
        const hit = self.hover_pick(in.cursor_x, in.cursor_y);
        self.hovered = hit;
        if (!has_active_input) {
            if (hit) |idx| {
                self.focused = idx;
                self.focus_source = .mouse;
            } else if (self.focus_source == .mouse) {
                self.focused = null;
            }
        }
    }

    // Route typed characters to the active text input. WASD navigation
    // is suppressed while an input is active (those keys type instead).
    if (has_active_input) {
        const typed = self.apply_text_input(in);
        if (!typed and in.nav != .none) {
            self.focus_source = .pad;
            self.nav_advance(in.nav);
            self.sync_active_to_focus();
        }
    } else {
        if (in.nav != .none) {
            self.focus_source = .pad;
            self.nav_advance(in.nav);
            self.sync_active_to_focus();
        }
    }

    // Click: select the component under the cursor. For text inputs this
    // makes them the active input; for buttons it activates them.
    if (in.cursor_available and in.click_edge) {
        if (self.hover_pick(in.cursor_x, in.cursor_y)) |idx| {
            self.hovered = idx;
            self.focused = idx;
            self.focus_source = .mouse;
            if (self.components[idx] == .text_input) {
                self.active_input = idx;
            } else {
                self.active_input = null;
                self.activate(idx);
            }
            return;
        }
        // Clicked on empty space - deselect active input.
        self.active_input = null;
    }
    if (in.confirm_edge) {
        if (self.activation_target()) |idx| {
            if (self.components[idx] == .text_input) {
                if (ae.platform == .psp) {
                    self.osk_request = idx;
                } else {
                    // Enter on a text input advances focus to the next field.
                    self.focus_source = .pad;
                    self.nav_advance(.down);
                    self.sync_active_to_focus();
                }
            } else {
                self.active_input = null;
                self.activate(idx);
            }
        }
    }
}

/// After keyboard navigation moves focus, update active_input to match
/// if the new focus target is a text input (or clear it if not).
fn sync_active_to_focus(self: *Self) void {
    if (self.focused) |f| {
        if (self.components[f] == .text_input) {
            self.active_input = f;
        } else {
            self.active_input = null;
        }
    } else {
        self.active_input = null;
    }
}

/// Writes typed characters into the active TextInput buffer. Returns true
/// if any characters were consumed (used to suppress overlapping nav).
fn apply_text_input(self: *Self, in: *const UiInput) bool {
    const idx = self.active_input orelse return false;
    const ti = switch (self.components[idx]) {
        .text_input => |t| t,
        else => return false,
    };

    var consumed = false;

    // Backspace
    if (in.backspace and ti.len.* > 0) {
        ti.len.* -= 1;
        consumed = true;
    }

    // Append typed characters
    for (in.char_buf[0..in.char_count]) |ch| {
        if (ti.len.* < ti.max_len) {
            ti.buf[ti.len.*] = ch;
            ti.len.* += 1;
            consumed = true;
        }
    }
    return consumed;
}

/// PSP: opens the system on-screen keyboard for the given TextInput,
/// blocking until the user confirms or cancels. On confirm, copies the
/// result back into the component's ASCII buffer. Must be called when the
/// GE is idle (after draw/flush), not from update.
pub fn open_psp_osk(self: *Self, idx: u8) void {
    const ti = switch (self.components[idx]) {
        .text_input => |t| t,
        else => return,
    };

    // Build a UTF-16 description from the placeholder.
    var desc_buf: [64:0]u16 = .{0} ** 64;
    for (ti.placeholder, 0..) |ch, i| {
        if (i >= 63) break;
        desc_buf[i] = ch;
    }

    var out_buf: [64]u16 = .{0} ** 64;
    const limit: c_int = @intCast(ti.max_len);
    const result = ae.Psp.showOSK(&desc_buf, &out_buf, limit);
    if (result != 0) return;

    // Copy UTF-16 output back to the ASCII buffer, truncating to max_len.
    var len: u8 = 0;
    for (out_buf) |wc| {
        if (wc == 0) break;
        if (len >= ti.max_len) break;
        // Only keep ASCII-range characters.
        if (wc <= 127) {
            ti.buf[len] = @intCast(wc);
            len += 1;
        }
    }
    ti.len.* = len;
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

    switch (dir) {
        .left, .right => {
            const step: i32 = if (dir == .right) 1 else -1;
            var nx: i32 = col + step;
            while (nx >= 0 and nx < rw) : (nx += step) {
                const next = row * rw + nx;
                if (next < 0 or next >= len) return;
                if (self.components[@intCast(next)].focusable()) {
                    self.focused = @intCast(next);
                    return;
                }
            }
        },
        .up, .down => {
            const step: i32 = if (dir == .down) 1 else -1;
            // Pass 1: walk the same column first so a disabled cell never
            // pivots focus sideways when a straight-ahead focusable exists.
            var ny: i32 = row + step;
            while (ny >= 0) : (ny += step) {
                const idx = ny * rw + col;
                if (idx >= len and step > 0) break;
                if (idx >= 0 and idx < len and
                    self.components[@intCast(idx)].focusable())
                {
                    self.focused = @intCast(idx);
                    return;
                }
            }
            // Pass 2: column exhausted -- scan each row in direction for any
            // focusable, preferring cells nearer the original column. Handles
            // asymmetric rows like a centered Done below two-column options.
            ny = row + step;
            while (ny >= 0) : (ny += step) {
                var off: i32 = 1;
                const first_in_row = ny * rw;
                if (first_in_row >= len and step > 0) return;
                while (off < rw) : (off += 1) {
                    const cols = [_]i32{ col - off, col + off };
                    for (cols) |cc| {
                        if (cc < 0 or cc >= rw) continue;
                        const idx = ny * rw + cc;
                        if (idx < 0 or idx >= len) continue;
                        if (self.components[@intCast(idx)].focusable()) {
                            self.focused = @intCast(idx);
                            return;
                        }
                    }
                }
            }
        },
        .none => return,
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
        const idx: u8 = @intCast(i);
        const active = self.active_input != null and self.active_input.? == idx;
        c.draw(sprites, fonts, gui_tex, self.is_highlighted(idx) or active, self.layer_base);
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
