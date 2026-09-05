// PSP text sessions resolve synchronously through the system OSK.

const std = @import("std");
const assert = std.debug.assert;
const ae = @import("aether");
const input = ae.Core.input;
const proto = @import("core").protocol;

const Player = @import("../player/Player.zig");
const FontBatcher = ae.Ui.FontBatcher;
const UiDrawList = @import("UiDrawList.zig");
const Colors = @import("../graphics/Color.zig");
const Color = Colors.Color;
const TextWrap = @import("TextWrap.zig");
const Chat = @This();

pub const MaxMessages: u8 = 10;
const MsgMaxLen: u8 = 96;
pub const InputMaxLen: u8 = 64;

const MsgShowSecs: f32 = 4.5;
const MsgFadeSecs: f32 = 0.5;
const MsgTotalSecs: f32 = MsgShowSecs + MsgFadeSecs;

const RowH: i16 = 10;
const MsgW: i16 = 200;
const LeftPad: i16 = 2;
const BottomPad: i16 = 26;
const TextPadX: i16 = 2;
const TextW: i16 = MsgW - 2 * TextPadX;

const HistoryLineLimit: usize = MaxMessages;
// Glyph tiles are 8 px wide with a 1 px gap, so the 64-byte Classic text
// limit plus the prompt cannot exceed four 196 px visual rows.
const MsgWrapMaxLines: usize = 4;
const InputWrapMaxLines: usize = 4;
const InputPrompt = "> ";
const InputTextMaxBytes: usize = @as(usize, InputMaxLen) + InputPrompt.len;
const WrapLineMaxBytes: usize = InputTextMaxBytes + 2;
const RenderLineMax: usize = HistoryLineLimit + InputWrapMaxLines;

const MsgBgLayer: u8 = 241;
const MsgTextLayer: u8 = 242;
const InputBgLayer: u8 = 243;
const InputTextLayer: u8 = 244;

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
    // Select/Back closes social mode without sending.
    try sys.bind_action(chat_cancel, &.{ .source = .{ .gamepad_button = .Back } });

    try sys.install_action_set(set);
    chat_set = set;
    return set;
}

const Entry = struct {
    text: [MsgMaxLen]u8,
    text_len: u8,
    age: f32,
};

messages: [MaxMessages]Entry,
msg_head: u8,
msg_count: u8,

/// The social overlay can be open before a text session starts.
open: bool,
session_active: bool,
prev_send: input.ButtonState,
prev_cancel: input.ButtonState,
/// Suppress send/cancel inputs held when chat opens.
chat_was_active: bool,
render_lines: [RenderLineMax][WrapLineMaxBytes]u8,
render_line_count: u8,

pub fn init() Chat {
    return .{
        .messages = std.mem.zeroes([MaxMessages]Entry),
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

pub fn receive(self: *Chat, raw: []const u8) void {
    var len: u8 = 0;
    const lim = @min(raw.len, MsgMaxLen);
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
    self.msg_head = (self.msg_head + 1) % MaxMessages;
    if (self.msg_count < MaxMessages) self.msg_count += 1;
}

pub fn open_overlay(self: *Chat, sys: *input.InputSystem, player: *Player, slash_prefix: bool) void {
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

/// Open social mode without starting text entry; Confirm starts it later.
pub fn open_overlay_social(self: *Chat, sys: *input.InputSystem, _: *Player) void {
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
}

fn begin_session(self: *Chat, sys: *input.InputSystem, slash_prefix: bool) void {
    const target: input.TextInputTarget = .{ .id = "chat" };
    const slash_buf = [_]u8{'/'};
    const opts: input.TextInputOptions = .{
        .max_bytes = InputMaxLen,
        .initial = if (slash_prefix) slash_buf[0..1] else null,
    };
    _ = sys.begin_text_input(&target, &opts) catch return;
    self.session_active = true;
}

fn handle_terminal_if_done(self: *Chat, sys: *input.InputSystem, player: *Player) void {
    const session = sys.current_text_session() orelse return;
    if (session.status == .submitted) {
        send_session(sys, player);
        self.close_overlay(sys, player);
    } else if (session.status == .cancelled) {
        self.close_overlay(sys, player);
    }
}

pub fn close_overlay(self: *Chat, sys: *input.InputSystem, player: *Player) void {
    if (!self.open) return;
    self.open = false;
    if (self.session_active) {
        sys.cancel_text() catch {};
        self.session_active = false;
    }
    _ = sys.pop_context() catch {};
    player.look_delta = .{ 0, 0 };
}

pub fn tick(self: *Chat, dt: f32) void {
    if (self.open) return;
    var i: u8 = 0;
    while (i < self.msg_count) : (i += 1) {
        self.messages[i].age += dt;
    }
}

pub fn update(self: *Chat, sys: *input.InputSystem, player: *Player) void {
    assert(self.open);

    if (self.session_active) {
        const session_const = sys.current_text_session() orelse return;
        // Aether exposes stable session storage but no pop-byte helper.
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
            // Modal OSKs finish here; desktop leaves the new session active.
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

fn send_session(sys: *input.InputSystem, player: *Player) void {
    const session = sys.current_text_session() orelse return;
    const body = session.buffer.items;
    if (body.len == 0) return;

    proto.send_message(player.writer, -1, body) catch {};
    player.writer.flush() catch {};
}

pub fn draw_into(self: *Chat, sys: *input.InputSystem, list: *UiDrawList, fonts: *const FontBatcher, y_shift: i16) void {
    self.render_line_count = 0;

    const base: i16 = BottomPad + y_shift;

    var input_text: [InputTextMaxBytes]u8 = undefined;
    var input_lines: [InputWrapMaxLines][WrapLineMaxBytes]u8 = undefined;
    var input_lens: [InputWrapMaxLines]u8 = undefined;
    var input_line_count: u8 = 0;

    // Social mode has no session buffer until text entry starts.
    const body: []const u8 = if (self.open)
        if (sys.current_text_session()) |s| s.buffer.items else &.{}
    else
        &.{};

    if (self.open) {
        @memcpy(input_text[0..InputPrompt.len], InputPrompt);
        const take = @min(body.len, @as(usize, InputMaxLen));
        if (take > 0) {
            @memcpy(input_text[InputPrompt.len .. InputPrompt.len + take], body[0..take]);
        }
        input_line_count = TextWrap.wrap(
            InputWrapMaxLines,
            WrapLineMaxBytes,
            fonts,
            input_text[0 .. InputPrompt.len + take],
            TextW,
            &input_lines,
            &input_lens,
        );
    }

    const input_h: i16 = if (self.open) @as(i16, @intCast(@max(input_line_count, 1))) * RowH else 0;

    var drawn_lines: usize = 0;
    var i: u8 = 0;
    while (i < self.msg_count) : (i += 1) {
        const idx = (self.msg_head + MaxMessages - 1 - i) % MaxMessages;
        const entry = &self.messages[idx];

        const alpha = compute_alpha(entry.age, self.open);
        if (alpha == 0) continue;
        if (drawn_lines >= HistoryLineLimit) break;

        var msg_lines: [MsgWrapMaxLines][WrapLineMaxBytes]u8 = undefined;
        var msg_lens: [MsgWrapMaxLines]u8 = undefined;
        const msg_line_count = TextWrap.wrap(
            MsgWrapMaxLines,
            WrapLineMaxBytes,
            fonts,
            entry.text[0..entry.text_len],
            TextW,
            &msg_lines,
            &msg_lens,
        );
        if (msg_line_count == 0) continue;

        const remaining = HistoryLineLimit - drawn_lines;
        const visible_lines = @min(@as(usize, msg_line_count), remaining);
        const first_line = @as(usize, msg_line_count) - visible_lines;

        const bg_a: u8 = @intFromFloat(160.0 * (@as(f32, @floatFromInt(alpha)) / 255.0));
        var line_i = first_line;
        while (line_i < @as(usize, msg_line_count)) : (line_i += 1) {
            const row_offset = drawn_lines + (@as(usize, msg_line_count) - 1 - line_i);
            const row_y: i16 = -(base + input_h + @as(i16, @intCast(row_offset)) * RowH);

            list.add_rect(&.{
                .pos_offset = .{ .x = LeftPad, .y = row_y },
                .pos_extent = .{ .x = MsgW, .y = RowH },
                .color = Color.rgba(0, 0, 0, bg_a),
                .layer = MsgBgLayer,
                .reference = .bottom_left,
                .origin = .bottom_left,
            });
            if (self.store_render_line(msg_lines[line_i][0..msg_lens[line_i]])) |line| {
                list.add_text(&.{
                    .str = line,
                    .pos_x = LeftPad + TextPadX,
                    .pos_y = row_y,
                    .color = Color.rgba(255, 255, 255, alpha),
                    .shadow_color = Color.rgba(50, 50, 50, alpha),
                    .spacing = 0,
                    .layer = MsgTextLayer,
                    .reference = .bottom_left,
                    .origin = .bottom_left,
                });
            }
        }

        drawn_lines += visible_lines;
    }

    if (!self.open) return;

    list.add_rect(&.{
        .pos_offset = .{ .x = LeftPad, .y = -base },
        .pos_extent = .{ .x = MsgW, .y = input_h },
        .color = Color.rgba(0, 0, 0, 192),
        .layer = InputBgLayer,
        .reference = .bottom_left,
        .origin = .bottom_left,
    });

    const text_x: i16 = LeftPad + TextPadX;
    const prompt_w = fonts.string_width(InputPrompt, 0, 1);
    var last_line_w: i16 = prompt_w;
    var input_i: usize = 0;
    while (input_i < @as(usize, input_line_count)) : (input_i += 1) {
        const row_y: i16 = -(base + @as(i16, @intCast(@as(usize, input_line_count) - 1 - input_i)) * RowH);
        if (self.store_render_line(input_lines[input_i][0..input_lens[input_i]])) |line| {
            // Separate the prompt to avoid an extra FontBatcher gap before the text.
            if (input_i == 0 and line.len > 0 and line[0] == InputPrompt[0]) {
                const prompt_len: usize = @min(line.len, InputPrompt.len);
                list.add_text(&.{
                    .str = InputPrompt,
                    .pos_x = text_x,
                    .pos_y = row_y,
                    .color = Colors.white_fg,
                    .shadow_color = Colors.menu_gray,
                    .spacing = 0,
                    .layer = InputTextLayer,
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
                        .layer = InputTextLayer,
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
                    .layer = InputTextLayer,
                    .reference = .bottom_left,
                    .origin = .bottom_left,
                });
                last_line_w = fonts.string_width(line, 0, 1);
            }
        }
    }
    if (input_line_count == 0) {
        list.add_text(&.{
            .str = InputPrompt,
            .pos_x = text_x,
            .pos_y = -base,
            .color = Colors.white_fg,
            .shadow_color = Colors.menu_gray,
            .spacing = 0,
            .layer = InputTextLayer,
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
        .layer = InputTextLayer,
        .reference = .bottom_left,
        .origin = .bottom_left,
    });
}

fn store_render_line(self: *Chat, line: []const u8) ?[]const u8 {
    if (line.len == 0 or line.len > WrapLineMaxBytes) return null;
    if (@as(usize, self.render_line_count) >= RenderLineMax) return null;

    const idx = @as(usize, self.render_line_count);
    @memcpy(self.render_lines[idx][0..line.len], line);
    self.render_line_count += 1;
    return self.render_lines[idx][0..line.len];
}

fn compute_alpha(age: f32, chat_open: bool) u8 {
    if (chat_open) return 255;
    if (age < MsgShowSecs) return 255;
    if (age >= MsgTotalSecs) return 0;
    const t = (age - MsgShowSecs) / MsgFadeSecs;
    return @intFromFloat((1.0 - t) * 255.0);
}
