/// Per-frame UI input snapshot polled from the menu ActionSet. Pause,
/// inventory, and the title-menu hierarchy all push contexts referencing
/// this set. Text input is routed through TextInputSession instead of
/// per-key char bindings.
const std = @import("std");
const ae = @import("aether");
const Rendering = ae.Rendering;
const input = ae.Core.input;

const Options = @import("../Options.zig");
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
    /// True while ui_click is held; distinct from the rising edge so sliders
    /// and scrollbars can read ongoing pointer state.
    click_held: bool,
    nav: NavDir,
    confirm_edge: bool,
    /// In-menu "back" - Escape, B, gamepad B/Start.
    cancel_edge: bool,
    /// In-game pause - Escape and gamepad Start only; excludes B so the
    /// inventory key cannot pause mid-gameplay.
    pause_edge: bool,
    /// Inventory toggle while a UI overlay owns input. This lets the same
    /// keyboard/gamepad binding close inventory without making B a global
    /// text-screen cancel key.
    inventory_edge: bool,
    /// Vertical wheel notches this frame. Positive scrolls content upward
    /// (GLFW convention). Zero when `cursor_available` is false.
    wheel_dy: i8,
    /// True on the update-side frame. Draw-only UI replays set this false so
    /// text sessions do not process the same raw key events twice.
    text_events: bool,
};

/// Previous-frame button state for rising-edge detection.
const Prev = struct {
    click: input.ButtonState = .released,
    confirm: input.ButtonState = .released,
    cancel: input.ButtonState = .released,
    pause: input.ButtonState = .released,
    inventory: input.ButtonState = .released,
};

const Runtime = struct {
    prev: Prev = .{},
    /// True iff menu_set owned the top context last frame. Suppresses a
    /// ghost rising edge on the frame menu_set activates with a binding
    /// already held (e.g. B from the gameplay press that pushed us here).
    was_active: bool = false,
    set: ?input.ActionSetHandle = null,
    profile: InputProfile = .pointer_and_pad,
    prev_cursor_x: i16 = std.math.minInt(i16),
    prev_cursor_y: i16 = std.math.minInt(i16),
    wheel_acc: f32 = 0,
};
var runtime: Runtime = .{};

pub fn default_profile() InputProfile {
    return if (ae.gfx == .headless or ae.platform == .psp or ae.platform == .nintendo_3ds)
        .pad_only
    else
        .pointer_and_pad;
}

pub fn set_profile(profile: InputProfile) void {
    runtime.profile = profile;
    runtime.prev_cursor_x = std.math.minInt(i16);
    runtime.prev_cursor_y = std.math.minInt(i16);
    runtime.wheel_acc = 0;
}

pub fn profile_uses_pointer() bool {
    return runtime.profile == .pointer_and_pad;
}

pub fn seed_focus_on_open() bool {
    return !profile_uses_pointer() or ae.platform == .nintendo_3ds or ae.platform == .nintendo_switch;
}

/// Idempotent: registers and installs the menu ActionSet on first call.
/// The set persists for the lifetime of the process.
pub fn ensure_registered() !void {
    if (runtime.set != null) return;
    const set = try input.register_action_set("menu");

    try input.add_action(set, "ui_click", .button);
    try input.bind_action(set, "ui_click", .{ .source = .{ .mouse_button = .Left } });

    try input.add_action(set, "ui_confirm", .button);
    try input.bind_action(set, "ui_confirm", .{ .source = .{ .key = .Enter } });
    try input.bind_action(set, "ui_confirm", .{ .source = .{ .key = .Space } });
    try input.bind_action(set, "ui_confirm", .{ .source = .{ .gamepad_button = .A } });

    // Cancel = back. Keyboard B is intentionally not included: text fields
    // need to accept the letter 'b' without backing out of their screen.
    try input.add_action(set, "ui_cancel", .button);
    try input.bind_action(set, "ui_cancel", .{ .source = .{ .key = .Escape } });
    try input.bind_action(set, "ui_cancel", .{ .source = .{ .gamepad_button = .B } });
    try input.bind_action(set, "ui_cancel", .{ .source = .{ .gamepad_button = .Start } });

    // ui_pause is the in-game "open pause" trigger. Deliberately omits B so
    // pressing B (which opens inventory) cannot pause mid-gameplay.
    try input.add_action(set, "ui_pause", .button);
    try input.bind_action(set, "ui_pause", .{ .source = .{ .key = .Escape } });
    try input.bind_action(set, "ui_pause", .{ .source = .{ .gamepad_button = .Start } });

    try input.add_action(set, "ui_inventory", .button);
    try bind_inventory(set);

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

pub fn apply_options() !void {
    const previous = runtime.set orelse return;
    runtime.set = null;
    errdefer runtime.set = previous;
    try ensure_registered();
    try refresh_active_context(previous);
}

pub fn menu_set() input.ActionSetHandle {
    return runtime.set.?;
}

fn bind_inventory(set: input.ActionSetHandle) !void {
    try input.bind_action(set, "ui_inventory", .{ .source = .{ .key = Options.current.key_inventory } });
    if (ae.platform != .psp) {
        try input.bind_action(set, "ui_inventory", .{ .source = .{ .gamepad_button = .Y } });
    }
}

fn refresh_active_context(previous: input.ActionSetHandle) !void {
    const set = runtime.set orelse return;
    const top = input.stack_top() orelse return;
    if (top.actions != previous) return;
    var ctx = top.*;
    ctx.actions = set;
    _ = try input.replace_top(ctx);
}

/// Builds the per-frame UI snapshot. `dt` is in seconds. `repeat` is
/// caller-owned state that survives across frames; one instance per active
/// screen owner. When menu_set is not the top context all reads return
/// released/zero, yielding an effectively empty snapshot.
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
    const inventory = input.get_action_button("ui_inventory");

    const active_now = is_menu_set_active();

    // Seed prev := current on activation so already-held bindings do not
    // fire a spurious rising edge.
    const fresh_activation = active_now and !runtime.was_active;
    runtime.was_active = active_now;

    const click_edge = !fresh_activation and rising_edge(runtime.prev.click, click);
    const confirm_edge = !fresh_activation and rising_edge(runtime.prev.confirm, confirm);
    const cancel_edge = !fresh_activation and rising_edge(runtime.prev.cancel, cancel);
    const pause_edge = !fresh_activation and rising_edge(runtime.prev.pause, pause);
    const inventory_edge = !fresh_activation and rising_edge(runtime.prev.inventory, inventory);

    runtime.prev.click = click;
    runtime.prev.confirm = confirm;
    runtime.prev.cancel = cancel;
    runtime.prev.pause = pause;
    runtime.prev.inventory = inventory;

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
        .click_held = !fresh_activation and click == .pressed,
        .nav = nav,
        .confirm_edge = confirm_edge,
        .cancel_edge = cancel_edge,
        .pause_edge = pause_edge,
        .inventory_edge = inventory_edge,
        .wheel_dy = if (profile_uses_pointer() and !fresh_activation) read_wheel_dy() else 0,
        .text_events = true,
    };
}

/// Accumulate fractional trackpad deltas and floor toward zero so a slow
/// scroll still registers a notch eventually.
fn read_wheel_dy() i8 {
    for (input.frame_events()) |ev| {
        switch (ev.kind) {
            .mouse_wheel => |w| runtime.wheel_acc += w.delta.y,
            else => {},
        }
    }
    if (runtime.wheel_acc == 0) return 0;
    const whole: i32 = @intFromFloat(if (runtime.wheel_acc > 0) @floor(runtime.wheel_acc) else @ceil(runtime.wheel_acc));
    if (whole == 0) return 0;
    const emitted = std.math.clamp(whole, -127, 127);
    runtime.wheel_acc -= @floatFromInt(emitted);
    return @intCast(emitted);
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
        if (repeat.timers[i] >= REPEAT_DELAY) {
            repeat.timers[i] -= REPEAT_RATE;
            if (fired == .none) fired = dirs[i];
        }
    }
    return fired;
}
