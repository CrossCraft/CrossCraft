/// Input action registration and default bindings.
/// Keyboard + mouse on desktop, gamepad/analog + D-pad on PSP.
///
/// Owns the gameplay ActionSet -- registered once by `init`, returned to the
/// caller as an `ActionSetHandle`. The caller pushes a context referencing
/// this set when the player has agency (GameState) and pops it on transition
/// out. Look sensitivity is applied at read time in Player.update against
/// the current Options value, so changing the option takes effect on the
/// next frame without re-binding.
const builtin = @import("builtin");
const ae = @import("aether");
const input = ae.Core.input;

pub const ActionSetHandle = input.ActionSetHandle;

/// One-shot lazy-init handle for the gameplay ActionSet. Registered on
/// first call; subsequent calls return the same handle so a second entry
/// into GameState does not hit ActionAlreadyExists.
var gameplay_set: ?ActionSetHandle = null;

/// Returns the gameplay action set handle if registered, null otherwise.
/// Used by Player.poll_inputs to detect whether gameplay is the active
/// top-of-stack set (and so suppress ghost edges on context activation).
pub fn handle() ?ActionSetHandle {
    return gameplay_set;
}

/// Registers the gameplay action set on first call, binds every gameplay
/// action to the platform-appropriate sources, installs the set, and
/// returns the handle. Idempotent across GameState entries.
/// The caller is responsible for pushing the gameplay context.
pub fn init() !ActionSetHandle {
    if (gameplay_set) |h| return h;
    const set = try input.register_action_set("gameplay");

    // --- movement (vector2: x = strafe, y = forward/back) ---
    try input.add_action(set, "move", .vector2);
    try input.bind_action(set, "move", .{ .source = .{ .key = .W }, .component = .y, .multiplier = 1.0 });
    try input.bind_action(set, "move", .{ .source = .{ .key = .S }, .component = .y, .multiplier = -1.0 });
    try input.bind_action(set, "move", .{ .source = .{ .key = .A }, .component = .x, .multiplier = -1.0 });
    try input.bind_action(set, "move", .{ .source = .{ .key = .D }, .component = .x, .multiplier = 1.0 });
    if (ae.platform == .psp) {
        // PSP face buttons drive movement (Circle/Square = strafe, Triangle/Cross = forward/back).
        try input.bind_action(set, "move", .{ .source = .{ .gamepad_button = .B }, .component = .x, .multiplier = 1.0 }); // Circle = right
        try input.bind_action(set, "move", .{ .source = .{ .gamepad_button = .X }, .component = .x, .multiplier = -1.0 }); // Square = left
        try input.bind_action(set, "move", .{ .source = .{ .gamepad_button = .Y }, .component = .y, .multiplier = 1.0 }); // Triangle = forward
        try input.bind_action(set, "move", .{ .source = .{ .gamepad_button = .A }, .component = .y, .multiplier = -1.0 }); // Cross = back
    } else {
        // Desktop: left analog stick drives movement. LeftY is +1 when pushed
        // down, so invert to make forward = +y.
        try input.bind_action(set, "move", .{ .source = .{ .gamepad_axis = .LeftX }, .component = .x, .multiplier = 1.0 });
        try input.bind_action(set, "move", .{ .source = .{ .gamepad_axis = .LeftY }, .component = .y, .multiplier = -1.0 });
    }

    // --- jump / sneak ---
    try input.add_action(set, "jump", .button);
    try input.bind_action(set, "jump", .{ .source = .{ .key = .Space } });
    try input.add_action(set, "sneak", .button);
    try input.bind_action(set, "sneak", .{ .source = .{ .key = .LeftShift } });
    if (ae.platform == .psp) {
        // D-pad up/down on PSP; on desktop the sticks handle movement and
        // the D-pad is free for hotbar cycling.
        try input.bind_action(set, "jump", .{ .source = .{ .gamepad_button = .DpadUp } });
        try input.bind_action(set, "sneak", .{ .source = .{ .gamepad_button = .DpadDown } });
    } else {
        // Desktop gamepad: A = jump, X = sneak (standard platformer layout).
        try input.bind_action(set, "jump", .{ .source = .{ .gamepad_button = .A } });
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
    try input.bind_action(set, "inventory_toggle", .{ .source = .{ .key = .B } });
    if (ae.platform != .psp) {
        try input.bind_action(set, "inventory_toggle", .{ .source = .{ .gamepad_button = .Y } });
    }

    // --- pause trigger ---
    // Same name and bindings as menu_set's ui_pause so ui_input.build_frame
    // polls the right value regardless of which context is on top: while
    // gameplay is the active set, this fires; once pause pushes the menu
    // context, the menu set's ui_pause takes over.
    try input.add_action(set, "ui_pause", .button);
    try input.bind_action(set, "ui_pause", .{ .source = .{ .key = .Escape } });
    try input.bind_action(set, "ui_pause", .{ .source = .{ .gamepad_button = .Start } });

    // --- mouse look (delta-based) ---
    // Multiplier left at 1.0; sensitivity is applied against Options.current
    // at read time in Player.update so an Options change takes effect on the
    // next frame without re-binding.
    try input.add_action(set, "look", .vector2);
    try input.bind_action(set, "look", .{ .source = .{ .mouse_delta = .x }, .component = .x });
    try input.bind_action(set, "look", .{ .source = .{ .mouse_delta = .y }, .component = .y });

    // --- stick look (rate-based, applied as velocity * dt) ---
    try input.add_action(set, "look_stick", .vector2);
    if (ae.platform == .psp) {
        try input.bind_action(set, "look_stick", .{ .source = .{ .gamepad_axis = .LeftX }, .component = .x });
        try input.bind_action(set, "look_stick", .{ .source = .{ .gamepad_axis = .LeftY }, .component = .y });
    } else {
        try input.bind_action(set, "look_stick", .{ .source = .{ .gamepad_axis = .RightX }, .component = .x });
        try input.bind_action(set, "look_stick", .{ .source = .{ .gamepad_axis = .RightY }, .component = .y });
    }

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
    try input.bind_action(set, "playerlist", .{ .source = .{ .key = .Tab } });
    try input.bind_action(set, "playerlist", .{ .source = .{ .gamepad_button = .Back } });

    // --- chat triggers ---
    // chat_open (T): opens a blank input field.
    // chat_cmd (/): opens with '/' pre-typed for commands.
    // chat_send is owned by the chat ActionSet (registered separately by
    // ui/Chat.zig), not gameplay, so Enter does not fire chat_send while
    // gameplay is on top.
    try input.add_action(set, "chat_open", .button);
    try input.bind_action(set, "chat_open", .{ .source = .{ .key = .T } });
    try input.add_action(set, "chat_cmd", .button);
    try input.bind_action(set, "chat_cmd", .{ .source = .{ .key = .Slash } });

    // PSP: Cross (X) confirms / launches the OSK while the social overlay is
    // open. Shares the same button as the 'move' backward action; the OSK
    // fires synchronously so any simultaneous movement is harmless.
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
