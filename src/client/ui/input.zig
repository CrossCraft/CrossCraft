const std = @import("std");
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

pub const Repeat = ae.Ui.InputAdapter;

pub const UiInput = struct {
    input_system: ?*input.InputSystem = null,
    cursor_x: i16 = 0,
    cursor_y: i16 = 0,
    cursor_available: bool = false,
    cursor_moved: bool = false,
    click_edge: bool = false,
    click_held: bool = false,
    click_released: bool = false,
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
    pub fn frame(self: UiInput) ae.Ui.InputAdapter.Frame {
        return .{ .input_system = self.input_system, .pointer = if (self.cursor_available) .{ .x = self.cursor_x, .y = self.cursor_y } else null, .pointer_moved = self.cursor_moved, .pointer_pressed = self.click_edge, .pointer_down = self.click_held, .pointer_released = self.click_released, .direction = switch (self.nav) {
            .none => null,
            .up => .up,
            .down => .down,
            .left => .left,
            .right => .right,
        }, .confirm = self.confirm_edge, .cancel = self.cancel_edge, .wheel = self.wheel_dy };
    }
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
    /// Suppress held bindings when the menu becomes active.
    was_active: bool = false,
    set: ?input.ActionSetHandle = null,
    actions: ?Actions = null,
    profile: InputProfile = .pointer_and_pad,
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
    Buttons.note_input_mode(sys.last_input_mode());
    const actions = runtime.actions.?;
    const active = if (sys.stack_top()) |top| top.actions == runtime.set.? else false;
    const fresh = active and !runtime.was_active;
    runtime.was_active = active;
    if (fresh) repeat.open();
    repeat.options.repeat_interval = 0.08;
    const surface = Rendering.surface_size();
    const frame = repeat.poll(sys, .{ .pointer = actions.click, .confirm = actions.confirm, .cancel = actions.cancel, .up = actions.up, .down = actions.down, .left = actions.left, .right = actions.right }, dt, @floatFromInt(Scaling.compute(surface.width, surface.height)));
    const pointer: ae.Ui.Point = frame.pointer orelse .{ .x = -1, .y = -1 };
    return .{ .input_system = sys, .cursor_x = pointer.x, .cursor_y = pointer.y, .cursor_available = profile_uses_pointer() and frame.pointer != null, .cursor_moved = frame.pointer_moved, .click_edge = frame.pointer_pressed, .click_held = frame.pointer_down, .click_released = frame.pointer_released, .nav = if (frame.direction) |direction| switch (direction) {
        .up => .up,
        .down => .down,
        .left => .left,
        .right => .right,
    } else .none, .confirm_edge = frame.confirm, .cancel_edge = frame.cancel, .pause_edge = !fresh and sys.button(actions.pause).pressed(), .title_exit_edge = !fresh and sys.button(actions.title_exit).pressed(), .inventory_edge = !fresh and sys.button(actions.inventory).pressed(), .wheel_dy = if (profile_uses_pointer() and !fresh) @intCast(std.math.clamp(frame.wheel, -127, 127)) else 0, .text_events = true };
}
