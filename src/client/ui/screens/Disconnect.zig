const Ui = @import("../Ui.zig");
const Prompts = @import("../Prompts.zig");
const widget_id = @import("../widget_id.zig");

pub const Widget = enum(u16) {
    back = 1,
    _,
};

pub fn wid(w: Widget) widget_id.WidgetId {
    return widget_id.from(Widget, w);
}

pub fn run(ui: *Ui, reason: []const u8) bool {
    var col = ui.stack(.{ .axis = .vertical, .anchor = .middle_center, .cross_align = .center, .gap = 4 });
    var back = false;
    ui.label("You were disconnected");
    ui.label(reason);
    ui.spacer(0, 12);
    if (ui.button(wid(.back), "Back to menu", .{})) back = true;
    col.end();
    ui.prompts(&.{ Prompts.select(), Prompts.back() });
    return back or ui.cancel_pressed();
}
