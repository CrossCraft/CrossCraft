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
const Buttons = @import("Buttons.zig");

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
    input_system: ?*input.InputSystem,
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

const Actions = struct {
    click: input.ActionHandle,
    confirm: input.ActionHandle,
    cancel: input.ActionHandle,
    pause: input.ActionHandle,
    inventory: input.ActionHandle,
    up: input.ActionHandle,
    down: input.ActionHandle,
    left: input.ActionHandle,
    right: input.ActionHandle,
};

const Runtime = struct {
    prev: Prev = .{},
    /// True iff menu_set owned the top context last frame. Suppresses a
    /// ghost rising edge on the frame menu_set activates with a binding
    /// already held (e.g. B from the gameplay press that pushed us here).
    was_active: bool = false,
    set: ?input.ActionSetHandle = null,
    actions: ?Actions = null,
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
pub fn ensure_registered(sys: *input.InputSystem) !void {
    if (runtime.set != null) return;
    const set = try sys.register_action_set("menu");

    const click = try sys.add_action(set, "ui_click", .button);
    try sys.bind_action(click, &.{ .source = .{ .mouse_button = .Left } });

    const confirm = try sys.add_action(set, "ui_confirm", .button);
    try sys.bind_action(confirm, &.{ .source = .{ .key = .Enter } });
    try sys.bind_action(confirm, &.{ .source = .{ .key = .Space } });
    try sys.bind_action(confirm, &.{ .source = .{ .gamepad_button = .A } });

    // Cancel = back. Keyboard B is intentionally not included: text fields
    // need to accept the letter 'b' without backing out of their screen.
    const cancel = try sys.add_action(set, "ui_cancel", .button);
    try sys.bind_action(cancel, &.{ .source = .{ .key = .Escape } });
    try sys.bind_action(cancel, &.{ .source = .{ .gamepad_button = .B } });
    try sys.bind_action(cancel, &.{ .source = .{ .gamepad_button = .Start } });

    // ui_pause is the in-game "open pause" trigger. Deliberately omits B so
    // pressing B (which opens inventory) cannot pause mid-gameplay.
    const pause = try sys.add_action(set, "ui_pause", .button);
    try sys.bind_action(pause, &.{ .source = .{ .key = .Escape } });
    try sys.bind_action(pause, &.{ .source = .{ .gamepad_button = .Start } });

    const inventory = try sys.add_action(set, "ui_inventory", .button);
    try bind_inventory(sys, inventory);

    const up = try sys.add_action(set, "ui_up", .button);
    try sys.bind_action(up, &.{ .source = .{ .key = .Up } });
    try sys.bind_action(up, &.{ .source = .{ .key = .W } });
    try sys.bind_action(up, &.{ .source = .{ .gamepad_button = .DpadUp } });
    // Stick up: LeftY is positive when pushed down on most pads, so flip.
    try sys.bind_action(up, &.{ .source = .{ .gamepad_axis = .LeftY }, .multiplier = -1.0 });

    const down = try sys.add_action(set, "ui_down", .button);
    try sys.bind_action(down, &.{ .source = .{ .key = .Down } });
    try sys.bind_action(down, &.{ .source = .{ .key = .S } });
    try sys.bind_action(down, &.{ .source = .{ .gamepad_button = .DpadDown } });
    try sys.bind_action(down, &.{ .source = .{ .gamepad_axis = .LeftY }, .multiplier = 1.0 });

    const left = try sys.add_action(set, "ui_left", .button);
    try sys.bind_action(left, &.{ .source = .{ .key = .Left } });
    try sys.bind_action(left, &.{ .source = .{ .key = .A } });
    try sys.bind_action(left, &.{ .source = .{ .gamepad_button = .DpadLeft } });
    try sys.bind_action(left, &.{ .source = .{ .gamepad_axis = .LeftX }, .multiplier = -1.0 });

    const right = try sys.add_action(set, "ui_right", .button);
    try sys.bind_action(right, &.{ .source = .{ .key = .Right } });
    try sys.bind_action(right, &.{ .source = .{ .key = .D } });
    try sys.bind_action(right, &.{ .source = .{ .gamepad_button = .DpadRight } });
    try sys.bind_action(right, &.{ .source = .{ .gamepad_axis = .LeftX }, .multiplier = 1.0 });

    try sys.install_action_set(set);
    runtime.set = set;
    runtime.actions = .{
        .click = click,
        .confirm = confirm,
        .cancel = cancel,
        .pause = pause,
        .inventory = inventory,
        .up = up,
        .down = down,
        .left = left,
        .right = right,
    };
}

pub fn apply_options(sys: *input.InputSystem) !void {
    const previous = runtime.set orelse return;
    runtime.set = null;
    errdefer runtime.set = previous;
    try ensure_registered(sys);
    try refresh_active_context(sys, previous);
}

pub fn menu_set() input.ActionSetHandle {
    return runtime.set.?;
}

fn bind_inventory(sys: *input.InputSystem, action: input.ActionHandle) !void {
    try sys.bind_action(action, &.{ .source = .{ .key = Options.current.key_inventory } });
    if (ae.platform != .psp) {
        try sys.bind_action(action, &.{ .source = .{ .gamepad_button = .Y } });
    }
}

fn refresh_active_context(sys: *input.InputSystem, previous: input.ActionSetHandle) !void {
    const set = runtime.set orelse return;
    const top = sys.stack_top() orelse return;
    if (top.actions != previous) return;
    var ctx = top.*;
    ctx.actions = set;
    _ = try sys.replace_top(&ctx);
}

/// Builds the per-frame UI snapshot. `dt` is in seconds. `repeat` is
/// caller-owned state that survives across frames; one instance per active
/// screen owner. When menu_set is not the top context all reads return
/// released/zero, yielding an effectively empty snapshot.
pub fn build_frame(sys: *input.InputSystem, dt: f32, repeat: *Repeat) UiInput {
    std.debug.assert(dt >= 0);
    Buttons.note_input_mode(sys.last_input_mode());

    const cursor = read_cursor(sys);
    const moved = cursor.x != runtime.prev_cursor_x or cursor.y != runtime.prev_cursor_y;
    runtime.prev_cursor_x = cursor.x;
    runtime.prev_cursor_y = cursor.y;

    const actions = runtime.actions.?;
    const click = sys.button(actions.click).current;
    const confirm = sys.button(actions.confirm).current;
    const cancel = sys.button(actions.cancel).current;
    const pause = sys.button(actions.pause).current;
    const inventory = sys.button(actions.inventory).current;

    const active_now = is_menu_set_active(sys);

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
        sys.button(actions.up).pressed(),
        sys.button(actions.down).pressed(),
        sys.button(actions.left).pressed(),
        sys.button(actions.right).pressed(),
    };
    const nav = resolve_nav(held, dt, repeat);

    return .{
        .input_system = sys,
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
        .wheel_dy = if (profile_uses_pointer() and !fresh_activation) read_wheel_dy(sys) else 0,
        .text_events = true,
    };
}

/// Accumulate fractional trackpad deltas and floor toward zero so a slow
/// scroll still registers a notch eventually.
fn read_wheel_dy(sys: *input.InputSystem) i8 {
    for (sys.frame_events()) |ev| {
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

fn is_menu_set_active(sys: *input.InputSystem) bool {
    const top = sys.stack_top() orelse return false;
    const set = runtime.set orelse return false;
    return @intFromEnum(top.actions) == @intFromEnum(set);
}

const Cursor = struct { x: i16, y: i16 };

fn read_cursor(sys: *input.InputSystem) Cursor {
    if (!profile_uses_pointer()) return .{ .x = -1, .y = -1 };

    const screen_w = Rendering.gfx.surface.get_width();
    const screen_h = Rendering.gfx.surface.get_height();
    const scale = Scaling.compute(screen_w, screen_h);

    const p = sys.frame_pointer().position;
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
