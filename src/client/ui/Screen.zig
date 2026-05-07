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
const PromptStrip = @import("PromptStrip.zig");

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

/// Caps the prompt strip the Screen can host per frame.  Four is enough
/// for every menu today (typical: Select + Back).  The buffer lives on
/// the Screen so `PromptsFn` never has to manage its own storage.
pub const MAX_PROMPTS: u8 = 4;
/// Builds the prompt list for the current frame.  Runs every draw so
/// style cycles from the Options menu take effect immediately.  Fills
/// `buf` and returns the populated slice.
pub const PromptsFn = *const fn (ctx: *anyopaque, buf: []PromptStrip.Prompt) []const PromptStrip.Prompt;

components: []const Component,
ctx: *anyopaque,
nav: NavTopology = .stack,
row_width: u8 = 1,
hovered: ?u8 = null,
focused: ?u8 = null,
/// Text input that is actively receiving keystrokes. Only changes on click
/// or keyboard navigation, NOT on mouse hover - so moving the mouse over
/// another component highlights it without stealing typing focus. When
/// non-null, the screen owns a TextInputSession mirrored into the field
/// each frame.
active_input: ?u8 = null,
/// True once a TextInputSession has been started for `active_input`, so
/// re-clicking the same field is idempotent.
session_started: bool = false,
focus_source: FocusSource = .mouse,
/// Set by `update` when ui_cancel was pressed; the owning state reads it
/// after `update` returns to drive back/pop transitions.
cancel_pressed: bool = false,
/// Added to every drawn component's layer. Lets the pause screen sit above an
/// in-game darkening overlay without colliding with HUD layers.
layer_base: u8 = 0,
draw_underlay: ?DrawFn = null,
/// Optional per-frame prompt builder.  When set, a controller / KB+M
/// prompt strip is drawn at the screen's bottom-left.  Null = no strip.
prompts_fn: ?PromptsFn = null,
prompts_buf: [MAX_PROMPTS]PromptStrip.Prompt = undefined,

pub fn open(self: *Self, seed_focus: bool) void {
    self.hovered = null;
    self.focused = if (seed_focus) self.first_focusable() else null;
    self.cancel_active_session();
    self.focus_source = if (seed_focus) .pad else .mouse;
    self.cancel_pressed = false;
}

fn cancel_active_session(self: *Self) void {
    if (self.active_input != null and self.session_started) {
        ae.Core.input.cancel_text() catch {};
    }
    self.active_input = null;
    self.session_started = false;
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

    // Nav keys still advance focus while a text input is active; typing
    // is delivered through the session, not these bindings. On PSP we
    // intentionally skip `sync_active_to_focus` so navigating across a
    // text input does not arm the modal OSK -- the OSK is only fired
    // when the user explicitly presses confirm (X / Cross).
    if (in.nav != .none) {
        self.focus_source = .pad;
        self.nav_advance(in.nav);
        if (ae.platform != .psp) self.sync_active_to_focus();
    }

    // Click: select the component under the cursor. For text inputs this
    // makes them the active input; for buttons it activates them.
    if (in.cursor_available and in.click_edge) {
        if (self.hover_pick(in.cursor_x, in.cursor_y)) |idx| {
            self.hovered = idx;
            self.focused = idx;
            self.focus_source = .mouse;
            if (self.components[idx] == .text_input) {
                self.set_active_input(idx);
            } else {
                self.cancel_active_session();
                self.activate(idx);
            }
            return;
        }
        // Clicked on empty space - deselect active input.
        self.cancel_active_session();
    }
    if (in.confirm_edge) {
        if (self.activation_target()) |idx| {
            if (self.components[idx] == .text_input) {
                self.focus_source = .pad;
                if (ae.platform == .psp) {
                    // Fire the modal OSK for the focused field. The PSP
                    // backend runs synchronously and writes the result
                    // back via `write_text_session_buffer`.
                    self.fire_psp_osk(idx);
                } else {
                    // Desktop: Enter advances focus; the active session
                    // is moved by `sync_active_to_focus`.
                    self.nav_advance(.down);
                    self.sync_active_to_focus();
                }
            } else {
                self.cancel_active_session();
                self.activate(idx);
            }
        }
    }

    // Mirror the active TextInputSession's buffer into the focused field.
    if (self.active_input) |idx| {
        switch (self.components[idx]) {
            .text_input => |ti| sync_session_to_field(ti),
            else => {},
        }
    }
}

/// After keyboard navigation moves focus, update active_input to match
/// if the new focus target is a text input (or clear it if not).
fn sync_active_to_focus(self: *Self) void {
    if (self.focused) |f| {
        if (self.components[f] == .text_input) {
            self.set_active_input(f);
        } else {
            self.cancel_active_session();
        }
    } else {
        self.cancel_active_session();
    }
}

/// Idempotent for the same idx; cancels any prior session and begins a
/// fresh one for the new field. Desktop only -- on PSP, focusing a text
/// input does not arm the OSK; that is deferred to `fire_psp_osk`.
fn set_active_input(self: *Self, idx: u8) void {
    if (self.active_input != null and self.active_input.? == idx and self.session_started) return;

    if (self.active_input != null and self.session_started) {
        ae.Core.input.cancel_text() catch {};
    }
    self.active_input = idx;
    self.session_started = false;

    if (ae.platform == .psp) return;

    const ti = switch (self.components[idx]) {
        .text_input => |t| t,
        else => return,
    };
    const target: ae.Core.input.TextInputTarget = .{ .id = ti.id };
    // Seed with existing field text so it survives the focus change.
    const opts: ae.Core.input.TextInputOptions = .{
        .max_bytes = ti.max_len,
        .initial = if (ti.len.* > 0) ti.buf[0..ti.len.*] else null,
    };
    _ = ae.Core.input.begin_text_input(target, opts) catch return;
    self.session_started = true;
}

/// PSP confirm path: fire the modal OSK for the focused text input. The
/// platform backend runs synchronously, so by the time `begin_text_input`
/// returns the session is already terminal. We mirror submitted output
/// into the field; on cancel the field is left untouched.
fn fire_psp_osk(self: *Self, idx: u8) void {
    const ti = switch (self.components[idx]) {
        .text_input => |t| t,
        else => return,
    };

    // Drop any leftover terminal session from a prior OSK invocation so
    // `begin_text_input` does not return TextSessionInFlight.
    if (ae.Core.input.current_text_session()) |s| {
        if (!s.is_terminal()) ae.Core.input.cancel_text() catch {};
    }

    const target: ae.Core.input.TextInputTarget = .{ .id = ti.id };
    // Seed the OSK with whatever's already in the field so re-edits begin
    // mid-text rather than blank.
    const opts: ae.Core.input.TextInputOptions = .{
        .max_bytes = ti.max_len,
        .initial = if (ti.len.* > 0) ti.buf[0..ti.len.*] else null,
    };
    _ = ae.Core.input.begin_text_input(target, opts) catch return;

    const session = ae.Core.input.current_text_session() orelse return;
    if (session.status == .submitted) {
        const take = @min(session.buffer.items.len, @as(usize, ti.max_len));
        if (take > 0) std.mem.copyForwards(u8, ti.buf[0..take], session.buffer.items[0..take]);
        ti.len.* = @intCast(take);
    }

    // The session is terminal; do not flag it as live so the per-frame
    // `sync_session_to_field` mirror does not overwrite the field.
    self.active_input = idx;
    self.session_started = false;
}

/// Mirror the active TextInputSession's buffer into the field's display
/// buffer, truncating to max_len. Called once per frame from `update`.
fn sync_session_to_field(ti: component.TextInput) void {
    const session = ae.Core.input.current_text_session() orelse return;
    const items = session.buffer.items;
    const take = @min(items.len, @as(usize, ti.max_len));
    if (take > 0) std.mem.copyForwards(u8, ti.buf[0..take], items[0..take]);
    ti.len.* = @intCast(take);
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
    self: *Self,
    sprites: *SpriteBatcher,
    fonts: *FontBatcher,
    gui_tex: *const Rendering.Texture,
    glyphs_tex: *const Rendering.Texture,
) void {
    if (self.draw_underlay) |draw_underlay| {
        draw_underlay(self.ctx, sprites, fonts, gui_tex);
    }
    for (self.components, 0..) |c, i| {
        const idx: u8 = @intCast(i);
        const active = self.active_input != null and self.active_input.? == idx;
        c.draw(sprites, fonts, gui_tex, self.is_highlighted(idx) or active, self.layer_base);
    }
    if (self.prompts_fn) |build_prompts| {
        if (PromptStrip.enabled()) {
            const slice = build_prompts(self.ctx, self.prompts_buf[0..]);
            // Slot sprite/text two/three layers above the deepest component
            // so prompts always sit on top of button art.
            PromptStrip.draw(
                slice,
                sprites,
                fonts,
                glyphs_tex,
                .bottom_left,
                PromptStrip.DEFAULT_POS_X,
                PromptStrip.DEFAULT_POS_Y,
                self.layer_base +| 2,
                self.layer_base +| 3,
            );
        }
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
