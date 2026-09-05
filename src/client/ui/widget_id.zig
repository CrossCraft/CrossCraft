//! Screen-local IDs use Aether's stable widget identifier type.
pub const WidgetId = @import("aether").Ui.Context.WidgetId;
pub fn from(comptime W: type, value: W) WidgetId {
    return @intFromEnum(value);
}
pub fn raw(value: u16) WidgetId {
    return value;
}
