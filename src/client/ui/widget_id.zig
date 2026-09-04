//! Screen-local opaque widget identifiers.

pub const WidgetId = enum(u16) { _ };

pub fn from(comptime W: type, w: W) WidgetId {
    return @enumFromInt(@intFromEnum(w));
}

pub fn raw(value_u16: u16) WidgetId {
    return @enumFromInt(value_u16);
}
