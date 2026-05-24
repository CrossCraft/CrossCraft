/// Gameplay ActionSet registration. Caller pushes a context referencing
/// the returned handle while the player has agency.
const std = @import("std");
const builtin = @import("builtin");
const ae = @import("aether");
const input = ae.Core.input;
const Options = @import("../Options.zig");

pub const ActionSetHandle = input.ActionSetHandle;

var gameplay_set: ?ActionSetHandle = null;

/// Gameplay action set handle if registered, null otherwise.
pub fn handle() ?ActionSetHandle {
    return gameplay_set;
}

/// Idempotent: registers, binds, and installs the gameplay action set on
/// first call. Caller pushes the matching context.
pub fn init() !ActionSetHandle {
    if (gameplay_set) |h| return h;
    const set = try input.register_action_set("gameplay");

    // --- movement (vector2: x = strafe, y = forward/back) ---
    try input.add_action(set, "move", .vector2);
    try bind_move(set);

    // --- jump / sneak ---
    try input.add_action(set, "jump", .button);
    try bind_jump(set);
    try input.add_action(set, "sneak", .button);
    try input.bind_action(set, "sneak", .{ .source = .{ .key = .LeftShift } });
    if (ae.platform == .psp) {
        try input.bind_action(set, "sneak", .{ .source = .{ .gamepad_button = .DpadDown } });
    } else {
        try input.bind_action(set, "sneak", .{ .source = .{ .gamepad_button = .X } });
    }

    // --- noclip toggle ---
    if (comptime builtin.mode == .Debug and ae.platform != .psp) {
        try input.add_action(set, "noclip", .button);
        try input.bind_action(set, "noclip", .{ .source = .{ .key = .X } });
    }

    // --- HUD toggle (desktop only) ---
    if (ae.platform != .psp) {
        try input.add_action(set, "hud_toggle", .button);
        try input.bind_action(set, "hud_toggle", .{ .source = .{ .key = .F1 } });
    }

    // --- rain toggle (desktop only) ---
    if (ae.platform != .psp) {
        try input.add_action(set, "rain_toggle", .button);
        try input.bind_action(set, "rain_toggle", .{ .source = .{ .key = .F5 } });
    }

    // --- inventory toggle ---
    try input.add_action(set, "inventory_toggle", .button);
    try bind_inventory_toggle(set);

    // ui_pause is mirrored from menu_set so build_frame can poll it from
    // either context.
    try input.add_action(set, "ui_pause", .button);
    try input.bind_action(set, "ui_pause", .{ .source = .{ .key = .Escape } });
    try input.bind_action(set, "ui_pause", .{ .source = .{ .gamepad_button = .Start } });

    // --- mouse look (delta-based) ---
    // Multiplier stays 1.0; Player applies Options.current.sensitivity at
    // read time.
    try input.add_action(set, "look", .vector2);
    try input.bind_action(set, "look", .{ .source = .{ .mouse_delta = .x }, .component = .x });
    try input.bind_action(set, "look", .{ .source = .{ .mouse_delta = .y }, .component = .y });

    // --- stick look (rate-based, applied as velocity * dt) ---
    try input.add_action(set, "look_stick", .vector2);
    try bind_look_stick(set);

    // --- break / place ---
    try input.add_action(set, "break", .button);
    try input.bind_action(set, "break", .{ .source = .{ .mouse_button = .Left } });
    try input.add_action(set, "place", .button);
    try input.bind_action(set, "place", .{ .source = .{ .mouse_button = .Right } });
    if (ae.platform != .psp) {
        try input.bind_action(set, "break", .{ .source = .{ .gamepad_axis = .RightTrigger } });
        try input.bind_action(set, "place", .{ .source = .{ .gamepad_axis = .LeftTrigger } });
    }

    // --- gamepad shoulder buttons (L/R) ---
    try input.add_action(set, "shoulder_r", .button);
    try input.add_action(set, "shoulder_l", .button);
    if (ae.platform == .psp) {
        try input.bind_action(set, "shoulder_r", .{ .source = .{ .gamepad_button = .RButton } });
        try input.bind_action(set, "shoulder_l", .{ .source = .{ .gamepad_button = .LButton } });
    }

    // --- playerlist (held overlay) ---
    try input.add_action(set, "playerlist", .button);
    try bind_playerlist(set);

    // chat_open (T) and chat_cmd (/) open the chat overlay; chat_send /
    // chat_cancel live on the chat ActionSet so Enter only sends when
    // chat owns the top context.
    try input.add_action(set, "chat_open", .button);
    try input.bind_action(set, "chat_open", .{ .source = .{ .key = .T } });
    try input.add_action(set, "chat_cmd", .button);
    try input.bind_action(set, "chat_cmd", .{ .source = .{ .key = .Slash } });

    // PSP: Cross (X) confirms / launches the OSK while the social overlay is
    // open. It may share a face-button gameplay binding; the OSK fires
    // synchronously so any simultaneous movement/look is harmless.
    if (ae.platform == .psp) {
        try input.add_action(set, "psp_osk", .button);
        try input.bind_action(set, "psp_osk", .{ .source = .{ .gamepad_button = .A } }); // Cross
    }

    // --- hotbar slot cycle ---
    try input.add_action(set, "hotbar_left", .button);
    try input.bind_action(set, "hotbar_left", .{ .source = .{ .gamepad_button = .DpadLeft } });
    try input.add_action(set, "hotbar_right", .button);
    try input.bind_action(set, "hotbar_right", .{ .source = .{ .gamepad_button = .DpadRight } });
    try input.add_action(set, "hotbar_scroll", .axis);
    try input.bind_action(set, "hotbar_scroll", .{ .source = .{ .mouse_wheel = .y } });
    if (ae.platform != .psp) {
        try input.bind_action(set, "hotbar_left", .{ .source = .{ .gamepad_button = .LButton } });
        try input.bind_action(set, "hotbar_right", .{ .source = .{ .gamepad_button = .RButton } });
    }

    // --- direct hotbar slot select (keyboard 1-9) ---
    try input.add_action(set, "hotbar_slot_1", .button);
    try input.bind_action(set, "hotbar_slot_1", .{ .source = .{ .key = .Num1 } });
    try input.add_action(set, "hotbar_slot_2", .button);
    try input.bind_action(set, "hotbar_slot_2", .{ .source = .{ .key = .Num2 } });
    try input.add_action(set, "hotbar_slot_3", .button);
    try input.bind_action(set, "hotbar_slot_3", .{ .source = .{ .key = .Num3 } });
    try input.add_action(set, "hotbar_slot_4", .button);
    try input.bind_action(set, "hotbar_slot_4", .{ .source = .{ .key = .Num4 } });
    try input.add_action(set, "hotbar_slot_5", .button);
    try input.bind_action(set, "hotbar_slot_5", .{ .source = .{ .key = .Num5 } });
    try input.add_action(set, "hotbar_slot_6", .button);
    try input.bind_action(set, "hotbar_slot_6", .{ .source = .{ .key = .Num6 } });
    try input.add_action(set, "hotbar_slot_7", .button);
    try input.bind_action(set, "hotbar_slot_7", .{ .source = .{ .key = .Num7 } });
    try input.add_action(set, "hotbar_slot_8", .button);
    try input.bind_action(set, "hotbar_slot_8", .{ .source = .{ .key = .Num8 } });
    try input.add_action(set, "hotbar_slot_9", .button);
    try input.bind_action(set, "hotbar_slot_9", .{ .source = .{ .key = .Num9 } });

    try input.install_action_set(set);
    gameplay_set = set;
    return set;
}

pub fn apply_options() !void {
    const previous = gameplay_set orelse return;
    gameplay_set = null;
    errdefer gameplay_set = previous;
    _ = try init();
    try refresh_active_context();
}

pub fn refresh_active_context() !void {
    const set = gameplay_set orelse return;
    const top = input.stack_top() orelse return;
    if (!std.mem.eql(u8, top.name, "gameplay")) return;
    if (top.actions == set) return;
    var ctx = top.*;
    ctx.actions = set;
    _ = try input.replace_top(ctx);
}

fn bind_move(set: ActionSetHandle) !void {
    if (ae.platform == .psp) {
        switch (Options.current.psp_analog_mode) {
            .move => {
                try input.bind_action(set, "move", .{ .source = .{ .gamepad_axis = .LeftX }, .component = .x, .multiplier = 1.0 });
                try input.bind_action(set, "move", .{ .source = .{ .gamepad_axis = .LeftY }, .component = .y, .multiplier = -1.0 });
            },
            .look => try bind_psp_face_move(set),
        }
        return;
    }

    try input.bind_action(set, "move", .{ .source = .{ .key = Options.current.key_forward }, .component = .y, .multiplier = 1.0 });
    try input.bind_action(set, "move", .{ .source = .{ .key = Options.current.key_back }, .component = .y, .multiplier = -1.0 });
    try input.bind_action(set, "move", .{ .source = .{ .key = Options.current.key_left }, .component = .x, .multiplier = -1.0 });
    try input.bind_action(set, "move", .{ .source = .{ .key = Options.current.key_right }, .component = .x, .multiplier = 1.0 });
    // Desktop: left analog stick drives movement. LeftY is +1 when pushed
    // down, so invert to make forward = +y.
    try input.bind_action(set, "move", .{ .source = .{ .gamepad_axis = .LeftX }, .component = .x, .multiplier = 1.0 });
    try input.bind_action(set, "move", .{ .source = .{ .gamepad_axis = .LeftY }, .component = .y, .multiplier = -1.0 });
}

fn bind_psp_face_move(set: ActionSetHandle) !void {
    try input.bind_action(set, "move", .{ .source = .{ .gamepad_button = .B }, .component = .x, .multiplier = 1.0 }); // Circle = right
    try input.bind_action(set, "move", .{ .source = .{ .gamepad_button = .X }, .component = .x, .multiplier = -1.0 }); // Square = left
    try input.bind_action(set, "move", .{ .source = .{ .gamepad_button = .Y }, .component = .y, .multiplier = 1.0 }); // Triangle = forward
    try input.bind_action(set, "move", .{ .source = .{ .gamepad_button = .A }, .component = .y, .multiplier = -1.0 }); // Cross = back
}

fn bind_jump(set: ActionSetHandle) !void {
    try input.bind_action(set, "jump", .{ .source = .{ .key = .Space } });
    if (ae.platform == .psp) {
        const button: input.Button = switch (Options.current.psp_jump_mode) {
            .up => .DpadUp,
            .select => .Back,
        };
        try input.bind_action(set, "jump", .{ .source = .{ .gamepad_button = button } });
    } else {
        try input.bind_action(set, "jump", .{ .source = .{ .gamepad_button = .A } });
    }
}

fn bind_inventory_toggle(set: ActionSetHandle) !void {
    try input.bind_action(set, "inventory_toggle", .{ .source = .{ .key = Options.current.key_inventory } });
    if (ae.platform != .psp) {
        try input.bind_action(set, "inventory_toggle", .{ .source = .{ .gamepad_button = .Y } });
    }
}

fn bind_look_stick(set: ActionSetHandle) !void {
    if (ae.platform == .psp) {
        switch (Options.current.psp_analog_mode) {
            .look => {
                try input.bind_action(set, "look_stick", .{ .source = .{ .gamepad_axis = .LeftX }, .component = .x });
                try input.bind_action(set, "look_stick", .{ .source = .{ .gamepad_axis = .LeftY }, .component = .y });
            },
            .move => {
                try input.bind_action(set, "look_stick", .{ .source = .{ .gamepad_button = .B }, .component = .x, .multiplier = 1.0 }); // Circle = right
                try input.bind_action(set, "look_stick", .{ .source = .{ .gamepad_button = .X }, .component = .x, .multiplier = -1.0 }); // Square = left
                try input.bind_action(set, "look_stick", .{ .source = .{ .gamepad_button = .Y }, .component = .y, .multiplier = -1.0 }); // Triangle = up
                try input.bind_action(set, "look_stick", .{ .source = .{ .gamepad_button = .A }, .component = .y, .multiplier = 1.0 }); // Cross = down
            },
        }
    } else {
        try input.bind_action(set, "look_stick", .{ .source = .{ .gamepad_axis = .RightX }, .component = .x });
        try input.bind_action(set, "look_stick", .{ .source = .{ .gamepad_axis = .RightY }, .component = .y });
    }
}

fn bind_playerlist(set: ActionSetHandle) !void {
    try input.bind_action(set, "playerlist", .{ .source = .{ .key = .Tab } });
    const button: input.Button = if (ae.platform == .psp)
        switch (Options.current.psp_jump_mode) {
            .up => .Back,
            .select => .DpadUp,
        }
    else
        .Back;
    try input.bind_action(set, "playerlist", .{ .source = .{ .gamepad_button = button } });
}
