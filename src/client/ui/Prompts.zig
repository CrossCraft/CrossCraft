//! Common menu and HUD prompts for the active input style.

const Buttons = @import("Buttons.zig");
const Options = @import("../Options.zig");
const PromptStrip = @import("PromptStrip.zig");

pub const Prompt = PromptStrip.Prompt;

fn confirm_prompt(label: []const u8) Prompt {
    const button: Buttons.Button = switch (Buttons.resolve_style()) {
        .kbm => .EnterKey,
        .nintendo, .xbox, .playstation, .psp => .A,
    };
    return .{ .chord = .{ button, null }, .label = label };
}

fn cancel_prompt(label: []const u8) Prompt {
    const button: Buttons.Button = switch (Buttons.resolve_style()) {
        .kbm => .EscapeKey,
        .nintendo, .xbox, .playstation, .psp => .B,
    };
    return .{ .chord = .{ button, null }, .label = label };
}

pub fn select() Prompt {
    return confirm_prompt("Select");
}

pub fn edit() Prompt {
    return confirm_prompt("Edit");
}

pub fn adjust() Prompt {
    return confirm_prompt("Adjust");
}

pub fn done() Prompt {
    return confirm_prompt("Done");
}

pub fn back() Prompt {
    return cancel_prompt("Back");
}

pub fn exit_adjust() Prompt {
    return cancel_prompt("Done");
}

pub fn left_right() Prompt {
    return switch (Buttons.resolve_style()) {
        .kbm => .{ .chord = .{ .BlankKey, null }, .label = "Adjust", .letter_overlay = "<>" },
        .nintendo, .xbox, .playstation, .psp => .{ .chord = .{ .DpadLeft, .DpadRight }, .label = "Adjust" },
    };
}

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
        .kbm => .{ .chord = .{ .Rmb, null }, .label = "Place" },
        .nintendo, .xbox, .playstation => .{ .chord = .{ .RTrigger, null }, .label = "Place" },
        .psp => .{ .chord = .{ .LButton, null }, .label = "Place" },
    };
}

pub fn break_() Prompt {
    if (Options.uses_old_3ds_controls()) {
        return .{ .chord = .{ .RButton, null }, .label = "Break" };
    }
    return switch (Buttons.resolve_style()) {
        .kbm => .{ .chord = .{ .Lmb, null }, .label = "Break" },
        .nintendo, .xbox, .playstation => .{ .chord = .{ .LTrigger, null }, .label = "Break" },
        .psp => .{ .chord = .{ .RButton, null }, .label = "Break" },
    };
}

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
    return confirm_prompt("Send");
}

pub fn cancel() Prompt {
    return cancel_prompt("Cancel");
}
