/// Input action registration and default bindings.
/// Keyboard + mouse on desktop, gamepad/analog + D-pad on PSP.
const builtin = @import("builtin");
const ae = @import("aether");
const input = ae.Core.input;

pub fn init() !void {
    // ---- movement (vector2: x = strafe, y = forward/back) ----
    try input.register_action("move", .vector2);
    // Keyboard
    try input.bind_action("move", .{ .source = .{ .key = .W }, .component = .y, .multiplier = 1.0 });
    try input.bind_action("move", .{ .source = .{ .key = .S }, .component = .y, .multiplier = -1.0 });
    try input.bind_action("move", .{ .source = .{ .key = .A }, .component = .x, .multiplier = -1.0 });
    try input.bind_action("move", .{ .source = .{ .key = .D }, .component = .x, .multiplier = 1.0 });
    // PSP face buttons drive movement (Circle/Square = strafe, Triangle/Cross = forward/back).
    try input.bind_action("move", .{ .source = .{ .gamepad_button = .B }, .component = .x, .multiplier = 1.0 }); // Circle = right
    try input.bind_action("move", .{ .source = .{ .gamepad_button = .X }, .component = .x, .multiplier = -1.0 }); // Square = left
    try input.bind_action("move", .{ .source = .{ .gamepad_button = .Y }, .component = .y, .multiplier = 1.0 }); // Triangle = forward
    try input.bind_action("move", .{ .source = .{ .gamepad_button = .A }, .component = .y, .multiplier = -1.0 }); // Cross = back

    // ---- jump / sneak ----
    try input.register_action("jump", .button);
    try input.bind_action("jump", .{ .source = .{ .key = .Space } });
    try input.bind_action("jump", .{ .source = .{ .gamepad_button = .DpadUp } });
    try input.register_action("sneak", .button);
    try input.bind_action("sneak", .{ .source = .{ .key = .LeftShift } });
    try input.bind_action("sneak", .{ .source = .{ .gamepad_button = .DpadDown } });

    // ---- noclip toggle ----
    // Debug-only dev tool. Not available in release builds and never on PSP,
    // so the gamepad Back button stays free for the inventory overlay.
    if (comptime builtin.mode == .Debug and ae.platform != .psp) {
        try input.register_action("noclip", .button);
        try input.bind_action("noclip", .{ .source = .{ .key = .X } });
    }

    // ---- inventory toggle ----
    // Opens the Classic block-picker overlay. Desktop uses B; PSP uses L+R
    // chord (detected in Player via shoulder_l / shoulder_r callbacks).
    try input.register_action("inventory_toggle", .button);
    try input.bind_action("inventory_toggle", .{ .source = .{ .key = .B } });

    // ---- mouse look (delta-based) ----
    try input.register_action("look", .vector2);
    try input.bind_action("look", .{ .source = .{ .mouse_relative = .X }, .component = .x });
    try input.bind_action("look", .{ .source = .{ .mouse_relative = .Y }, .component = .y });

    // ---- stick / face-button look (rate-based, applied as velocity * dt) ----
    try input.register_action("look_stick", .vector2);
    // Right stick (standard gamepad)
    try input.bind_action("look_stick", .{ .source = .{ .gamepad_axis = .RightX }, .component = .x });
    try input.bind_action("look_stick", .{ .source = .{ .gamepad_axis = .RightY }, .component = .y });
    // PSP analog nub: no right stick exists, so left stick aims the camera.
    try input.bind_action("look_stick", .{ .source = .{ .gamepad_axis = .LeftX }, .component = .x });
    try input.bind_action("look_stick", .{ .source = .{ .gamepad_axis = .LeftY }, .component = .y });

    // ---- escape / menu ----
    try input.register_action("escape", .button);
    try input.bind_action("escape", .{ .source = .{ .key = .Escape } });
    try input.bind_action("escape", .{ .source = .{ .gamepad_button = .Start } });

    // ---- break / place ----
    // Desktop: mouse buttons only. Gamepad shoulder buttons are handled
    // separately via shoulder_l / shoulder_r for L+R chord detection.
    try input.register_action("break", .button);
    try input.bind_action("break", .{ .source = .{ .mouse_button = .Left } });
    try input.register_action("place", .button);
    try input.bind_action("place", .{ .source = .{ .mouse_button = .Right } });

    // ---- gamepad shoulder buttons (L/R) ----
    // Separate from break/place so the L+R chord can toggle the inventory
    // without firing a spurious break or place on the same frame.
    // R = break, L = place, L+R = inventory toggle.
    try input.register_action("shoulder_r", .button);
    try input.bind_action("shoulder_r", .{ .source = .{ .gamepad_button = .RButton } });
    try input.register_action("shoulder_l", .button);
    try input.bind_action("shoulder_l", .{ .source = .{ .gamepad_button = .LButton } });

    // ---- playerlist (held overlay) ----
    try input.register_action("playerlist", .button);
    try input.bind_action("playerlist", .{ .source = .{ .key = .Tab } });
    try input.bind_action("playerlist", .{ .source = .{ .gamepad_button = .Back } });

    // ---- chat ----
    // chat_open (T): opens a blank input field.
    // chat_cmd (/): opens with '/' pre-typed for commands.
    // chat_send (Enter): sends the composed message; kept separate from
    //   ui_confirm (Enter + Space + A) so Space can type a space character
    //   without accidentally sending.
    try input.register_action("chat_open", .button);
    try input.bind_action("chat_open", .{ .source = .{ .key = .T } });
    try input.register_action("chat_cmd", .button);
    try input.bind_action("chat_cmd", .{ .source = .{ .key = .Slash } });
    try input.register_action("chat_send", .button);
    try input.bind_action("chat_send", .{ .source = .{ .key = .Enter } });

    // PSP: Cross (X) confirms / launches the OSK while the social overlay is
    // open.  Shares the same button as the 'move' backward action; that is
    // intentional -- the OSK service call is blocking so any simultaneous
    // movement is harmless.
    if (ae.platform == .psp) {
        try input.register_action("psp_osk", .button);
        try input.bind_action("psp_osk", .{ .source = .{ .gamepad_button = .A } }); // Cross
    }

    // ---- hotbar slot cycle ----
    // D-pad is button-typed (one event per press). Mouse scroll is axis-typed
    // because get_mouse_scroll() returns a per-frame delta and is consumed on
    // read -- binding it to two button actions would let only the first fire.
    try input.register_action("hotbar_left", .button);
    try input.bind_action("hotbar_left", .{ .source = .{ .gamepad_button = .DpadLeft } });
    try input.register_action("hotbar_right", .button);
    try input.bind_action("hotbar_right", .{ .source = .{ .gamepad_button = .DpadRight } });
    try input.register_action("hotbar_scroll", .axis);
    try input.bind_action("hotbar_scroll", .{ .source = .{ .mouse_scroll = {} } });

    // ---- direct hotbar slot select (keyboard 1-9) ----
    try input.register_action("hotbar_slot_1", .button);
    try input.bind_action("hotbar_slot_1", .{ .source = .{ .key = .Num1 } });
    try input.register_action("hotbar_slot_2", .button);
    try input.bind_action("hotbar_slot_2", .{ .source = .{ .key = .Num2 } });
    try input.register_action("hotbar_slot_3", .button);
    try input.bind_action("hotbar_slot_3", .{ .source = .{ .key = .Num3 } });
    try input.register_action("hotbar_slot_4", .button);
    try input.bind_action("hotbar_slot_4", .{ .source = .{ .key = .Num4 } });
    try input.register_action("hotbar_slot_5", .button);
    try input.bind_action("hotbar_slot_5", .{ .source = .{ .key = .Num5 } });
    try input.register_action("hotbar_slot_6", .button);
    try input.bind_action("hotbar_slot_6", .{ .source = .{ .key = .Num6 } });
    try input.register_action("hotbar_slot_7", .button);
    try input.bind_action("hotbar_slot_7", .{ .source = .{ .key = .Num7 } });
    try input.register_action("hotbar_slot_8", .button);
    try input.bind_action("hotbar_slot_8", .{ .source = .{ .key = .Num8 } });
    try input.register_action("hotbar_slot_9", .button);
    try input.bind_action("hotbar_slot_9", .{ .source = .{ .key = .Num9 } });
}
