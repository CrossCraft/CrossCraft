//! Screen-local lifetime and focus presets over Aether's UI state.
const std = @import("std");
const ae = @import("aether");
const State = @This();
const WidgetId = @import("widget_id.zig").WidgetId;
implementation: ?ae.Ui.State = null,
focused: ?WidgetId = null,
hovered: ?WidgetId = null,
captured: ?WidgetId = null,
active_text: ?WidgetId = null,
seed_focus: bool = false,
pub fn get(self: *State, allocator: std.mem.Allocator) *ae.Ui.State {
    if (self.implementation == null) self.implementation = ae.Ui.State.init(allocator, .{ .focusables = 64, .scrolls = 4, .stack_depth = 8 }) catch @panic("UI state allocation failed");
    self.implementation.?.focused = self.focused;
    self.implementation.?.seed_focus = self.seed_focus;
    return &self.implementation.?;
}
pub fn sync(self: *State) void {
    if (self.implementation) |*state| {
        self.focused = state.focused;
        self.hovered = state.hovered;
        self.captured = state.captured;
        self.active_text = state.active_text;
    }
}
pub fn open(self: *State, seed: bool) void {
    if (self.implementation) |*state| {
        state.close();
        state.focus_count = .{ 0, 0 };
        state.scroll_count = 0;
    }
    self.seed_focus = seed;
    self.focused = null;
    self.hovered = null;
    self.captured = null;
    self.active_text = null;
}
pub fn cancel_active_text(self: *State) void {
    if (self.implementation) |*state| state.cancel_text();
    self.active_text = null;
}
pub fn deinit(self: *State) void {
    if (self.implementation) |*state| state.deinit();
    self.* = undefined;
}
