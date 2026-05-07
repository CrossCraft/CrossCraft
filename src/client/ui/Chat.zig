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
// T opens a blank input field. / opens with '/' pre-typed as a command
// prefix. Enter (chat_send) submits, Escape (chat_cancel) discards.

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

const MSG_SHOW_SECS: f32 = 4.5;
const MSG_FADE_SECS: f32 = 0.5;
const MSG_TOTAL_SECS: f32 = MSG_SHOW_SECS + MSG_FADE_SECS;

const ROW_H: i16 = 10;
const MSG_W: i16 = 200;
const LEFT_PAD: i16 = 2;
const BOTTOM_PAD: i16 = 26;

const MSG_BG_LAYER: u8 = 241;
const MSG_TEXT_LAYER: u8 = 242;
const INPUT_BG_LAYER: u8 = 243;
const INPUT_TEXT_LAYER: u8 = 244;

// --- Action set ---

/// One-shot lazy-init handle for the chat ActionSet. Registered the first
/// time the chat overlay opens; reused on every subsequent open across
/// GameState entries.
var chat_set: ?input.ActionSetHandle = null;

fn ensure_chat_set() !input.ActionSetHandle {
    if (chat_set) |h| return h;
    const set = try input.register_action_set("chat");

    try input.add_action(set, "chat_send", .button);
    try input.bind_action(set, "chat_send", .{ .source = .{ .key = .Enter } });
    try input.bind_action(set, "chat_send", .{ .source = .{ .gamepad_button = .A } });

    try input.add_action(set, "chat_cancel", .button);
    try input.bind_action(set, "chat_cancel", .{ .source = .{ .key = .Escape } });
    try input.bind_action(set, "chat_cancel", .{ .source = .{ .gamepad_button = .B } });
    if (ae.platform == .psp) {
        // PSP Select (Back) toggles social mode -- pressing it again with
        // chat already open exits without sending.
        try input.bind_action(set, "chat_cancel", .{ .source = .{ .gamepad_button = .Back } });
    }

    try input.install_action_set(set);
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
/// text session yet -- e.g. PSP social mode shows the panel pre-OSK).
open: bool,
/// Set when the chat overlay is open AND a TextInputSession is in flight.
/// Distinct from `open` so PSP social mode can show the panel without yet
/// having armed the OSK.
session_active: bool,
/// Optional command prefix prepended to outgoing messages, displayed
/// ahead of the typed text. Zero = no prefix.
prefix: u8,
/// Edge-detection mirror for chat_send / chat_cancel.
prev_send: input.ButtonState,
prev_cancel: input.ButtonState,
/// True iff chat_set was the top context's action set last frame. Used
/// to suppress ghost rising edges on the frame chat first becomes active
/// with chat_send / chat_cancel sources already held from the gameplay
/// press that opened the overlay.
chat_was_active: bool,

// --- Init ---

pub fn init() Self {
    return .{
        .messages = std.mem.zeroes([MAX_MESSAGES]Entry),
        .msg_head = 0,
        .msg_count = 0,
        .open = false,
        .session_active = false,
        .prefix = 0,
        .prev_send = .released,
        .prev_cancel = .released,
        .chat_was_active = false,
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
/// `slash_prefix = true` prepends '/' as a command marker; the prefix is
/// rendered separately and added back when the message is dispatched.
pub fn open_overlay(self: *Self, player: *Player, slash_prefix: bool) void {
    if (self.open) return;
    self.open = true;
    self.prefix = if (slash_prefix) '/' else 0;
    self.prev_send = .released;
    self.prev_cancel = .released;
    self.chat_was_active = false;

    const set = ensure_chat_set() catch {
        self.open = false;
        return;
    };
    input.push_context(.{
        .name = "chat",
        .cursor_mode = .visible,
        .actions = set,
        .consumes_text = true,
    }) catch {
        self.open = false;
        return;
    };
    self.begin_session();

    // PSP returns synchronously with a terminal session; service it now.
    handle_terminal_if_done(self, player);
}

/// PSP social mode: show the chat panel without arming the OSK, so the
/// player list can sit alongside it. The OSK fires later when X is
/// pressed and `begin_session_now` is called.
pub fn open_overlay_social(self: *Self, _: *Player) void {
    if (self.open) return;
    self.open = true;
    self.prefix = 0;
    self.prev_send = .released;
    self.prev_cancel = .released;
    self.chat_was_active = false;

    const set = ensure_chat_set() catch {
        self.open = false;
        return;
    };
    input.push_context(.{
        .name = "chat",
        .cursor_mode = .visible,
        .actions = set,
        .consumes_text = true,
    }) catch {
        self.open = false;
        return;
    };
    // session_active stays false; the panel is empty until X arms the OSK.
}

/// PSP: invoked from GameState when X (Cross) is pressed during social
/// mode. Begins the text session synchronously (OSK shows), services the
/// terminal result, and closes the overlay if the user submitted.
pub fn begin_session_now(self: *Self, player: *Player) void {
    if (!self.open or self.session_active) return;
    self.begin_session();
    handle_terminal_if_done(self, player);
}

fn begin_session(self: *Self) void {
    const target: input.TextInputTarget = .{ .id = "chat" };
    const opts: input.TextInputOptions = .{ .max_bytes = INPUT_MAX_LEN };
    _ = input.begin_text_input(target, opts) catch return;
    self.session_active = true;
    if (self.prefix != 0) {
        // Prefill the engine session so PSP's modal OSK can see the slash
        // as the starting text. Status stays .active.
        const buf = [_]u8{self.prefix};
        input.write_text_session_buffer(&buf, .active);
    }
}

fn handle_terminal_if_done(self: *Self, player: *Player) void {
    const session = input.current_text_session() orelse return;
    if (session.status == .submitted) {
        send_session(self, player);
        self.close_overlay(player);
    } else if (session.status == .cancelled) {
        self.close_overlay(player);
    }
}

pub fn close_overlay(self: *Self, player: *Player) void {
    if (!self.open) return;
    self.open = false;
    if (self.session_active) {
        // cancel_text errors if the session is already terminal; ignore.
        input.cancel_text() catch {};
        self.session_active = false;
    }
    _ = input.pop_context() catch {};
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

pub fn update(self: *Self, player: *Player) void {
    std.debug.assert(self.open);

    // Walk frame events for Backspace; trim the session buffer in place.
    if (self.session_active) {
        const session_const = input.current_text_session() orelse return;
        // The session pointer is into Aether's module-static storage and
        // is stable for the session's lifetime; we can safely cast away
        // const for the buffer-trim mutation (no allocator needed for
        // shrink). Aether exposes no public "pop byte" helper.
        const session: *input.TextInputSession = @constCast(session_const);
        for (input.frame_events()) |ev| {
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

    const send = input.get_action_button("chat_send");
    const cancel = input.get_action_button("chat_cancel");

    const active_now = is_chat_set_active();
    const fresh_activation = active_now and !self.chat_was_active;
    self.chat_was_active = active_now;

    const send_edge = !fresh_activation and self.prev_send == .released and send == .pressed;
    const cancel_edge = !fresh_activation and self.prev_cancel == .released and cancel == .pressed;
    self.prev_send = send;
    self.prev_cancel = cancel;

    if (send_edge) {
        if (self.session_active) {
            input.submit_text() catch {};
            send_session(self, player);
        }
        self.close_overlay(player);
        return;
    }

    if (cancel_edge) {
        self.close_overlay(player);
    }
}

fn is_chat_set_active() bool {
    const top = input.stack_top() orelse return false;
    const set = chat_set orelse return false;
    return @intFromEnum(top.actions) == @intFromEnum(set);
}

// --- Wire send ---

fn send_session(self: *Self, player: *Player) void {
    const session = input.current_text_session() orelse return;
    const body = session.buffer.items;
    if (body.len == 0 and self.prefix == 0) return;

    var combined: [INPUT_MAX_LEN + 1]u8 = undefined;
    var n: usize = 0;
    if (self.prefix != 0 and n < combined.len) {
        combined[n] = self.prefix;
        n += 1;
    }
    const take = @min(body.len, combined.len - n);
    if (take > 0) std.mem.copyForwards(u8, combined[n..][0..take], body[0..take]);
    n += take;

    proto.send_message(player.writer, -1, combined[0..n]) catch {};
    player.writer.flush() catch {};
}

// --- Draw ---

pub fn draw(self: *const Self, batcher: *SpriteBatcher, fonts: *FontBatcher, y_shift: i16) void {
    const base: i16 = BOTTOM_PAD + y_shift;
    var drawn: u8 = 0;
    var i: u8 = 0;
    while (i < self.msg_count) : (i += 1) {
        const idx = (self.msg_head + MAX_MESSAGES - 1 - i) % MAX_MESSAGES;
        const entry = &self.messages[idx];

        const alpha = compute_alpha(entry.age, self.open);
        if (alpha == 0) continue;

        const input_offset: i16 = if (self.open) ROW_H else 0;
        const row_y: i16 = -(base + input_offset + @as(i16, drawn) * ROW_H);

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

    // Input field background.
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

    const text_x: i16 = LEFT_PAD + 2;
    const visual_prompt = "> ";
    fonts.add_text(&.{
        .str = visual_prompt,
        .pos_x = text_x,
        .pos_y = -base,
        .color = .white_fg,
        .shadow_color = .menu_gray,
        .spacing = 0,
        .layer = INPUT_TEXT_LAYER,
        .reference = .bottom_left,
        .origin = .bottom_left,
    });
    const prompt_w: i16 = fonts.string_width(visual_prompt, 0, 1);

    // Read the live session buffer; on PSP between OSK opens the session
    // may not yet be active (social mode's pre-OSK panel) -- show empty.
    const body: []const u8 = if (input.current_text_session()) |s| s.buffer.items else &.{};
    if (body.len > 0) {
        fonts.add_text(&.{
            .str = body,
            .pos_x = text_x + prompt_w,
            .pos_y = -base,
            .color = .white_fg,
            .shadow_color = .menu_gray,
            .spacing = 0,
            .layer = INPUT_TEXT_LAYER,
            .reference = .bottom_left,
            .origin = .bottom_left,
        });
    }

    const typed_w: i16 = if (body.len > 0) fonts.string_width(body, 0, 1) else 0;
    fonts.add_text(&.{
        .str = "_",
        .pos_x = text_x + prompt_w + typed_w + 1,
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

fn compute_alpha(age: f32, chat_open: bool) u8 {
    if (chat_open) return 255;
    if (age < MSG_SHOW_SECS) return 255;
    if (age >= MSG_TOTAL_SECS) return 0;
    const t = (age - MSG_SHOW_SECS) / MSG_FADE_SECS;
    return @intFromFloat((1.0 - t) * 255.0);
}
