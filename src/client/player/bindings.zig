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
    if (ae.platform == .psp) {
        // PSP face buttons drive movement (Circle/Square = strafe, Triangle/Cross = forward/back).
        try input.bind_action("move", .{ .source = .{ .gamepad_button = .B }, .component = .x, .multiplier = 1.0 }); // Circle = right
        try input.bind_action("move", .{ .source = .{ .gamepad_button = .X }, .component = .x, .multiplier = -1.0 }); // Square = left
        try input.bind_action("move", .{ .source = .{ .gamepad_button = .Y }, .component = .y, .multiplier = 1.0 }); // Triangle = forward
        try input.bind_action("move", .{ .source = .{ .gamepad_button = .A }, .component = .y, .multiplier = -1.0 }); // Cross = back
    } else {
        // Desktop: left analog stick drives movement. LeftY is +1 when pushed
        // down, so invert to make forward = +y.
        try input.bind_action("move", .{ .source = .{ .gamepad_axis = .LeftX }, .component = .x, .multiplier = 1.0 });
        try input.bind_action("move", .{ .source = .{ .gamepad_axis = .LeftY }, .component = .y, .multiplier = -1.0 });
    }

    // ---- jump / sneak ----
    try input.register_action("jump", .button);
    try input.bind_action("jump", .{ .source = .{ .key = .Space } });
    try input.register_action("sneak", .button);
    try input.bind_action("sneak", .{ .source = .{ .key = .LeftShift } });
    if (ae.platform == .psp) {
        // D-pad up/down on PSP; on desktop the sticks handle movement and
        // the D-pad is free for hotbar cycling.
        try input.bind_action("jump", .{ .source = .{ .gamepad_button = .DpadUp } });
        try input.bind_action("sneak", .{ .source = .{ .gamepad_button = .DpadDown } });
    } else {
        // Desktop gamepad: A = jump, X = sneak (standard platformer layout).
        try input.bind_action("jump", .{ .source = .{ .gamepad_button = .A } });
        try input.bind_action("sneak", .{ .source = .{ .gamepad_button = .X } });
    }

    // ---- noclip toggle ----
    // Debug-only dev tool. Not available in release builds and never on PSP,
    // so the gamepad Back button stays free for the inventory overlay.
    if (comptime builtin.mode == .Debug and ae.platform != .psp) {
        try input.register_action("noclip", .button);
        try input.bind_action("noclip", .{ .source = .{ .key = .X } });
    }

    // ---- inventory toggle ----
    // Opens the Classic block-picker overlay. Desktop keyboard uses B and
    // gamepad uses Y; PSP uses L+R chord (detected in Player via shoulder_l /
    // shoulder_r callbacks).
    try input.register_action("inventory_toggle", .button);
    try input.bind_action("inventory_toggle", .{ .source = .{ .key = .B } });
    if (ae.platform != .psp) {
        try input.bind_action("inventory_toggle", .{ .source = .{ .gamepad_button = .Y } });
    }

    // ---- mouse look (delta-based) ----
    try input.register_action("look", .vector2);
    try input.bind_action("look", .{ .source = .{ .mouse_relative = .X }, .component = .x });
    try input.bind_action("look", .{ .source = .{ .mouse_relative = .Y }, .component = .y });

    // ---- stick look (rate-based, applied as velocity * dt) ----
    try input.register_action("look_stick", .vector2);
    if (ae.platform == .psp) {
        // PSP analog nub: no right stick exists, so left stick aims the camera.
        try input.bind_action("look_stick", .{ .source = .{ .gamepad_axis = .LeftX }, .component = .x });
        try input.bind_action("look_stick", .{ .source = .{ .gamepad_axis = .LeftY }, .component = .y });
    } else {
        // Desktop: right stick for look, left stick is reserved for movement.
        try input.bind_action("look_stick", .{ .source = .{ .gamepad_axis = .RightX }, .component = .x });
        try input.bind_action("look_stick", .{ .source = .{ .gamepad_axis = .RightY }, .component = .y });
    }

    // ---- break / place ----
    // Keyboard/mouse always bound. On desktop the analog triggers also map:
    // RT = break, LT = place. PSP uses shoulder_l / shoulder_r callbacks for
    // chord detection (L+R = inventory) instead of binding break/place here.
    try input.register_action("break", .button);
    try input.bind_action("break", .{ .source = .{ .mouse_button = .Left } });
    try input.register_action("place", .button);
    try input.bind_action("place", .{ .source = .{ .mouse_button = .Right } });
    if (ae.platform != .psp) {
        // Triggers report -1 fully released .. 1 fully pressed; button actions
        // fire when any contribution is >0, so past halfway registers as a press.
        try input.bind_action("break", .{ .source = .{ .gamepad_axis = .RightTrigger } });
        try input.bind_action("place", .{ .source = .{ .gamepad_axis = .LeftTrigger } });
    }

    // ---- gamepad shoulder buttons (L/R) ----
    // PSP only: separated from break/place so the L+R chord can toggle the
    // inventory without firing a spurious break or place on the same frame.
    // R = break, L = place, L+R = inventory toggle.  Desktop uses the triggers
    // for break/place and leaves the bumpers free for hotbar cycling.
    try input.register_action("shoulder_r", .button);
    try input.register_action("shoulder_l", .button);
    if (ae.platform == .psp) {
        try input.bind_action("shoulder_r", .{ .source = .{ .gamepad_button = .RButton } });
        try input.bind_action("shoulder_l", .{ .source = .{ .gamepad_button = .LButton } });
    }

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
    if (ae.platform != .psp) {
        // Desktop gamepad: bumpers cycle the hotbar (triggers are break/place).
        try input.bind_action("hotbar_left", .{ .source = .{ .gamepad_button = .LButton } });
        try input.bind_action("hotbar_right", .{ .source = .{ .gamepad_button = .RButton } });
    }

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
