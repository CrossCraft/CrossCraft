/// Gameplay action-set registration and bindings.
const std = @import("std");
const builtin = @import("builtin");
const ae = @import("aether");
const input = ae.Core.input;
const Options = @import("../Options.zig");

pub const ActionSetHandle = input.ActionSetHandle;

var gameplay_set: ?ActionSetHandle = null;
var gameplay_actions: ?Actions = null;

pub const Actions = struct {
    move: input.ActionHandle,
    jump: input.ActionHandle,
    sneak: input.ActionHandle,
    noclip: input.ActionHandle = .none,
    hud_toggle: input.ActionHandle = .none,
    rain_toggle: input.ActionHandle = .none,
    inventory_toggle: input.ActionHandle,
    ui_pause: input.ActionHandle,
    look: input.ActionHandle,
    look_stick: input.ActionHandle,
    break_: input.ActionHandle,
    place: input.ActionHandle,
    pick_block: input.ActionHandle = .none,
    shoulder_r: input.ActionHandle,
    shoulder_l: input.ActionHandle,
    playerlist: input.ActionHandle,
    chat_open: input.ActionHandle,
    chat_cmd: input.ActionHandle,
    hotbar_left: input.ActionHandle,
    hotbar_right: input.ActionHandle,
    hotbar_scroll: input.ActionHandle,
    hotbar_slot: [9]input.ActionHandle,
};

pub fn handle() ?ActionSetHandle {
    return gameplay_set;
}

pub fn actions() Actions {
    return gameplay_actions.?;
}

/// Register and install the gameplay action set once.
pub fn init(sys: *input.InputSystem) !ActionSetHandle {
    if (gameplay_set) |h| return h;
    const set = try sys.register_action_set("gameplay");

    const move = try sys.add_action(set, "move", .vector2);
    try bind_move(sys, move);

    const jump = try sys.add_action(set, "jump", .button);
    try bind_jump(sys, jump);
    const sneak = try sys.add_action(set, "sneak", .button);
    try sys.bind_action(sneak, &.{ .source = .{ .key = .LeftShift } });
    if (ae.platform == .psp or Options.uses_old_3ds_controls()) {
        try sys.bind_action(sneak, &.{ .source = .{ .gamepad_button = .DpadDown } });
    } else {
        try sys.bind_action(sneak, &.{ .source = .{ .gamepad_button = .X } });
    }

    var noclip: input.ActionHandle = .none;
    if (comptime builtin.mode == .Debug and ae.platform != .psp) {
        noclip = try sys.add_action(set, "noclip", .button);
        try sys.bind_action(noclip, &.{ .source = .{ .key = .X } });
    }

    var hud_toggle: input.ActionHandle = .none;
    if (ae.platform != .psp) {
        hud_toggle = try sys.add_action(set, "hud_toggle", .button);
        try sys.bind_action(hud_toggle, &.{ .source = .{ .key = .F1 } });
    }

    var rain_toggle: input.ActionHandle = .none;
    if (ae.platform != .psp) {
        rain_toggle = try sys.add_action(set, "rain_toggle", .button);
        try sys.bind_action(rain_toggle, &.{ .source = .{ .key = .F5 } });
    }

    const inventory_toggle = try sys.add_action(set, "inventory_toggle", .button);
    try bind_inventory_toggle(sys, inventory_toggle);

    // ui_pause is mirrored from menu_set so build_frame can poll it from
    // either context.
    const ui_pause = try sys.add_action(set, "ui_pause", .button);
    try sys.bind_action(ui_pause, &.{ .source = .{ .key = .Escape } });
    try sys.bind_action(ui_pause, &.{ .source = .{ .gamepad_button = .Start } });

    // Multiplier stays 1.0; Player applies Options.current.sensitivity at
    // read time.
    const look = try sys.add_action(set, "look", .vector2);
    try sys.bind_action(look, &.{ .source = .{ .mouse_delta = .x }, .component = .x });
    try sys.bind_action(look, &.{ .source = .{ .mouse_delta = .y }, .component = .y });

    // Stick look is a rate applied with frame delta.
    const look_stick = try sys.add_action(set, "look_stick", .vector2);
    try bind_look_stick(sys, look_stick);

    const break_ = try sys.add_action(set, "break", .button);
    try sys.bind_action(break_, &.{ .source = .{ .mouse_button = .Left } });
    const place = try sys.add_action(set, "place", .button);
    try sys.bind_action(place, &.{ .source = .{ .mouse_button = .Right } });
    var pick_block: input.ActionHandle = .none;
    if (Options.uses_old_3ds_controls()) {
        // Old 3DS has physical L/R shoulders but no ZL/ZR triggers. Bind the
        // physical buttons directly; keep Aether's trigger-axis aliases as a
        // compatibility fallback for builds using that backend mapping.
        try sys.bind_action(break_, &.{ .source = .{ .gamepad_button = .RButton } });
        try sys.bind_action(place, &.{ .source = .{ .gamepad_button = .LButton } });
        try sys.bind_action(break_, &.{ .source = .{ .gamepad_axis = .RightTrigger } });
        try sys.bind_action(place, &.{ .source = .{ .gamepad_axis = .LeftTrigger } });
    } else if (ae.platform != .psp) {
        try sys.bind_action(break_, &.{ .source = .{ .gamepad_axis = .RightTrigger } });
        try sys.bind_action(place, &.{ .source = .{ .gamepad_axis = .LeftTrigger } });
        pick_block = try sys.add_action(set, "pick_block", .button);
        try sys.bind_action(pick_block, &.{ .source = .{ .mouse_button = .Middle } });
    }

    const shoulder_r = try sys.add_action(set, "shoulder_r", .button);
    const shoulder_l = try sys.add_action(set, "shoulder_l", .button);
    if (ae.platform == .psp) {
        try sys.bind_action(shoulder_r, &.{ .source = .{ .gamepad_button = .RButton } });
        try sys.bind_action(shoulder_l, &.{ .source = .{ .gamepad_button = .LButton } });
    }

    const playerlist = try sys.add_action(set, "playerlist", .button);
    try bind_playerlist(sys, playerlist);

    // chat_open (T) and chat_cmd (/) open the chat overlay; chat_send /
    // chat_cancel live on the chat ActionSet so Enter only sends when
    // chat owns the top context.
    const chat_open = try sys.add_action(set, "chat_open", .button);
    try sys.bind_action(chat_open, &.{ .source = .{ .key = .T } });
    const chat_cmd = try sys.add_action(set, "chat_cmd", .button);
    try sys.bind_action(chat_cmd, &.{ .source = .{ .key = .Slash } });

    const hotbar_left = try sys.add_action(set, "hotbar_left", .button);
    try sys.bind_action(hotbar_left, &.{ .source = .{ .gamepad_button = .DpadLeft } });
    const hotbar_right = try sys.add_action(set, "hotbar_right", .button);
    try sys.bind_action(hotbar_right, &.{ .source = .{ .gamepad_button = .DpadRight } });
    const hotbar_scroll = try sys.add_action(set, "hotbar_scroll", .axis);
    try sys.bind_action(hotbar_scroll, &.{ .source = .{ .mouse_wheel = .y } });
    if (ae.platform != .psp and !Options.uses_old_3ds_controls()) {
        try sys.bind_action(hotbar_left, &.{ .source = .{ .gamepad_button = .LButton } });
        try sys.bind_action(hotbar_right, &.{ .source = .{ .gamepad_button = .RButton } });
    }

    var hotbar_slot: [9]input.ActionHandle = undefined;
    inline for (&hotbar_slot, .{ input.Key.Num1, .Num2, .Num3, .Num4, .Num5, .Num6, .Num7, .Num8, .Num9 }, 0..) |*slot, key, i| {
        var name_buf: [14]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "hotbar_slot_{d}", .{i + 1});
        slot.* = try sys.add_action(set, name, .button);
        try sys.bind_action(slot.*, &.{ .source = .{ .key = key } });
    }

    try sys.install_action_set(set);
    gameplay_set = set;
    gameplay_actions = .{
        .move = move,
        .jump = jump,
        .sneak = sneak,
        .noclip = noclip,
        .hud_toggle = hud_toggle,
        .rain_toggle = rain_toggle,
        .inventory_toggle = inventory_toggle,
        .ui_pause = ui_pause,
        .look = look,
        .look_stick = look_stick,
        .break_ = break_,
        .place = place,
        .pick_block = pick_block,
        .shoulder_r = shoulder_r,
        .shoulder_l = shoulder_l,
        .playerlist = playerlist,
        .chat_open = chat_open,
        .chat_cmd = chat_cmd,
        .hotbar_left = hotbar_left,
        .hotbar_right = hotbar_right,
        .hotbar_scroll = hotbar_scroll,
        .hotbar_slot = hotbar_slot,
    };
    return set;
}

pub fn apply_options(sys: *input.InputSystem) !void {
    const previous = gameplay_set orelse return;
    gameplay_set = null;
    gameplay_actions = null;
    errdefer gameplay_set = previous;
    _ = try init(sys);
    try refresh_active_context(sys);
}

pub fn refresh_active_context(sys: *input.InputSystem) !void {
    const set = gameplay_set orelse return;
    const top = sys.stack_top() orelse return;
    if (!std.mem.eql(u8, top.name, "gameplay")) return;
    // Replacing even an unchanged context synchronizes its actions with the
    // currently held physical inputs.  An overlay can be closed by Escape
    // while that key is still held; without this sync, gameplay would see it
    // as a fresh ui_pause edge on the following frame.
    var ctx = top.*;
    ctx.actions = set;
    _ = try sys.replace_top(&ctx);
}

test "refreshing gameplay after an overlay consumes held Escape" {
    var sys = input.InputSystem{};
    try sys.init(std.testing.allocator);
    defer sys.deinit();
    defer {
        gameplay_set = null;
        gameplay_actions = null;
    }

    const gameplay = try init(&sys);
    try sys.push_context(&.{
        .name = "gameplay",
        .cursor_mode = .captured,
        .actions = gameplay,
    });

    const overlay = try sys.register_action_set("test_overlay");
    try sys.install_action_set(overlay);
    try sys.push_context(&.{
        .name = "test_overlay",
        .cursor_mode = .visible,
        .actions = overlay,
    });

    sys.deliver_key_down(.Escape, .{}, false);
    sys.update();
    _ = try sys.pop_context();
    try refresh_active_context(&sys);

    try std.testing.expect(sys.button(actions().ui_pause).down());
    try std.testing.expect(!sys.button(actions().ui_pause).pressed());

    sys.update();
    try std.testing.expect(!sys.button(actions().ui_pause).pressed());

    sys.deliver_key_up(.Escape, .{});
    sys.update();
    sys.deliver_key_down(.Escape, .{}, false);
    sys.update();
    try std.testing.expect(sys.button(actions().ui_pause).pressed());
}

fn bind_move(sys: *input.InputSystem, action: input.ActionHandle) !void {
    if (ae.platform == .psp) {
        switch (Options.current.psp_analog_mode) {
            .move => {
                try sys.bind_action(action, &.{ .source = .{ .gamepad_axis = .LeftX }, .component = .x, .multiplier = 1.0 });
                try sys.bind_action(action, &.{ .source = .{ .gamepad_axis = .LeftY }, .component = .y, .multiplier = -1.0 });
            },
            .look => try bind_psp_face_move(sys, action),
        }
        return;
    }

    if (Options.uses_old_3ds_controls()) {
        switch (Options.current.psp_analog_mode) {
            .move => {
                try sys.bind_action(action, &.{ .source = .{ .gamepad_axis = .LeftX }, .component = .x, .multiplier = 1.0 });
                try sys.bind_action(action, &.{ .source = .{ .gamepad_axis = .LeftY }, .component = .y, .multiplier = -1.0 });
            },
            .look => try bind_old_3ds_face_move(sys, action),
        }
        return;
    }

    try sys.bind_action(action, &.{ .source = .{ .key = Options.current.key_forward }, .component = .y, .multiplier = 1.0 });
    try sys.bind_action(action, &.{ .source = .{ .key = Options.current.key_back }, .component = .y, .multiplier = -1.0 });
    try sys.bind_action(action, &.{ .source = .{ .key = Options.current.key_left }, .component = .x, .multiplier = -1.0 });
    try sys.bind_action(action, &.{ .source = .{ .key = Options.current.key_right }, .component = .x, .multiplier = 1.0 });

    // LeftY is positive downward, so forward uses a negative multiplier.
    try sys.bind_action(action, &.{ .source = .{ .gamepad_axis = .LeftX }, .component = .x, .multiplier = 1.0 });
    try sys.bind_action(action, &.{ .source = .{ .gamepad_axis = .LeftY }, .component = .y, .multiplier = -1.0 });
}

fn bind_psp_face_move(sys: *input.InputSystem, action: input.ActionHandle) !void {
    try sys.bind_action(action, &.{ .source = .{ .gamepad_button = .B }, .component = .x, .multiplier = 1.0 }); // Circle = right
    try sys.bind_action(action, &.{ .source = .{ .gamepad_button = .X }, .component = .x, .multiplier = -1.0 }); // Square = left
    try sys.bind_action(action, &.{ .source = .{ .gamepad_button = .Y }, .component = .y, .multiplier = 1.0 }); // Triangle = forward
    try sys.bind_action(action, &.{ .source = .{ .gamepad_button = .A }, .component = .y, .multiplier = -1.0 }); // Cross = back
}

fn bind_old_3ds_face_move(sys: *input.InputSystem, action: input.ActionHandle) !void {
    try sys.bind_action(action, &.{ .source = .{ .gamepad_button = .A }, .component = .x, .multiplier = 1.0 }); // A = right
    try sys.bind_action(action, &.{ .source = .{ .gamepad_button = .Y }, .component = .x, .multiplier = -1.0 }); // Y = left
    try sys.bind_action(action, &.{ .source = .{ .gamepad_button = .X }, .component = .y, .multiplier = 1.0 }); // X = forward
    try sys.bind_action(action, &.{ .source = .{ .gamepad_button = .B }, .component = .y, .multiplier = -1.0 }); // B = back
}

fn bind_jump(sys: *input.InputSystem, action: input.ActionHandle) !void {
    try sys.bind_action(action, &.{ .source = .{ .key = .Space } });
    if (ae.platform == .psp) {
        const button: input.Button = switch (Options.current.psp_jump_mode) {
            .up => .DpadUp,
            .select => .Back,
        };
        try sys.bind_action(action, &.{ .source = .{ .gamepad_button = button } });
    } else if (Options.uses_old_3ds_controls()) {
        const button: input.Button = switch (Options.current.psp_jump_mode) {
            .up => .DpadUp,
            .select => .Back,
        };
        try sys.bind_action(action, &.{ .source = .{ .gamepad_button = button } });
    } else {
        try sys.bind_action(action, &.{ .source = .{ .gamepad_button = .A } });
    }
}

fn bind_inventory_toggle(sys: *input.InputSystem, action: input.ActionHandle) !void {
    try sys.bind_action(action, &.{ .source = .{ .key = Options.current.key_inventory } });
    if (ae.platform != .psp and !Options.uses_old_3ds_controls()) {
        try sys.bind_action(action, &.{ .source = .{ .gamepad_button = .Y } });
    }
}

fn bind_look_stick(sys: *input.InputSystem, action: input.ActionHandle) !void {
    if (ae.platform == .psp) {
        switch (Options.current.psp_analog_mode) {
            .look => {
                try sys.bind_action(action, &.{ .source = .{ .gamepad_axis = .LeftX }, .component = .x });
                try sys.bind_action(action, &.{ .source = .{ .gamepad_axis = .LeftY }, .component = .y });
            },
            .move => {
                try sys.bind_action(action, &.{ .source = .{ .gamepad_button = .B }, .component = .x, .multiplier = 1.0 }); // Circle = right
                try sys.bind_action(action, &.{ .source = .{ .gamepad_button = .X }, .component = .x, .multiplier = -1.0 }); // Square = left
                try sys.bind_action(action, &.{ .source = .{ .gamepad_button = .Y }, .component = .y, .multiplier = -1.0 }); // Triangle = up
                try sys.bind_action(action, &.{ .source = .{ .gamepad_button = .A }, .component = .y, .multiplier = 1.0 }); // Cross = down
            },
        }
    } else if (Options.uses_old_3ds_controls()) {
        switch (Options.current.psp_analog_mode) {
            .look => {
                try sys.bind_action(action, &.{ .source = .{ .gamepad_axis = .LeftX }, .component = .x });
                try sys.bind_action(action, &.{ .source = .{ .gamepad_axis = .LeftY }, .component = .y });
            },
            .move => {
                try sys.bind_action(action, &.{ .source = .{ .gamepad_button = .A }, .component = .x, .multiplier = 1.0 }); // A = right
                try sys.bind_action(action, &.{ .source = .{ .gamepad_button = .Y }, .component = .x, .multiplier = -1.0 }); // Y = left
                try sys.bind_action(action, &.{ .source = .{ .gamepad_button = .X }, .component = .y, .multiplier = -1.0 }); // X = up
                try sys.bind_action(action, &.{ .source = .{ .gamepad_button = .B }, .component = .y, .multiplier = 1.0 }); // B = down
            },
        }
    } else if (ae.platform == .nintendo_3ds) {
        try sys.bind_action(action, &.{ .source = .{ .gamepad_axis = .RightX }, .component = .x, .deadzone = 0.0 });
        try sys.bind_action(action, &.{ .source = .{ .gamepad_axis = .RightY }, .component = .y, .deadzone = 0.0 });
    } else {
        try sys.bind_action(action, &.{ .source = .{ .gamepad_axis = .RightX }, .component = .x });
        try sys.bind_action(action, &.{ .source = .{ .gamepad_axis = .RightY }, .component = .y });
    }
}

fn bind_playerlist(sys: *input.InputSystem, action: input.ActionHandle) !void {
    try sys.bind_action(action, &.{ .source = .{ .key = .Tab } });
    const button: input.Button = if (ae.platform == .psp)
        switch (Options.current.psp_jump_mode) {
            .up => .Back,
            .select => .DpadUp,
        }
    else if (Options.uses_old_3ds_controls())
        switch (Options.current.psp_jump_mode) {
            .up => .Back,
            .select => .DpadUp,
        }
    else
        .Back;
    try sys.bind_action(action, &.{ .source = .{ .gamepad_button = button } });
}
