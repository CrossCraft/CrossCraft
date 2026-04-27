// Chat overlay.
//
// Stores up to 10 incoming messages (ring buffer) with per-entry age timers.
// Each message is shown in full for 4.5 s, then fades out over 0.5 s.
// When the input field is open all messages are held at full opacity.
//
// T opens a blank input field.  / opens with '/' pre-typed as a command
// prefix.  On desktop the player types via keyboard char events, presses
// Enter to send and Escape to cancel.  On PSP the system OSK is displayed
// immediately when the field opens; the result is sent automatically on
// confirm or discarded on cancel.

const std = @import("std");
const ae = @import("aether");
const Rendering = ae.Rendering;
const input = ae.Core.input;
const proto = @import("common").protocol;

const Player = @import("../player/Player.zig");
const SpriteBatcher = @import("SpriteBatcher.zig");
const FontBatcher = @import("FontBatcher.zig");
const Scaling = @import("Scaling.zig");
const Color = @import("../graphics/Color.zig").Color;
const ui_input = @import("input.zig");

const Self = @This();

// --- Configuration ---

pub const MAX_MESSAGES: u8 = 10;
const MSG_MAX_LEN: u8 = 64;
pub const INPUT_MAX_LEN: u8 = 64;

/// Seconds a message is held at full opacity before fading begins.
const MSG_SHOW_SECS: f32 = 4.5;
/// Duration of the fade-out after MSG_SHOW_SECS.
const MSG_FADE_SECS: f32 = 0.5;
const MSG_TOTAL_SECS: f32 = MSG_SHOW_SECS + MSG_FADE_SECS;

// Layout constants (logical pixels).
const ROW_H: i16 = 10; // Height of one message or input row.
const MSG_W: i16 = 200; // Width of the per-message background strip.
const LEFT_PAD: i16 = 2; // Distance from the screen left edge.
// The hotbar is 22 px tall and sits 1 px above the bottom, so it occupies
// the bottom 23 logical pixels.  Add 3 px breathing room -> 26 px, matching
// the hotbar tooltip offset used elsewhere in the codebase.
const BOTTOM_PAD: i16 = 26; // Baseline distance above the hotbar.

// Layer values: below playerlist (244+), inventory (247+), and hotbar (250+).
const MSG_BG_LAYER: u8 = 241;
const MSG_TEXT_LAYER: u8 = 242;
const INPUT_BG_LAYER: u8 = 243;
const INPUT_TEXT_LAYER: u8 = 244;

// --- Data types ---

const Entry = struct {
    text: [MSG_MAX_LEN]u8,
    text_len: u8,
    age: f32,
};

// --- Fields ---

/// Ring buffer of received messages, oldest at head, newest just before head.
messages: [MAX_MESSAGES]Entry,
msg_head: u8, // Next-write slot (wraps at MAX_MESSAGES).
msg_count: u8, // Number of valid entries (0..MAX_MESSAGES).

/// True while the input field is visible.
open: bool,
/// Characters typed so far (ASCII, up to INPUT_MAX_LEN bytes).
buf: [INPUT_MAX_LEN]u8,
len: u8,
saved_mouse_captured: bool,
ui_repeat: ui_input.Repeat,
/// Set when open_overlay() is called; cleared on the first update() so the
/// trigger key's char event is discarded rather than inserted.
just_opened: bool,
/// PSP only: set by open_overlay(), serviced by GameState at the top of
/// the next update() after the GE is idle.
psp_osk_pending: bool,

// --- Init ---

pub fn init() Self {
    return .{
        .messages = std.mem.zeroes([MAX_MESSAGES]Entry),
        .msg_head = 0,
        .msg_count = 0,
        .open = false,
        .buf = undefined,
        .len = 0,
        .saved_mouse_captured = true,
        .ui_repeat = .{},
        .just_opened = false,
        .psp_osk_pending = false,
    };
}

// --- Data mutations ---

/// Called by ClientConn.on_message.  Trims the 64-byte space-padded wire
/// representation and stores the message in the ring buffer.
pub fn receive(self: *Self, raw: []const u8) void {
    // Trim trailing spaces / nulls to find the real length.
    var len: u8 = 0;
    const lim = @min(raw.len, MSG_MAX_LEN);
    {
        var i: usize = 0;
        while (i < lim) : (i += 1) {
            if (raw[i] != ' ' and raw[i] != 0) len = @intCast(i + 1);
        }
    }
    if (len == 0) return;

    const slot = &self.messages[self.msg_head];
    @memcpy(slot.text[0..len], raw[0..len]);
    slot.text_len = len;
    slot.age = 0;
    self.msg_head = (self.msg_head + 1) % MAX_MESSAGES;
    if (self.msg_count < MAX_MESSAGES) self.msg_count += 1;
}

// --- Overlay control ---

/// Open the input field.  If slash_prefix is true, '/' is pre-typed so the
/// player can immediately continue a command.  On PSP this also arms the
/// deferred OSK request that GameState services on the next frame.
pub fn open_overlay(self: *Self, player: *Player, slash_prefix: bool) void {
    if (self.open) return;
    self.open = true;
    self.len = 0;
    if (slash_prefix) {
        self.buf[0] = '/';
        self.len = 1;
    }
    self.saved_mouse_captured = player.mouse_captured;
    player.mouse_captured = false;
    input.set_mouse_relative_mode(false);
    self.ui_repeat = .{};
    self.just_opened = true;
    if (ae.platform == .psp) self.psp_osk_pending = true;
}

/// PSP social mode: open the input field to show the cursor but do NOT arm
/// the OSK.  GameState will arm it when Cross (X) is pressed.  No
/// `just_opened` discard is needed because there is no triggering keyboard
/// char event on PSP.
pub fn open_overlay_social(self: *Self, player: *Player) void {
    if (self.open) return;
    self.open = true;
    self.len = 0;
    self.saved_mouse_captured = player.mouse_captured;
    player.mouse_captured = false;
    input.set_mouse_relative_mode(false);
    self.ui_repeat = .{};
    self.just_opened = false;
    // psp_osk_pending intentionally not set here.
}

pub fn close_overlay(self: *Self, player: *Player) void {
    if (!self.open) return;
    self.open = false;
    self.len = 0;
    player.mouse_captured = self.saved_mouse_captured;
    input.set_mouse_relative_mode(self.saved_mouse_captured);
    player.look_delta = .{ 0, 0 };
}

// --- Per-frame tick (call every frame regardless of open state) ---

/// Age all stored messages.  Messages that are closed will fade; messages
/// while open are frozen at their current age (held fully visible).
pub fn tick(self: *Self, dt: f32) void {
    if (self.open) return;
    var i: u8 = 0;
    while (i < self.msg_count) : (i += 1) {
        self.messages[i].age += dt;
    }
}

// --- Update (call every frame while open) ---

/// Process keyboard input.  `send_edge` is true when the chat_send action
/// fired this frame (Enter key only, distinct from ui_confirm which also
/// fires on Space).
pub fn update(
    self: *Self,
    ui_in: *const ui_input.UiInput,
    send_edge: bool,
    player: *Player,
) void {
    std.debug.assert(self.open);

    // Discard the triggering key's char on the frame the overlay opens.
    if (self.just_opened) {
        self.just_opened = false;
        return;
    }

    // Backspace (with autorepeat via ui_repeat).
    if (ui_in.backspace and self.len > 0) self.len -= 1;

    for (ui_in.char_buf[0..ui_in.char_count]) |ch| {
        if (self.len < INPUT_MAX_LEN) {
            self.buf[self.len] = ch;
            self.len += 1;
        }
    }

    if (send_edge) {
        send_message(self, player);
        self.close_overlay(player);
        return;
    }

    if (ui_in.cancel_edge) self.close_overlay(player);
}

// --- PSP OSK (call from GameState at the top of update, after end_frame) ---

/// Blocking PSP system OSK.  Shows the keyboard, waits for confirm/cancel,
/// then sends the result (if confirmed) and closes the overlay.
/// Must be called when the GE is idle (top of update, after end_frame).
pub fn service_psp_osk(self: *Self, player: *Player) void {
    var desc: [16:0]u16 = .{0} ** 16;
    for ("Chat message", 0..) |ch, i| {
        if (i < 15) desc[i] = @intCast(ch);
    }
    var out: [INPUT_MAX_LEN + 1]u16 = .{0} ** (INPUT_MAX_LEN + 1);
    const result = ae.Psp.showOSK(&desc, &out, INPUT_MAX_LEN);
    if (result != 0) {
        self.close_overlay(player);
        return;
    }
    var len: u8 = 0;
    for (out) |wc| {
        if (wc == 0) break;
        if (len >= INPUT_MAX_LEN) break;
        if (wc <= 127) {
            self.buf[len] = @intCast(wc);
            len += 1;
        }
    }
    self.len = len;
    send_message(self, player);
    self.close_overlay(player);
}

// --- Draw ---

pub fn draw(self: *const Self, batcher: *SpriteBatcher, fonts: *FontBatcher, y_shift: i16) void {
    // y_shift is the number of logical pixels the HUD has been pushed upward
    // by the controller-tooltip strip.  When it is non-zero, every chat row
    // and the input field ride upward by the same amount so they sit above
    // the strip instead of overlapping it.
    const base: i16 = BOTTOM_PAD + y_shift;
    // --- Message history ---
    // Iterate from newest to oldest; newest draws closest to the bottom.
    // When the input field is open, messages are offset one row upward to
    // leave room for it.
    var drawn: u8 = 0;
    var i: u8 = 0;
    while (i < self.msg_count) : (i += 1) {
        // Ring buffer index: i=0 is the newest entry.
        const idx = (self.msg_head + MAX_MESSAGES - 1 - i) % MAX_MESSAGES;
        const entry = &self.messages[idx];

        const alpha = compute_alpha(entry.age, self.open);
        if (alpha == 0) continue;

        // Vertical position relative to screen bottom-left.  Negative y means
        // "above the bottom edge."  The baseline sits above the hotbar; when
        // the input field is open, messages are offset one extra row upward.
        const input_offset: i16 = if (self.open) ROW_H else 0;
        const row_y: i16 = -(base + input_offset + @as(i16, drawn) * ROW_H);

        // Proportionally fade the dark background to match the text alpha.
        const bg_a: u8 = @intFromFloat(160.0 * (@as(f32, @floatFromInt(alpha)) / 255.0));
        batcher.add_sprite(&.{
            .texture = &Rendering.Texture.Default,
            .pos_offset = .{ .x = LEFT_PAD, .y = row_y },
            .pos_extent = .{ .x = MSG_W, .y = ROW_H },
            .tex_offset = .{ .x = 0, .y = 0 },
            .tex_extent = .{ .x = 1, .y = 1 },
            .color = Color.rgba(0, 0, 0, bg_a),
            .layer = MSG_BG_LAYER,
            .reference = .bottom_left,
            .origin = .bottom_left,
        });
        fonts.add_text(&.{
            .str = entry.text[0..entry.text_len],
            .pos_x = LEFT_PAD + 2,
            .pos_y = row_y,
            .color = Color.rgba(255, 255, 255, alpha),
            .shadow_color = Color.rgba(50, 50, 50, alpha),
            .spacing = 0,
            .layer = MSG_TEXT_LAYER,
            .reference = .bottom_left,
            .origin = .bottom_left,
        });

        drawn += 1;
        if (drawn >= MAX_MESSAGES) break;
    }

    if (!self.open) return;

    // --- Input field ---
    // Dark background strip for the input row, flush with the hotbar top.
    batcher.add_sprite(&.{
        .texture = &Rendering.Texture.Default,
        .pos_offset = .{ .x = LEFT_PAD, .y = -base },
        .pos_extent = .{ .x = MSG_W, .y = ROW_H },
        .tex_offset = .{ .x = 0, .y = 0 },
        .tex_extent = .{ .x = 1, .y = 1 },
        .color = Color.rgba(0, 0, 0, 192),
        .layer = INPUT_BG_LAYER,
        .reference = .bottom_left,
        .origin = .bottom_left,
    });

    // Visual "> " prompt prefix (not part of the message buffer).
    const text_x: i16 = LEFT_PAD + 2;
    const prefix = "> ";
    fonts.add_text(&.{
        .str = prefix,
        .pos_x = text_x,
        .pos_y = -base,
        .color = .white_fg,
        .shadow_color = .menu_gray,
        .spacing = 0,
        .layer = INPUT_TEXT_LAYER,
        .reference = .bottom_left,
        .origin = .bottom_left,
    });
    const prefix_w: i16 = fonts.string_width(prefix, 0, 1);

    // Typed text, offset past the prefix.
    if (self.len > 0) {
        fonts.add_text(&.{
            .str = self.buf[0..self.len],
            .pos_x = text_x + prefix_w,
            .pos_y = -base,
            .color = .white_fg,
            .shadow_color = .menu_gray,
            .spacing = 0,
            .layer = INPUT_TEXT_LAYER,
            .reference = .bottom_left,
            .origin = .bottom_left,
        });
    }

    // Cursor "_" placed immediately after the typed text (or after the prefix when empty).
    const typed_w: i16 = if (self.len > 0) fonts.string_width(self.buf[0..self.len], 0, 1) else 0;
    fonts.add_text(&.{
        .str = "_",
        .pos_x = text_x + prefix_w + typed_w + 1,
        .pos_y = -base,
        .color = .white_fg,
        .shadow_color = .menu_gray,
        .spacing = 0,
        .layer = INPUT_TEXT_LAYER,
        .reference = .bottom_left,
        .origin = .bottom_left,
    });
}

// --- Helpers ---

fn send_message(self: *Self, player: *Player) void {
    if (self.len == 0) return;
    proto.send_message(player.writer, -1, self.buf[0..self.len]) catch {};
    player.writer.flush() catch {};
}

fn compute_alpha(age: f32, chat_open: bool) u8 {
    if (chat_open) return 255;
    if (age < MSG_SHOW_SECS) return 255;
    if (age >= MSG_TOTAL_SECS) return 0;
    const t = (age - MSG_SHOW_SECS) / MSG_FADE_SECS;
    return @intFromFloat((1.0 - t) * 255.0);
}
