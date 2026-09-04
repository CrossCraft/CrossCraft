//! Persistent state for one immediate-mode UI surface.

const ae = @import("aether");
const widget_id = @import("widget_id.zig");
const layout = ae.UI.layout;

pub const WidgetId = widget_id.WidgetId;

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

pub const ScrollEntry = struct {
    id: WidgetId,
    y: i16,
};

pub const MAX_FOCUSABLES: u8 = 64;
pub const MAX_SCROLLS: u8 = 4;

const UiState = @This();

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

/// `seed_focus` highlights the first focusable after the first frame.
pub fn open(self: *UiState, seed_focus: bool) void {
    self.* = .{ .focus_source = if (seed_focus) .pad else .mouse };
}

pub fn scroll_y(self: *const UiState, id: WidgetId) i16 {
    for (self.scroll_entries[0..self.scroll_count]) |entry| {
        if (entry.id == id) return entry.y;
    }
    return 0;
}

pub fn set_scroll_y(self: *UiState, id: WidgetId, y: i16) void {
    for (self.scroll_entries[0..self.scroll_count]) |*entry| {
        if (entry.id == id) {
            entry.y = y;
            return;
        }
    }
    if (self.scroll_count >= MAX_SCROLLS) return;
    self.scroll_entries[self.scroll_count] = .{ .id = id, .y = y };
    self.scroll_count += 1;
}

pub fn cancel_active_text(self: *UiState) void {
    self.active_text = null;
    self.text_session_started = false;
}
