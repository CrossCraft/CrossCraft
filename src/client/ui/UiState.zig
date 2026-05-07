//! Persistent state for one immediate-mode UI surface.

const ae = @import("aether");
const widget_id = @import("widget_id.zig");
const layout = @import("layout.zig");

pub const WidgetId = widget_id.WidgetId;

/// Tracks whether focus was last moved by the pointer or the d-pad.
pub const FocusSource = enum { mouse, pad };

pub const FocusableKind = enum(u8) { button, text_field, slider, slot_grid };

pub const ScrollClip = struct {
    list_id: WidgetId,
    viewport: layout.LogicalRect,
};

pub const Focusable = struct {
    rect: layout.LogicalRect,
    id: WidgetId,
    kind: FocusableKind = .button,
    enabled: bool = true,
    scroll_clip: ?ScrollClip = null,
};

pub const ScrollView = struct {
    list_id: WidgetId,
    viewport: layout.LogicalRect,
    content_h: i16,
    wheel_step: i16,
};

/// Per-`ScrollList` scroll position.
pub const ScrollEntry = struct {
    id: WidgetId,
    y: i16,
};

pub const MAX_FOCUSABLES: u8 = 64;
pub const MAX_SCROLLS: u8 = 4;

const Self = @This();

focused: ?WidgetId = null,
hovered: ?WidgetId = null,
captured: ?WidgetId = null,
captured_via_click: bool = false,
active_text: ?WidgetId = null,
text_session_started: bool = false,
focus_source: FocusSource = .mouse,

focusables: [MAX_FOCUSABLES]Focusable = undefined,
focusable_count: u8 = 0,
scroll_views: [MAX_SCROLLS]ScrollView = undefined,
scroll_view_count: u8 = 0,

scroll_entries: [MAX_SCROLLS]ScrollEntry = undefined,
scroll_count: u8 = 0,

/// Reset transient state on screen entry. `seed_focus = true` arms
/// pad-style nav so the first focusable is highlighted after the first frame.
pub fn open(self: *Self, seed_focus: bool) void {
    self.cancel_active_text();
    self.focused = null;
    self.hovered = null;
    self.captured = null;
    self.captured_via_click = false;
    self.focus_source = if (seed_focus) .pad else .mouse;
    self.focusable_count = 0;
    self.scroll_view_count = 0;
    self.scroll_count = 0;
}

pub fn scroll_y(self: *const Self, id: WidgetId) i16 {
    var i: u8 = 0;
    while (i < self.scroll_count) : (i += 1) {
        if (self.scroll_entries[i].id == id) return self.scroll_entries[i].y;
    }
    return 0;
}

pub fn set_scroll_y(self: *Self, id: WidgetId, y: i16) void {
    var i: u8 = 0;
    while (i < self.scroll_count) : (i += 1) {
        if (self.scroll_entries[i].id == id) {
            self.scroll_entries[i].y = y;
            return;
        }
    }
    if (self.scroll_count >= MAX_SCROLLS) return;
    self.scroll_entries[self.scroll_count] = .{ .id = id, .y = y };
    self.scroll_count += 1;
}

pub fn cancel_active_text(self: *Self) void {
    if (self.active_text != null and self.text_session_started) {
        ae.Core.input.cancel_text() catch {};
    }
    self.active_text = null;
    self.text_session_started = false;
}
