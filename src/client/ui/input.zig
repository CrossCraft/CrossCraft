/// Per-frame UI input snapshot, fed by Aether action callbacks.
///
/// Aether's action system delivers `pressed`/`released` events on state change.
/// We mirror those into a module-static `pending` struct, then `build_frame`
/// folds them into a `UiInput` snapshot the screen consumes once per frame.
///
/// Held-direction autorepeat lives here so every screen gets the same cadence
/// without re-implementing it.
const std = @import("std");
const ae = @import("aether");
const Rendering = ae.Rendering;
const input = ae.Core.input;

const Scaling = @import("Scaling.zig");

pub const NavDir = enum(u8) { none, up, down, left, right };
pub const InputProfile = enum {
    pointer_and_pad,
    pad_only,
};

/// First-press to autorepeat-start delay (seconds).
const REPEAT_DELAY: f32 = 0.4;
/// Repeat interval after delay elapses (seconds).
const REPEAT_RATE: f32 = 0.08;

pub const Repeat = struct {
    /// Order: up, down, left, right.
    timers: [4]f32 = .{ 0, 0, 0, 0 },
    fired_first: [4]bool = .{ false, false, false, false },
    bs_timer: f32 = 0,
    bs_fired_first: bool = false,
};

pub const CHAR_BUF_CAP = 8;

pub const UiInput = struct {
    cursor_x: i16,
    cursor_y: i16,
    cursor_available: bool,
    cursor_moved: bool,
    click_edge: bool,
    nav: NavDir,
    confirm_edge: bool,
    /// In-menu "go back" — bound to keyboard Escape and gamepad B/Start.
    cancel_edge: bool,
    /// In-game "open pause menu" — keyboard Escape and gamepad Start only.
    /// Distinct from cancel so the gamepad B/Circle button (which doubles as a
    /// movement key on PSP) does not toggle pause from gameplay.
    pause_edge: bool,
    /// Characters typed this frame (for text input fields).
    char_buf: [CHAR_BUF_CAP]u8,
    char_count: u8,
    /// Backspace fired this frame (with autorepeat).
    backspace: bool,
};

/// Module-static pending edge/held flags written by Aether action callbacks.
const Pending = struct {
    click_edge: bool = false,
    confirm_edge: bool = false,
    cancel_edge: bool = false,
    pause_edge: bool = false,
    held_up: bool = false,
    held_down: bool = false,
    held_left: bool = false,
    held_right: bool = false,
    held_backspace: bool = false,
    char_buf: [CHAR_BUF_CAP]u8 = .{0} ** CHAR_BUF_CAP,
    char_count: u8 = 0,
    /// Latest cursor position from the ui_cursor vector2 action, in absolute
    /// normalized coords [0..1, 0..1] with Y already top-down (the source
    /// `mouse_relative` axes are Y-flipped in Aether's absolute mode, so the
    /// callback re-flips before storing).
    cursor_norm_x: f32 = 0.0,
    cursor_norm_y: f32 = 0.0,
};

const Runtime = struct {
    pending: Pending = .{},
    registered: bool = false,
    profile: InputProfile = .pointer_and_pad,
    prev_cursor_x: i16 = std.math.minInt(i16),
    prev_cursor_y: i16 = std.math.minInt(i16),
};
var runtime: Runtime = .{};

pub fn default_profile() InputProfile {
    return if (ae.gfx == .headless or ae.platform == .psp)
        .pad_only
    else
        .pointer_and_pad;
}

pub fn set_profile(profile: InputProfile) void {
    runtime.profile = profile;
    runtime.prev_cursor_x = std.math.minInt(i16);
    runtime.prev_cursor_y = std.math.minInt(i16);
}

pub fn profile_uses_pointer() bool {
    return runtime.profile == .pointer_and_pad;
}

/// Idempotent: registers all UI actions and binds them. Safe to call from
/// multiple state inits.
pub fn ensure_registered() !void {
    if (runtime.registered) return;

    try input.register_action("ui_click", .button);
    try input.bind_action("ui_click", .{ .source = .{ .mouse_button = .Left } });
    try input.add_button_callback("ui_click", &runtime.pending, on_click);

    try input.register_action("ui_confirm", .button);
    try input.bind_action("ui_confirm", .{ .source = .{ .key = .Enter } });
    try input.bind_action("ui_confirm", .{ .source = .{ .key = .Space } });
    try input.bind_action("ui_confirm", .{ .source = .{ .gamepad_button = .A } });
    try input.add_button_callback("ui_confirm", &runtime.pending, on_confirm);

    try input.register_action("ui_cancel", .button);
    try input.bind_action("ui_cancel", .{ .source = .{ .key = .Escape } });
    try input.bind_action("ui_cancel", .{ .source = .{ .gamepad_button = .B } });
    try input.bind_action("ui_cancel", .{ .source = .{ .gamepad_button = .Start } });
    try input.add_button_callback("ui_cancel", &runtime.pending, on_cancel);

    // ui_pause is the in-game "open pause" trigger. Deliberately omits B so
    // PSP Circle (also a strafe-right key) cannot pause mid-gameplay.
    try input.register_action("ui_pause", .button);
    try input.bind_action("ui_pause", .{ .source = .{ .key = .Escape } });
    try input.bind_action("ui_pause", .{ .source = .{ .gamepad_button = .Start } });
    try input.add_button_callback("ui_pause", &runtime.pending, on_pause);

    try input.register_action("ui_up", .button);
    try input.bind_action("ui_up", .{ .source = .{ .key = .Up } });
    try input.bind_action("ui_up", .{ .source = .{ .key = .W } });
    try input.bind_action("ui_up", .{ .source = .{ .gamepad_button = .DpadUp } });
    // Stick up: LeftY is positive when pushed down on most pads, so flip.
    try input.bind_action("ui_up", .{ .source = .{ .gamepad_axis = .LeftY }, .multiplier = -1.0 });
    try input.add_button_callback("ui_up", &runtime.pending, on_up);

    try input.register_action("ui_down", .button);
    try input.bind_action("ui_down", .{ .source = .{ .key = .Down } });
    try input.bind_action("ui_down", .{ .source = .{ .key = .S } });
    try input.bind_action("ui_down", .{ .source = .{ .gamepad_button = .DpadDown } });
    try input.bind_action("ui_down", .{ .source = .{ .gamepad_axis = .LeftY }, .multiplier = 1.0 });
    try input.add_button_callback("ui_down", &runtime.pending, on_down);

    try input.register_action("ui_left", .button);
    try input.bind_action("ui_left", .{ .source = .{ .key = .Left } });
    try input.bind_action("ui_left", .{ .source = .{ .key = .A } });
    try input.bind_action("ui_left", .{ .source = .{ .gamepad_button = .DpadLeft } });
    try input.bind_action("ui_left", .{ .source = .{ .gamepad_axis = .LeftX }, .multiplier = -1.0 });
    try input.add_button_callback("ui_left", &runtime.pending, on_left);

    try input.register_action("ui_right", .button);
    try input.bind_action("ui_right", .{ .source = .{ .key = .Right } });
    try input.bind_action("ui_right", .{ .source = .{ .key = .D } });
    try input.bind_action("ui_right", .{ .source = .{ .gamepad_button = .DpadRight } });
    try input.bind_action("ui_right", .{ .source = .{ .gamepad_axis = .LeftX }, .multiplier = 1.0 });
    try input.add_button_callback("ui_right", &runtime.pending, on_right);

    // Cursor: Aether's mouse_relative axes return absolute normalized coords
    // when relative mode is disabled (the menu's default). The Y axis returns
    // (h - cursor_y)/h, i.e. bottom-origin; we re-flip in the callback.
    try input.register_action("ui_cursor", .vector2);
    try input.bind_action("ui_cursor", .{ .source = .{ .mouse_relative = .X }, .component = .x });
    try input.bind_action("ui_cursor", .{ .source = .{ .mouse_relative = .Y }, .component = .y });
    try input.add_vector2_callback("ui_cursor", &runtime.pending, on_cursor);

    // Text-input character keys and backspace.
    try register_char_keys();
    try input.register_action("tc_bs", .button);
    try input.bind_action("tc_bs", .{ .source = .{ .key = .Backspace } });
    try input.add_button_callback("tc_bs", &runtime.pending, on_backspace);

    runtime.registered = true;
}

/// Key-to-character mapping for text input fields.
const CharBinding = struct { key: input.Key, char: u8 };
const char_bindings = [_]CharBinding{
    .{ .key = .A, .char = 'a' },
    .{ .key = .B, .char = 'b' },
    .{ .key = .C, .char = 'c' },
    .{ .key = .D, .char = 'd' },
    .{ .key = .E, .char = 'e' },
    .{ .key = .F, .char = 'f' },
    .{ .key = .G, .char = 'g' },
    .{ .key = .H, .char = 'h' },
    .{ .key = .I, .char = 'i' },
    .{ .key = .J, .char = 'j' },
    .{ .key = .K, .char = 'k' },
    .{ .key = .L, .char = 'l' },
    .{ .key = .M, .char = 'm' },
    .{ .key = .N, .char = 'n' },
    .{ .key = .O, .char = 'o' },
    .{ .key = .P, .char = 'p' },
    .{ .key = .Q, .char = 'q' },
    .{ .key = .R, .char = 'r' },
    .{ .key = .S, .char = 's' },
    .{ .key = .T, .char = 't' },
    .{ .key = .U, .char = 'u' },
    .{ .key = .V, .char = 'v' },
    .{ .key = .W, .char = 'w' },
    .{ .key = .X, .char = 'x' },
    .{ .key = .Y, .char = 'y' },
    .{ .key = .Z, .char = 'z' },
    .{ .key = .Num0, .char = '0' },
    .{ .key = .Num1, .char = '1' },
    .{ .key = .Num2, .char = '2' },
    .{ .key = .Num3, .char = '3' },
    .{ .key = .Num4, .char = '4' },
    .{ .key = .Num5, .char = '5' },
    .{ .key = .Num6, .char = '6' },
    .{ .key = .Num7, .char = '7' },
    .{ .key = .Num8, .char = '8' },
    .{ .key = .Num9, .char = '9' },
    .{ .key = .Period, .char = '.' },
    .{ .key = .Minus, .char = '-' },
    .{ .key = .Semicolon, .char = ':' },
};

fn char_handler(comptime ch: u8) input.ButtonCallback {
    return struct {
        fn handle(_: *anyopaque, ev: input.ButtonEvent) void {
            if (ev == .pressed) push_char(ch);
        }
    }.handle;
}

fn push_char(ch: u8) void {
    if (runtime.pending.char_count < CHAR_BUF_CAP) {
        runtime.pending.char_buf[runtime.pending.char_count] = ch;
        runtime.pending.char_count += 1;
    }
}

fn register_char_keys() !void {
    @setEvalBranchQuota(10_000);
    inline for (char_bindings) |cb| {
        const name = comptime std.fmt.comptimePrint("tc_{d}", .{@intFromEnum(cb.key)});
        try input.register_action(name, .button);
        try input.bind_action(name, .{ .source = .{ .key = cb.key } });
        try input.add_button_callback(name, &runtime.pending, char_handler(cb.char));
    }
}

fn on_backspace(_: *anyopaque, ev: input.ButtonEvent) void {
    runtime.pending.held_backspace = ev == .pressed;
}

fn on_click(_: *anyopaque, ev: input.ButtonEvent) void {
    if (ev == .pressed) runtime.pending.click_edge = true;
}
fn on_confirm(_: *anyopaque, ev: input.ButtonEvent) void {
    if (ev == .pressed) runtime.pending.confirm_edge = true;
}
fn on_cancel(_: *anyopaque, ev: input.ButtonEvent) void {
    if (ev == .pressed) runtime.pending.cancel_edge = true;
}
fn on_pause(_: *anyopaque, ev: input.ButtonEvent) void {
    if (ev == .pressed) runtime.pending.pause_edge = true;
}
fn on_up(_: *anyopaque, ev: input.ButtonEvent) void {
    runtime.pending.held_up = ev == .pressed;
}
fn on_down(_: *anyopaque, ev: input.ButtonEvent) void {
    runtime.pending.held_down = ev == .pressed;
}
fn on_left(_: *anyopaque, ev: input.ButtonEvent) void {
    runtime.pending.held_left = ev == .pressed;
}
fn on_right(_: *anyopaque, ev: input.ButtonEvent) void {
    runtime.pending.held_right = ev == .pressed;
}
fn on_cursor(_: *anyopaque, value: [2]f32) void {
    runtime.pending.cursor_norm_x = value[0];
    runtime.pending.cursor_norm_y = 1.0 - value[1];
}

/// Builds the per-frame snapshot. `dt` is in seconds. `repeat` is caller-owned
/// state that survives across frames; one instance per active screen owner is
/// fine (a screen sees its own autorepeat cadence).
pub fn build_frame(dt: f32, repeat: *Repeat) UiInput {
    std.debug.assert(dt >= 0);

    const cursor = read_cursor();
    const moved = cursor.x != runtime.prev_cursor_x or cursor.y != runtime.prev_cursor_y;
    runtime.prev_cursor_x = cursor.x;
    runtime.prev_cursor_y = cursor.y;

    const held = [4]bool{
        runtime.pending.held_up, runtime.pending.held_down, runtime.pending.held_left, runtime.pending.held_right,
    };
    const nav = resolve_nav(held, dt, repeat);

    const backspace = resolve_backspace(runtime.pending.held_backspace, dt, repeat);

    const snap = UiInput{
        .cursor_x = cursor.x,
        .cursor_y = cursor.y,
        .cursor_available = profile_uses_pointer(),
        .cursor_moved = moved,
        .click_edge = runtime.pending.click_edge,
        .nav = nav,
        .confirm_edge = runtime.pending.confirm_edge,
        .cancel_edge = runtime.pending.cancel_edge,
        .pause_edge = runtime.pending.pause_edge,
        .char_buf = runtime.pending.char_buf,
        .char_count = runtime.pending.char_count,
        .backspace = backspace,
    };

    runtime.pending.click_edge = false;
    runtime.pending.confirm_edge = false;
    runtime.pending.cancel_edge = false;
    runtime.pending.pause_edge = false;
    runtime.pending.char_count = 0;
    return snap;
}

const Cursor = struct { x: i16, y: i16 };

fn read_cursor() Cursor {
    // Controller-only UI profiles do not participate in hover/click hit-tests.
    if (!profile_uses_pointer()) return .{ .x = -1, .y = -1 };

    const screen_w = Rendering.gfx.surface.get_width();
    const screen_h = Rendering.gfx.surface.get_height();
    const scale = Scaling.compute(screen_w, screen_h);
    const sw_f: f32 = @floatFromInt(screen_w);
    const sh_f: f32 = @floatFromInt(screen_h);

    const px_f: f32 = runtime.pending.cursor_norm_x * sw_f;
    const py_f: f32 = runtime.pending.cursor_norm_y * sh_f;
    const lx: i32 = @intFromFloat(px_f / @as(f32, @floatFromInt(scale)));
    const ly: i32 = @intFromFloat(py_f / @as(f32, @floatFromInt(scale)));
    return .{
        .x = @intCast(std.math.clamp(lx, std.math.minInt(i16), std.math.maxInt(i16))),
        .y = @intCast(std.math.clamp(ly, std.math.minInt(i16), std.math.maxInt(i16))),
    };
}

/// Resolves the four held flags into at most one autorepeat-fired direction.
/// Up takes priority over Down, Left over Right (matches typical menu UX).
fn resolve_nav(held: [4]bool, dt: f32, repeat: *Repeat) NavDir {
    const dirs = [_]NavDir{ .up, .down, .left, .right };
    var fired: NavDir = .none;
    for (held, 0..) |is_held, i| {
        if (!is_held) {
            repeat.timers[i] = 0;
            repeat.fired_first[i] = false;
            continue;
        }
        if (!repeat.fired_first[i]) {
            repeat.fired_first[i] = true;
            repeat.timers[i] = 0;
            if (fired == .none) fired = dirs[i];
            continue;
        }
        repeat.timers[i] += dt;
        const threshold: f32 = REPEAT_DELAY + REPEAT_RATE;
        if (repeat.timers[i] >= threshold) {
            repeat.timers[i] -= REPEAT_RATE;
            if (fired == .none) fired = dirs[i];
        }
    }
    return fired;
}

fn resolve_backspace(held: bool, dt: f32, repeat: *Repeat) bool {
    if (!held) {
        repeat.bs_timer = 0;
        repeat.bs_fired_first = false;
        return false;
    }
    if (!repeat.bs_fired_first) {
        repeat.bs_fired_first = true;
        repeat.bs_timer = 0;
        return true;
    }
    repeat.bs_timer += dt;
    const threshold: f32 = REPEAT_DELAY + REPEAT_RATE;
    if (repeat.bs_timer >= threshold) {
        repeat.bs_timer -= REPEAT_RATE;
        return true;
    }
    return false;
}
