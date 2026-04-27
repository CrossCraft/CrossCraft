//! Named action helpers returning `Prompt` values for common menu and
//! HUD actions.  Each helper inspects the currently-resolved
//! `Buttons.Style` so prompts update live when the user cycles the
//! controller-tooltip style in Options.

const Buttons = @import("Buttons.zig");
const PromptStrip = @import("PromptStrip.zig");

pub const Prompt = PromptStrip.Prompt;

// --- menu actions ---

pub fn select() Prompt {
    return switch (Buttons.resolve_style()) {
        .kbm => .{ .chord = .{ .EnterKey, null }, .label = "Select" },
        .nintendo, .xbox, .playstation, .psp => .{ .chord = .{ .A, null }, .label = "Select" },
    };
}

pub fn back() Prompt {
    return switch (Buttons.resolve_style()) {
        .kbm => .{ .chord = .{ .EscapeKey, null }, .label = "Back" },
        .nintendo, .xbox, .playstation, .psp => .{ .chord = .{ .B, null }, .label = "Back" },
    };
}

// --- in-game HUD actions ---

pub fn inventory() Prompt {
    return switch (Buttons.resolve_style()) {
        .kbm => .{ .chord = .{ .BlankKey, null }, .label = "Inventory", .letter_overlay = "B" },
        .nintendo, .xbox, .playstation => .{ .chord = .{ .Y, null }, .label = "Inventory" },
        .psp => .{ .chord = .{ .LButton, .RButton }, .label = "Inventory" },
    };
}

pub fn place() Prompt {
    return switch (Buttons.resolve_style()) {
        .kbm => .{ .chord = .{ .RMB, null }, .label = "Place" },
        .nintendo, .xbox, .playstation => .{ .chord = .{ .RTrigger, null }, .label = "Place" },
        .psp => .{ .chord = .{ .LButton, null }, .label = "Place" },
    };
}

pub fn break_() Prompt {
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
