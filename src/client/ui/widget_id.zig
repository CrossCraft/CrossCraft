//! Opaque widget identifier. Each screen declares a private
//! `Widget = enum(u16) { ..., _ }` and casts into this wrapper; uniqueness
//! is only required within one screen's focusable set.

pub const WidgetId = enum(u16) { _ };

/// Cast a screen-local `Widget` enum value (tagged `(u16)`) into a WidgetId.
pub fn from(comptime W: type, w: W) WidgetId {
    return @enumFromInt(@intFromEnum(w));
}

/// Build a WidgetId from a raw u16 for dynamic-row IDs.
pub fn raw(value_u16: u16) WidgetId {
    return @enumFromInt(value_u16);
}

pub fn value(id: WidgetId) u16 {
    return @intFromEnum(id);
}
