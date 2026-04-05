/// Input action registration and default bindings.
/// Keyboard + mouse on desktop, gamepad/analog + D-pad on PSP.
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
    // Left stick (PSP analog nub)
    try input.bind_action("move", .{ .source = .{ .gamepad_axis = .LeftX }, .component = .x });
    try input.bind_action("move", .{ .source = .{ .gamepad_axis = .LeftY }, .component = .y, .multiplier = -1.0 });

    // ---- jump / sneak ----
    try input.register_action("jump", .button);
    try input.bind_action("jump", .{ .source = .{ .key = .Space } });
    try input.bind_action("jump", .{ .source = .{ .gamepad_button = .DpadUp } });
    try input.register_action("sneak", .button);
    try input.bind_action("sneak", .{ .source = .{ .key = .LeftShift } });
    try input.bind_action("sneak", .{ .source = .{ .gamepad_button = .DpadDown } });

    // ---- noclip toggle ----
    try input.register_action("noclip", .button);
    try input.bind_action("noclip", .{ .source = .{ .gamepad_button = .Back } });
    try input.bind_action("noclip", .{ .source = .{ .key = .X } });

    // ---- mouse look (delta-based) ----
    try input.register_action("look", .vector2);
    try input.bind_action("look", .{ .source = .{ .mouse_relative = .X }, .component = .x });
    try input.bind_action("look", .{ .source = .{ .mouse_relative = .Y }, .component = .y });

    // ---- stick / face-button look (rate-based, applied as velocity * dt) ----
    try input.register_action("look_stick", .vector2);
    // Right stick (standard gamepad)
    try input.bind_action("look_stick", .{ .source = .{ .gamepad_axis = .RightX }, .component = .x });
    try input.bind_action("look_stick", .{ .source = .{ .gamepad_axis = .RightY }, .component = .y });
    // Face buttons (PSP has no right stick)
    try input.bind_action("look_stick", .{ .source = .{ .gamepad_button = .B }, .component = .x, .multiplier = 1.0 }); // Circle = right
    try input.bind_action("look_stick", .{ .source = .{ .gamepad_button = .X }, .component = .x, .multiplier = -1.0 }); // Square = left
    try input.bind_action("look_stick", .{ .source = .{ .gamepad_button = .A }, .component = .y, .multiplier = 1.0 }); // Cross  = down
    try input.bind_action("look_stick", .{ .source = .{ .gamepad_button = .Y }, .component = .y, .multiplier = -1.0 }); // Triangle = up

    // ---- escape / menu ----
    try input.register_action("escape", .button);
    try input.bind_action("escape", .{ .source = .{ .key = .Escape } });
    try input.bind_action("escape", .{ .source = .{ .gamepad_button = .Start } });
}
