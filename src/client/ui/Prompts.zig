//! Named action helpers returning `Prompt` values for common menu and
//! HUD actions.  Each helper inspects the currently-resolved
//! `Buttons.Style` so prompts update live when the user cycles the
//! controller-tooltip style in Options.

const Buttons = @import("Buttons.zig");
const Options = @import("../Options.zig");
const PromptStrip = @import("PromptStrip.zig");

pub const Prompt = PromptStrip.Prompt;

// --- menu actions ---

pub fn select() Prompt {
    return switch (Buttons.resolve_style()) {
        .kbm => .{ .chord = .{ .EnterKey, null }, .label = "Select" },
        .nintendo, .xbox, .playstation, .psp => .{ .chord = .{ .A, null }, .label = "Select" },
    };
}

pub fn edit() Prompt {
    return switch (Buttons.resolve_style()) {
        .kbm => .{ .chord = .{ .EnterKey, null }, .label = "Edit" },
        .nintendo, .xbox, .playstation, .psp => .{ .chord = .{ .A, null }, .label = "Edit" },
    };
}

pub fn adjust() Prompt {
    return switch (Buttons.resolve_style()) {
        .kbm => .{ .chord = .{ .EnterKey, null }, .label = "Adjust" },
        .nintendo, .xbox, .playstation, .psp => .{ .chord = .{ .A, null }, .label = "Adjust" },
    };
}

pub fn done() Prompt {
    return switch (Buttons.resolve_style()) {
        .kbm => .{ .chord = .{ .EnterKey, null }, .label = "Done" },
        .nintendo, .xbox, .playstation, .psp => .{ .chord = .{ .A, null }, .label = "Done" },
    };
}

pub fn back() Prompt {
    return switch (Buttons.resolve_style()) {
        .kbm => .{ .chord = .{ .EscapeKey, null }, .label = "Back" },
        .nintendo, .xbox, .playstation, .psp => .{ .chord = .{ .B, null }, .label = "Back" },
    };
}

pub fn exit_adjust() Prompt {
    return switch (Buttons.resolve_style()) {
        .kbm => .{ .chord = .{ .EscapeKey, null }, .label = "Done" },
        .nintendo, .xbox, .playstation, .psp => .{ .chord = .{ .B, null }, .label = "Done" },
    };
}

pub fn left_right() Prompt {
    return switch (Buttons.resolve_style()) {
        .kbm => .{ .chord = .{ .BlankKey, null }, .label = "Adjust", .letter_overlay = "<>" },
        .nintendo, .xbox, .playstation, .psp => .{ .chord = .{ .DpadLeft, .DpadRight }, .label = "Adjust" },
    };
}

// --- in-game HUD actions ---

pub fn inventory() Prompt {
    if (Options.uses_old_3ds_controls()) {
        return .{ .chord = .{ .LButton, .RButton }, .label = "Inventory" };
    }
    return switch (Buttons.resolve_style()) {
        .kbm => .{ .chord = .{ .BlankKey, null }, .label = "Inventory", .letter_overlay = Options.pc_key_prompt_label(Options.current.key_inventory) },
        .nintendo, .xbox, .playstation => .{ .chord = .{ .Y, null }, .label = "Inventory" },
        .psp => .{ .chord = .{ .LButton, .RButton }, .label = "Inventory" },
    };
}

pub fn place() Prompt {
    if (Options.uses_old_3ds_controls()) {
        return .{ .chord = .{ .LButton, null }, .label = "Place" };
    }
    return switch (Buttons.resolve_style()) {
        .kbm => .{ .chord = .{ .RMB, null }, .label = "Place" },
        .nintendo, .xbox, .playstation => .{ .chord = .{ .RTrigger, null }, .label = "Place" },
        .psp => .{ .chord = .{ .LButton, null }, .label = "Place" },
    };
}

pub fn break_() Prompt {
    if (Options.uses_old_3ds_controls()) {
        return .{ .chord = .{ .RButton, null }, .label = "Break" };
    }
    return switch (Buttons.resolve_style()) {
        .kbm => .{ .chord = .{ .LMB, null }, .label = "Break" },
        .nintendo, .xbox, .playstation => .{ .chord = .{ .LTrigger, null }, .label = "Break" },
        .psp => .{ .chord = .{ .RButton, null }, .label = "Break" },
    };
}

// --- playerlist / chat overlays ---

/// PSP social-mode hint.  No desktop equivalent since the list is shown
/// while Tab is held.
pub fn exit_list() Prompt {
    return switch (Buttons.resolve_style()) {
        .kbm => .{ .chord = .{ .EscapeKey, null }, .label = "Exit" },
        .nintendo, .xbox, .playstation, .psp => .{ .chord = .{ .Select, null }, .label = "Exit" },
    };
}

pub fn chat() Prompt {
    return switch (Buttons.resolve_style()) {
        .kbm => .{ .chord = .{ .BlankKey, null }, .label = "Chat", .letter_overlay = "T" },
        .nintendo, .xbox, .playstation, .psp => .{ .chord = .{ .A, null }, .label = "Chat" },
    };
}

pub fn send() Prompt {
    return switch (Buttons.resolve_style()) {
        .kbm => .{ .chord = .{ .EnterKey, null }, .label = "Send" },
        .nintendo, .xbox, .playstation, .psp => .{ .chord = .{ .A, null }, .label = "Send" },
    };
}

pub fn cancel() Prompt {
    return switch (Buttons.resolve_style()) {
        .kbm => .{ .chord = .{ .EscapeKey, null }, .label = "Cancel" },
        .nintendo, .xbox, .playstation, .psp => .{ .chord = .{ .B, null }, .label = "Cancel" },
    };
}
