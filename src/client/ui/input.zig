/// Per-frame UI input snapshot, fed by polling Aether's menu ActionSet.
///
/// Owns the menu ActionSet (registered once at first call, installed
/// for the process lifetime). Pause, inventory, and the title-menu
/// hierarchy all push contexts that reference this set.
///
/// Text-character routing is owned by Aether's TextInputSession --
/// `Screen.zig` and `Chat.zig` start sessions when they need text and
/// read the populated buffer back. There is no per-key char binding
/// here.
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
};

pub const UiInput = struct {
    cursor_x: i16,
    cursor_y: i16,
    cursor_available: bool,
    cursor_moved: bool,
    click_edge: bool,
    nav: NavDir,
    confirm_edge: bool,
    /// In-menu "go back" - bound to keyboard Escape, B, and gamepad B/Start.
    cancel_edge: bool,
    /// In-game "open pause menu" - keyboard Escape and gamepad Start only.
    /// Distinct from cancel so the gamepad B / keyboard B (which doubles as
    /// the inventory-open key) does not toggle pause from gameplay.
    pause_edge: bool,
};

/// Module-static prev-state used for rising-edge detection on the menu
/// action set. Held flags are read directly each frame via get_action_*.
const Prev = struct {
    click: input.ButtonState = .released,
    confirm: input.ButtonState = .released,
    cancel: input.ButtonState = .released,
    pause: input.ButtonState = .released,
};

const Runtime = struct {
    prev: Prev = .{},
    /// True iff menu_set was the top context's action set at the end of
    /// the previous build_frame call. Used to suppress ghost rising
    /// edges on the frame the menu set first becomes active with a
    /// binding (e.g. keyboard B for ui_cancel) already held from the
    /// gameplay-set press that triggered the context push.
    was_active: bool = false,
    set: ?input.ActionSetHandle = null,
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

/// Idempotent: registers the menu ActionSet on first call and returns the
/// handle. The set persists for the lifetime of the process; subsequent
/// state transitions push a context referencing it.
pub fn ensure_registered() !void {
    if (runtime.set != null) return;
    const set = try input.register_action_set("menu");

    try input.add_action(set, "ui_click", .button);
    try input.bind_action(set, "ui_click", .{ .source = .{ .mouse_button = .Left } });

    try input.add_action(set, "ui_confirm", .button);
    try input.bind_action(set, "ui_confirm", .{ .source = .{ .key = .Enter } });
    try input.bind_action(set, "ui_confirm", .{ .source = .{ .key = .Space } });
    try input.bind_action(set, "ui_confirm", .{ .source = .{ .gamepad_button = .A } });

    // Cancel = back. Keyboard B is included so the same key that opens the
    // inventory overlay also closes it from the inventory's own update path.
    try input.add_action(set, "ui_cancel", .button);
    try input.bind_action(set, "ui_cancel", .{ .source = .{ .key = .Escape } });
    try input.bind_action(set, "ui_cancel", .{ .source = .{ .key = .B } });
    try input.bind_action(set, "ui_cancel", .{ .source = .{ .gamepad_button = .B } });
    try input.bind_action(set, "ui_cancel", .{ .source = .{ .gamepad_button = .Start } });

    // ui_pause is the in-game "open pause" trigger. Deliberately omits B so
    // pressing B (which opens inventory) cannot pause mid-gameplay.
    try input.add_action(set, "ui_pause", .button);
    try input.bind_action(set, "ui_pause", .{ .source = .{ .key = .Escape } });
    try input.bind_action(set, "ui_pause", .{ .source = .{ .gamepad_button = .Start } });

    try input.add_action(set, "ui_up", .button);
    try input.bind_action(set, "ui_up", .{ .source = .{ .key = .Up } });
    try input.bind_action(set, "ui_up", .{ .source = .{ .key = .W } });
    try input.bind_action(set, "ui_up", .{ .source = .{ .gamepad_button = .DpadUp } });
    // Stick up: LeftY is positive when pushed down on most pads, so flip.
    try input.bind_action(set, "ui_up", .{ .source = .{ .gamepad_axis = .LeftY }, .multiplier = -1.0 });

    try input.add_action(set, "ui_down", .button);
    try input.bind_action(set, "ui_down", .{ .source = .{ .key = .Down } });
    try input.bind_action(set, "ui_down", .{ .source = .{ .key = .S } });
    try input.bind_action(set, "ui_down", .{ .source = .{ .gamepad_button = .DpadDown } });
    try input.bind_action(set, "ui_down", .{ .source = .{ .gamepad_axis = .LeftY }, .multiplier = 1.0 });

    try input.add_action(set, "ui_left", .button);
    try input.bind_action(set, "ui_left", .{ .source = .{ .key = .Left } });
    try input.bind_action(set, "ui_left", .{ .source = .{ .key = .A } });
    try input.bind_action(set, "ui_left", .{ .source = .{ .gamepad_button = .DpadLeft } });
    try input.bind_action(set, "ui_left", .{ .source = .{ .gamepad_axis = .LeftX }, .multiplier = -1.0 });

    try input.add_action(set, "ui_right", .button);
    try input.bind_action(set, "ui_right", .{ .source = .{ .key = .Right } });
    try input.bind_action(set, "ui_right", .{ .source = .{ .key = .D } });
    try input.bind_action(set, "ui_right", .{ .source = .{ .gamepad_button = .DpadRight } });
    try input.bind_action(set, "ui_right", .{ .source = .{ .gamepad_axis = .LeftX }, .multiplier = 1.0 });

    try input.install_action_set(set);
    runtime.set = set;
}

pub fn menu_set() input.ActionSetHandle {
    return runtime.set.?;
}

/// Builds the per-frame UI snapshot. `dt` is in seconds. `repeat` is
/// caller-owned state that survives across frames; one instance per active
/// screen owner.
///
/// Reads the menu ActionSet via Aether's polling API. When the active
/// context's ActionSet is not menu_set (e.g. gameplay or chat is on top),
/// every read returns the released / zero default and the snapshot is
/// effectively empty -- exactly what we want for a UI poll fired from a
/// state that does not currently own input.
pub fn build_frame(dt: f32, repeat: *Repeat) UiInput {
    std.debug.assert(dt >= 0);

    const cursor = read_cursor();
    const moved = cursor.x != runtime.prev_cursor_x or cursor.y != runtime.prev_cursor_y;
    runtime.prev_cursor_x = cursor.x;
    runtime.prev_cursor_y = cursor.y;

    const click = input.get_action_button("ui_click");
    const confirm = input.get_action_button("ui_confirm");
    const cancel = input.get_action_button("ui_cancel");
    const pause = input.get_action_button("ui_pause");

    const active_now = is_menu_set_active();

    // On the activation frame, seed prev := current so a binding that was
    // already held when the context switched in does not fire a spurious
    // rising edge. Also do this when menu_set was inactive last frame
    // even if it still isn't active now -- the masked .released values
    // would have written into prev otherwise, leaking next-frame edges.
    const fresh_activation = active_now and !runtime.was_active;
    runtime.was_active = active_now;

    const click_edge = !fresh_activation and rising_edge(runtime.prev.click, click);
    const confirm_edge = !fresh_activation and rising_edge(runtime.prev.confirm, confirm);
    const cancel_edge = !fresh_activation and rising_edge(runtime.prev.cancel, cancel);
    const pause_edge = !fresh_activation and rising_edge(runtime.prev.pause, pause);

    runtime.prev.click = click;
    runtime.prev.confirm = confirm;
    runtime.prev.cancel = cancel;
    runtime.prev.pause = pause;

    const held = [4]bool{
        input.get_action_button("ui_up") == .pressed,
        input.get_action_button("ui_down") == .pressed,
        input.get_action_button("ui_left") == .pressed,
        input.get_action_button("ui_right") == .pressed,
    };
    const nav = resolve_nav(held, dt, repeat);

    return .{
        .cursor_x = cursor.x,
        .cursor_y = cursor.y,
        .cursor_available = profile_uses_pointer(),
        .cursor_moved = moved,
        .click_edge = click_edge,
        .nav = nav,
        .confirm_edge = confirm_edge,
        .cancel_edge = cancel_edge,
        .pause_edge = pause_edge,
    };
}

fn rising_edge(prev: input.ButtonState, cur: input.ButtonState) bool {
    return prev == .released and cur == .pressed;
}

fn is_menu_set_active() bool {
    const top = input.stack_top() orelse return false;
    const set = runtime.set orelse return false;
    return @intFromEnum(top.actions) == @intFromEnum(set);
}

const Cursor = struct { x: i16, y: i16 };

/// Pointer position from Aether's frame pointer (absolute screen pixels,
/// top-origin), scaled to logical UI coordinates. Returns sentinel (-1,-1)
/// for controller-only profiles so hover/hit tests are skipped.
fn read_cursor() Cursor {
    if (!profile_uses_pointer()) return .{ .x = -1, .y = -1 };

    const screen_w = Rendering.gfx.surface.get_width();
    const screen_h = Rendering.gfx.surface.get_height();
    const scale = Scaling.compute(screen_w, screen_h);

    const p = input.frame_pointer().position;
    const lx: i32 = @intFromFloat(p.x / @as(f32, @floatFromInt(scale)));
    const ly: i32 = @intFromFloat(p.y / @as(f32, @floatFromInt(scale)));
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
