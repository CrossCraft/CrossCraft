const std = @import("std");
const assert = std.debug.assert;
const ae = @import("aether");
const caps = @import("capabilities").ClientType(ae);
const Rendering = ae.Rendering;
const input = ae.Core.input;

const Options = @import("../Options.zig");
const Scaling = ae.Ui.Scaling;
const Buttons = @import("Buttons.zig");

pub const NavDir = enum(u8) { none, up, down, left, right };
pub const InputProfile = enum {
    pointer_and_pad,
    pad_only,
};

const RepeatDelay: f32 = 0.4;
const RepeatRate: f32 = 0.08;

pub const Repeat = struct {
    direction: NavDir = .none,
    timer: f32 = 0,
};

pub const UiInput = struct {
    input_system: ?*input.InputSystem = null,
    cursor_x: i16 = 0,
    cursor_y: i16 = 0,
    cursor_available: bool = false,
    cursor_moved: bool = false,
    click_edge: bool = false,
    click_held: bool = false,
    nav: NavDir = .none,
    confirm_edge: bool = false,
    cancel_edge: bool = false,
    pause_edge: bool = false,
    title_exit_edge: bool = false,
    inventory_edge: bool = false,
    /// Positive wheel notches scroll content upward.
    wheel_dy: i8 = 0,
    /// Draw-only UI replays must not process text events twice.
    text_events: bool = false,
};

const Prev = struct {
    click: input.ButtonState = .released,
    confirm: input.ButtonState = .released,
    cancel: input.ButtonState = .released,
    pause: input.ButtonState = .released,
    title_exit: input.ButtonState = .released,
    inventory: input.ButtonState = .released,
};

const Actions = struct {
    click: input.ActionHandle,
    confirm: input.ActionHandle,
    cancel: input.ActionHandle,
    pause: input.ActionHandle,
    title_exit: input.ActionHandle,
    inventory: input.ActionHandle,
    up: input.ActionHandle,
    down: input.ActionHandle,
    left: input.ActionHandle,
    right: input.ActionHandle,
};

const Runtime = struct {
    prev: Prev = .{},
    /// Suppress held bindings when the menu becomes active.
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
    return if (!caps.ui.pointer)
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
    return !profile_uses_pointer() or caps.ui.seed_controller_focus;
}

pub fn title_exit_enabled() bool {
    return caps.ui.title_exit_button;
}

pub fn ensure_registered(sys: *input.InputSystem) !void {
    if (runtime.set != null) return;
    const set = try sys.register_action_set("menu");

    const click = try sys.add_action(set, "ui_click", .button);
    try sys.bind_action(click, &.{ .source = .{ .mouse_button = .Left } });

    const confirm = try sys.add_action(set, "ui_confirm", .button);
    try sys.bind_action(confirm, &.{ .source = .{ .key = .Enter } });
    try sys.bind_action(confirm, &.{ .source = .{ .key = .Space } });
    try sys.bind_action(confirm, &.{ .source = .{ .gamepad_button = .A } });

    // Leave keyboard B available to text fields.
    const cancel = try sys.add_action(set, "ui_cancel", .button);
    try sys.bind_action(cancel, &.{ .source = .{ .key = .Escape } });
    try sys.bind_action(cancel, &.{ .source = .{ .gamepad_button = .B } });
    try sys.bind_action(cancel, &.{ .source = .{ .gamepad_button = .Start } });

    // Inventory's B binding must not pause gameplay.
    const pause = try sys.add_action(set, "ui_pause", .button);
    try sys.bind_action(pause, &.{ .source = .{ .key = .Escape } });
    try sys.bind_action(pause, &.{ .source = .{ .gamepad_button = .Start } });

    // Start exits the console title screen; elsewhere it means Back or Pause.
    const title_exit = try sys.add_action(set, "ui_title_exit", .button);
    if (title_exit_enabled()) {
        try sys.bind_action(title_exit, &.{ .source = .{ .gamepad_button = .Start } });
    }

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
        .title_exit = title_exit,
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
    if (!Options.uses_single_stick_controls()) {
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

/// `repeat` is owned by the active screen and persists across frames.
pub fn build_frame(sys: *input.InputSystem, dt: f32, repeat: *Repeat) UiInput {
    assert(dt >= 0);
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
    const title_exit = sys.button(actions.title_exit).current;
    const inventory = sys.button(actions.inventory).current;

    const active_now = is_menu_set_active(sys);

    const fresh_activation = active_now and !runtime.was_active;
    runtime.was_active = active_now;

    const click_edge = !fresh_activation and rising_edge(runtime.prev.click, click);
    const confirm_edge = !fresh_activation and rising_edge(runtime.prev.confirm, confirm);
    const cancel_edge = !fresh_activation and rising_edge(runtime.prev.cancel, cancel);
    const pause_edge = !fresh_activation and rising_edge(runtime.prev.pause, pause);
    const title_exit_edge = !fresh_activation and rising_edge(runtime.prev.title_exit, title_exit);
    const inventory_edge = !fresh_activation and rising_edge(runtime.prev.inventory, inventory);

    runtime.prev.click = click;
    runtime.prev.confirm = confirm;
    runtime.prev.cancel = cancel;
    runtime.prev.pause = pause;
    runtime.prev.title_exit = title_exit;
    runtime.prev.inventory = inventory;

    const held = [4]bool{
        sys.button(actions.up).down(),
        sys.button(actions.down).down(),
        sys.button(actions.left).down(),
        sys.button(actions.right).down(),
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
        .title_exit_edge = title_exit_edge,
        .inventory_edge = inventory_edge,
        .wheel_dy = if (profile_uses_pointer() and !fresh_activation) read_wheel_dy(sys) else 0,
        .text_events = true,
    };
}

/// Preserve fractional trackpad deltas between frames.
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
    return top.actions == set;
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

fn resolve_nav(held: [4]bool, dt: f32, repeat: *Repeat) NavDir {
    const dirs = [_]NavDir{ .up, .down, .left, .right };
    const active = for (held, dirs) |is_held, direction| {
        if (is_held) break direction;
    } else {
        repeat.* = .{};
        return .none;
    };

    if (active != repeat.direction) {
        repeat.* = .{ .direction = active };
        return active;
    }
    repeat.timer += dt;
    if (repeat.timer < RepeatDelay) return .none;
    repeat.timer -= RepeatRate;
    return active;
}

test "navigation repeats while held and resets on release" {
    var repeat: Repeat = .{};
    const down = [4]bool{ false, true, false, false };
    const released = [4]bool{ false, false, false, false };

    try std.testing.expectEqual(NavDir.down, resolve_nav(down, 0, &repeat));
    try std.testing.expectEqual(NavDir.none, resolve_nav(down, RepeatDelay - 0.01, &repeat));
    try std.testing.expectEqual(NavDir.down, resolve_nav(down, 0.02, &repeat));
    try std.testing.expectEqual(NavDir.none, resolve_nav(down, RepeatRate - 0.02, &repeat));
    try std.testing.expectEqual(NavDir.down, resolve_nav(down, 0.02, &repeat));

    try std.testing.expectEqual(NavDir.none, resolve_nav(released, 0, &repeat));
    try std.testing.expectEqual(NavDir.down, resolve_nav(down, 0, &repeat));
}

test "navigation resolves opposing directions once per frame" {
    var repeat: Repeat = .{};
    try std.testing.expectEqual(NavDir.up, resolve_nav(.{ true, true, true, true }, 0, &repeat));
    try std.testing.expectEqual(NavDir.down, resolve_nav(.{ false, true, true, true }, 0, &repeat));
    try std.testing.expectEqual(NavDir.none, resolve_nav(.{ false, true, true, true }, RepeatDelay - 0.01, &repeat));
    try std.testing.expectEqual(NavDir.up, resolve_nav(.{ true, true, true, true }, 0, &repeat));
}
