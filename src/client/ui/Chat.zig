// Chat overlay.
//
// Stores up to 10 incoming messages (ring buffer) with per-entry age timers.
// Each message is shown in full for 4.5 s, then fades out over 0.5 s.
// When the input field is open all messages are held at full opacity.
//
// Text input is owned by Aether's TextInputSession. On desktop the player
// types interactively via the OS text path; on PSP the platform backend's
// `begin_text_input_session` hook invokes the system OSK synchronously and
// the session returns in terminal state, which Chat services on the same
// frame the overlay opens. There is no PSP branch in the text path itself.
//
// T opens a blank input field. / opens with '/' inserted into the input.
// Enter (chat_send) submits, Escape (chat_cancel) discards.

const std = @import("std");
const ae = @import("aether");
const input = ae.Core.input;
const proto = @import("core").protocol;

const Player = @import("../player/Player.zig");
const FontBatcher = ae.UI.FontBatcher;
const UiDrawList = @import("UiDrawList.zig");
const Scaling = ae.UI.Scaling;
const Colors = @import("../graphics/Color.zig");
const Color = Colors.Color;
const TextWrap = @import("TextWrap.zig");
const ui_input = @import("input.zig");

const Self = @This();

// --- Configuration ---

pub const MAX_MESSAGES: u8 = 10;
const MSG_MAX_LEN: u8 = 96;
pub const INPUT_MAX_LEN: u8 = 64;

const MSG_SHOW_SECS: f32 = 4.5;
const MSG_FADE_SECS: f32 = 0.5;
const MSG_TOTAL_SECS: f32 = MSG_SHOW_SECS + MSG_FADE_SECS;

const ROW_H: i16 = 10;
const MSG_W: i16 = 200;
const LEFT_PAD: i16 = 2;
const BOTTOM_PAD: i16 = 26;
const TEXT_PAD_X: i16 = 2;
const TEXT_W: i16 = MSG_W - 2 * TEXT_PAD_X;

const HISTORY_LINE_LIMIT: usize = MAX_MESSAGES;
// Glyph tiles are 8 px wide with a 1 px gap, so the 64-byte Classic text
// limit plus the prompt cannot exceed four 196 px visual rows.
const MSG_WRAP_MAX_LINES: usize = 4;
const INPUT_WRAP_MAX_LINES: usize = 4;
const INPUT_PROMPT = "> ";
const INPUT_TEXT_MAX_BYTES: usize = @as(usize, INPUT_MAX_LEN) + INPUT_PROMPT.len;
const WRAP_LINE_MAX_BYTES: usize = INPUT_TEXT_MAX_BYTES + 2;
const RENDER_LINE_MAX: usize = HISTORY_LINE_LIMIT + INPUT_WRAP_MAX_LINES;

const MSG_BG_LAYER: u8 = 241;
const MSG_TEXT_LAYER: u8 = 242;
const INPUT_BG_LAYER: u8 = 243;
const INPUT_TEXT_LAYER: u8 = 244;

// --- Action set ---

var chat_set: ?input.ActionSetHandle = null;
var chat_send: input.ActionHandle = .none;
var chat_cancel: input.ActionHandle = .none;

fn ensure_chat_set(sys: *input.InputSystem) !input.ActionSetHandle {
    if (chat_set) |h| return h;
    const set = try sys.register_action_set("chat");

    chat_send = try sys.add_action(set, "chat_send", .button);
    try sys.bind_action(chat_send, &.{ .source = .{ .key = .Enter } });
    try sys.bind_action(chat_send, &.{ .source = .{ .gamepad_button = .A } });

    chat_cancel = try sys.add_action(set, "chat_cancel", .button);
    try sys.bind_action(chat_cancel, &.{ .source = .{ .key = .Escape } });
    try sys.bind_action(chat_cancel, &.{ .source = .{ .gamepad_button = .B } });
    // Controller Select/Back toggles social mode -- pressing it again with
    // chat already open exits without sending.
    try sys.bind_action(chat_cancel, &.{ .source = .{ .gamepad_button = .Back } });

    try sys.install_action_set(set);
    chat_set = set;
    return set;
}

// --- Data types ---

const Entry = struct {
    text: [MSG_MAX_LEN]u8,
    text_len: u8,
    age: f32,
};

// --- Fields ---

messages: [MAX_MESSAGES]Entry,
msg_head: u8,
msg_count: u8,

/// True while the chat panel is visible (input field, even if no active
/// text session yet -- e.g. controller social mode shows the panel before
/// the user starts chat entry).
open: bool,
/// Set when the chat overlay is open AND a TextInputSession is in flight.
/// Distinct from `open` so controller social mode can show the panel without
/// yet having armed text entry.
session_active: bool,
prev_send: input.ButtonState,
prev_cancel: input.ButtonState,
/// Suppresses a ghost rising edge on the frame chat activates with
/// chat_send / chat_cancel still held from the press that opened it.
chat_was_active: bool,
render_lines: [RENDER_LINE_MAX][WRAP_LINE_MAX_BYTES]u8,
render_line_count: u8,

// --- Init ---

pub fn init() Self {
    return .{
        .messages = std.mem.zeroes([MAX_MESSAGES]Entry),
        .msg_head = 0,
        .msg_count = 0,
        .open = false,
        .session_active = false,
        .prev_send = .released,
        .prev_cancel = .released,
        .chat_was_active = false,
        .render_lines = undefined,
        .render_line_count = 0,
    };
}

// --- Data mutations ---

pub fn receive(self: *Self, raw: []const u8) void {
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

/// Open the chat input field and begin a TextInputSession. On PSP the
/// platform's begin_text_input_session hook invokes the system OSK
/// synchronously; on return the session is already terminal (submitted /
/// cancelled). On desktop the session is left active for the user to type
/// into; chat_send / chat_cancel are polled in `update`.
///
/// `slash_prefix = true` starts the editable input with '/'.
pub fn open_overlay(self: *Self, sys: *input.InputSystem, player: *Player, slash_prefix: bool) void {
    if (self.open) return;
    self.open = true;
    self.prev_send = .released;
    self.prev_cancel = .released;
    self.chat_was_active = false;

    const set = ensure_chat_set(sys) catch {
        self.open = false;
        return;
    };
    sys.push_context(&.{
        .name = "chat",
        .cursor_mode = .visible,
        .actions = set,
        .consumes_text = true,
    }) catch {
        self.open = false;
        return;
    };
    self.begin_session(sys, slash_prefix);

    // PSP returns synchronously with a terminal session; service it now.
    handle_terminal_if_done(self, sys, player);
}

/// Controller social mode: show the chat panel without arming text entry, so
/// the player list can sit alongside it. Confirm starts text entry later.
pub fn open_overlay_social(self: *Self, sys: *input.InputSystem, _: *Player) void {
    if (self.open) return;
    self.open = true;
    self.prev_send = .released;
    self.prev_cancel = .released;
    self.chat_was_active = false;

    const set = ensure_chat_set(sys) catch {
        self.open = false;
        return;
    };
    sys.push_context(&.{
        .name = "chat",
        .cursor_mode = .visible,
        .actions = set,
        .consumes_text = true,
    }) catch {
        self.open = false;
        return;
    };
    // session_active stays false; the panel is empty until confirm starts
    // text entry.
}

fn begin_session(self: *Self, sys: *input.InputSystem, slash_prefix: bool) void {
    const target: input.TextInputTarget = .{ .id = "chat" };
    const slash_buf = [_]u8{'/'};
    const opts: input.TextInputOptions = .{
        .max_bytes = INPUT_MAX_LEN,
        .initial = if (slash_prefix) slash_buf[0..1] else null,
    };
    _ = sys.begin_text_input(&target, &opts) catch return;
    self.session_active = true;
}

fn handle_terminal_if_done(self: *Self, sys: *input.InputSystem, player: *Player) void {
    const session = sys.current_text_session() orelse return;
    if (session.status == .submitted) {
        send_session(sys, player);
        self.close_overlay(sys, player);
    } else if (session.status == .cancelled) {
        self.close_overlay(sys, player);
    }
}

pub fn close_overlay(self: *Self, sys: *input.InputSystem, player: *Player) void {
    if (!self.open) return;
    self.open = false;
    if (self.session_active) {
        // cancel_text errors if the session is already terminal; ignore.
        sys.cancel_text() catch {};
        self.session_active = false;
    }
    _ = sys.pop_context() catch {};
    player.look_delta = .{ 0, 0 };
}

// --- Per-frame tick ---

pub fn tick(self: *Self, dt: f32) void {
    if (self.open) return;
    var i: u8 = 0;
    while (i < self.msg_count) : (i += 1) {
        self.messages[i].age += dt;
    }
}

// --- Update (called every frame while open) ---

pub fn update(self: *Self, sys: *input.InputSystem, player: *Player) void {
    std.debug.assert(self.open);

    // Walk frame events for Backspace; trim the session buffer in place.
    if (self.session_active) {
        const session_const = sys.current_text_session() orelse return;
        // Cast away const for the in-place shrink; the session pointer is
        // stable storage and Aether exposes no pop-byte helper.
        const session: *input.TextInputSession = @constCast(session_const);
        for (sys.frame_events()) |ev| {
            switch (ev.kind) {
                .key_down => |k| {
                    if (k.key == .Backspace and session.buffer.items.len > 0) {
                        session.buffer.items.len -= 1;
                    }
                },
                else => {},
            }
        }
    }

    const send = sys.button(chat_send).current;
    const cancel = sys.button(chat_cancel).current;

    const active_now = is_chat_set_active(sys);
    const fresh_activation = active_now and !self.chat_was_active;
    self.chat_was_active = active_now;

    const send_edge = !fresh_activation and self.prev_send == .released and send == .pressed;
    const cancel_edge = !fresh_activation and self.prev_cancel == .released and cancel == .pressed;
    self.prev_send = send;
    self.prev_cancel = cancel;

    if (send_edge) {
        if (self.session_active) {
            sys.submit_text() catch {};
            send_session(sys, player);
            self.close_overlay(sys, player);
        } else {
            // Controller social mode: the panel is open without an active
            // session. Confirm starts text entry; modal OSK platforms return
            // synchronously and desktop keeps the session active.
            self.begin_session(sys, false);
            handle_terminal_if_done(self, sys, player);
        }
        return;
    }

    if (cancel_edge) {
        self.close_overlay(sys, player);
    }
}

fn is_chat_set_active(sys: *input.InputSystem) bool {
    const top = sys.stack_top() orelse return false;
    const set = chat_set orelse return false;
    return @intFromEnum(top.actions) == @intFromEnum(set);
}

// --- Wire send ---

fn send_session(sys: *input.InputSystem, player: *Player) void {
    const session = sys.current_text_session() orelse return;
    const body = session.buffer.items;
    if (body.len == 0) return;

    proto.send_message(player.writer, -1, body) catch {};
    player.writer.flush() catch {};
}

// --- Draw ---

pub fn draw_into(self: *Self, sys: *input.InputSystem, list: *UiDrawList, fonts: *const FontBatcher, y_shift: i16) void {
    self.render_line_count = 0;

    const base: i16 = BOTTOM_PAD + y_shift;

    var input_text: [INPUT_TEXT_MAX_BYTES]u8 = undefined;
    var input_lines: [INPUT_WRAP_MAX_LINES][WRAP_LINE_MAX_BYTES]u8 = undefined;
    var input_lens: [INPUT_WRAP_MAX_LINES]u8 = undefined;
    var input_line_count: u8 = 0;

    // Read the live session buffer; in social mode the session may not yet
    // be active -- show only the prompt in that state.
    const body: []const u8 = if (self.open)
        if (sys.current_text_session()) |s| s.buffer.items else &.{}
    else
        &.{};

    if (self.open) {
        @memcpy(input_text[0..INPUT_PROMPT.len], INPUT_PROMPT);
        const take = @min(body.len, @as(usize, INPUT_MAX_LEN));
        if (take > 0) {
            @memcpy(input_text[INPUT_PROMPT.len .. INPUT_PROMPT.len + take], body[0..take]);
        }
        input_line_count = TextWrap.wrap(
            INPUT_WRAP_MAX_LINES,
            WRAP_LINE_MAX_BYTES,
            fonts,
            input_text[0 .. INPUT_PROMPT.len + take],
            TEXT_W,
            &input_lines,
            &input_lens,
        );
    }

    const input_h: i16 = if (self.open) @as(i16, @intCast(@max(input_line_count, 1))) * ROW_H else 0;

    var drawn_lines: usize = 0;
    var i: u8 = 0;
    while (i < self.msg_count) : (i += 1) {
        const idx = (self.msg_head + MAX_MESSAGES - 1 - i) % MAX_MESSAGES;
        const entry = &self.messages[idx];

        const alpha = compute_alpha(entry.age, self.open);
        if (alpha == 0) continue;
        if (drawn_lines >= HISTORY_LINE_LIMIT) break;

        var msg_lines: [MSG_WRAP_MAX_LINES][WRAP_LINE_MAX_BYTES]u8 = undefined;
        var msg_lens: [MSG_WRAP_MAX_LINES]u8 = undefined;
        const msg_line_count = TextWrap.wrap(
            MSG_WRAP_MAX_LINES,
            WRAP_LINE_MAX_BYTES,
            fonts,
            entry.text[0..entry.text_len],
            TEXT_W,
            &msg_lines,
            &msg_lens,
        );
        if (msg_line_count == 0) continue;

        const remaining = HISTORY_LINE_LIMIT - drawn_lines;
        const visible_lines = @min(@as(usize, msg_line_count), remaining);
        const first_line = @as(usize, msg_line_count) - visible_lines;

        const bg_a: u8 = @intFromFloat(160.0 * (@as(f32, @floatFromInt(alpha)) / 255.0));
        var line_i = first_line;
        while (line_i < @as(usize, msg_line_count)) : (line_i += 1) {
            const row_offset = drawn_lines + (@as(usize, msg_line_count) - 1 - line_i);
            const row_y: i16 = -(base + input_h + @as(i16, @intCast(row_offset)) * ROW_H);

            list.add_rect(&.{
                .pos_offset = .{ .x = LEFT_PAD, .y = row_y },
                .pos_extent = .{ .x = MSG_W, .y = ROW_H },
                .color = Color.rgba(0, 0, 0, bg_a),
                .layer = MSG_BG_LAYER,
                .reference = .bottom_left,
                .origin = .bottom_left,
            });
            if (self.store_render_line(msg_lines[line_i][0..msg_lens[line_i]])) |line| {
                list.add_text(&.{
                    .str = line,
                    .pos_x = LEFT_PAD + TEXT_PAD_X,
                    .pos_y = row_y,
                    .color = Color.rgba(255, 255, 255, alpha),
                    .shadow_color = Color.rgba(50, 50, 50, alpha),
                    .spacing = 0,
                    .layer = MSG_TEXT_LAYER,
                    .reference = .bottom_left,
                    .origin = .bottom_left,
                });
            }
        }

        drawn_lines += visible_lines;
    }

    if (!self.open) return;

    // Input field background.
    list.add_rect(&.{
        .pos_offset = .{ .x = LEFT_PAD, .y = -base },
        .pos_extent = .{ .x = MSG_W, .y = input_h },
        .color = Color.rgba(0, 0, 0, 192),
        .layer = INPUT_BG_LAYER,
        .reference = .bottom_left,
        .origin = .bottom_left,
    });

    const text_x: i16 = LEFT_PAD + TEXT_PAD_X;
    const prompt_w = fonts.string_width(INPUT_PROMPT, 0, 1);
    var last_line_w: i16 = prompt_w;
    var input_i: usize = 0;
    while (input_i < @as(usize, input_line_count)) : (input_i += 1) {
        const row_y: i16 = -(base + @as(i16, @intCast(@as(usize, input_line_count) - 1 - input_i)) * ROW_H);
        if (self.store_render_line(input_lines[input_i][0..input_lens[input_i]])) |line| {
            // Keep the prompt separate from the editable text. Combining
            // them makes FontBatcher add another inter-character gap after
            // the prompt's trailing space, which is especially noticeable
            // before a leading command slash.
            if (input_i == 0 and line.len > 0 and line[0] == INPUT_PROMPT[0]) {
                const prompt_len: usize = @min(line.len, INPUT_PROMPT.len);
                list.add_text(&.{
                    .str = INPUT_PROMPT,
                    .pos_x = text_x,
                    .pos_y = row_y,
                    .color = Colors.white_fg,
                    .shadow_color = Colors.menu_gray,
                    .spacing = 0,
                    .layer = INPUT_TEXT_LAYER,
                    .reference = .bottom_left,
                    .origin = .bottom_left,
                });

                if (prompt_len < line.len) {
                    const body_line = line[prompt_len..];
                    list.add_text(&.{
                        .str = body_line,
                        .pos_x = text_x + prompt_w,
                        .pos_y = row_y,
                        .color = Colors.white_fg,
                        .shadow_color = Colors.menu_gray,
                        .spacing = 0,
                        .layer = INPUT_TEXT_LAYER,
                        .reference = .bottom_left,
                        .origin = .bottom_left,
                    });
                    last_line_w = prompt_w + fonts.string_width(body_line, 0, 1);
                } else {
                    last_line_w = prompt_w;
                }
            } else {
                list.add_text(&.{
                    .str = line,
                    .pos_x = text_x,
                    .pos_y = row_y,
                    .color = Colors.white_fg,
                    .shadow_color = Colors.menu_gray,
                    .spacing = 0,
                    .layer = INPUT_TEXT_LAYER,
                    .reference = .bottom_left,
                    .origin = .bottom_left,
                });
                last_line_w = fonts.string_width(line, 0, 1);
            }
        }
    }
    if (input_line_count == 0) {
        list.add_text(&.{
            .str = INPUT_PROMPT,
            .pos_x = text_x,
            .pos_y = -base,
            .color = Colors.white_fg,
            .shadow_color = Colors.menu_gray,
            .spacing = 0,
            .layer = INPUT_TEXT_LAYER,
            .reference = .bottom_left,
            .origin = .bottom_left,
        });
    }

    list.add_text(&.{
        .str = "_",
        .pos_x = text_x + last_line_w + 1,
        .pos_y = -base,
        .color = Colors.white_fg,
        .shadow_color = Colors.menu_gray,
        .spacing = 0,
        .layer = INPUT_TEXT_LAYER,
        .reference = .bottom_left,
        .origin = .bottom_left,
    });
}

// --- Helpers ---

fn store_render_line(self: *Self, line: []const u8) ?[]const u8 {
    if (line.len == 0 or line.len > WRAP_LINE_MAX_BYTES) return null;
    if (@as(usize, self.render_line_count) >= RENDER_LINE_MAX) return null;

    const idx = @as(usize, self.render_line_count);
    @memcpy(self.render_lines[idx][0..line.len], line);
    self.render_line_count += 1;
    return self.render_lines[idx][0..line.len];
}

fn compute_alpha(age: f32, chat_open: bool) u8 {
    if (chat_open) return 255;
    if (age < MSG_SHOW_SECS) return 255;
    if (age >= MSG_TOTAL_SECS) return 0;
    const t = (age - MSG_SHOW_SECS) / MSG_FADE_SECS;
    return @intFromFloat((1.0 - t) * 255.0);
}
