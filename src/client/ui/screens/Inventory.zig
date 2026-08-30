const Ui = @import("../Ui.zig");
const Prompts = @import("../Prompts.zig");
const widget_id = @import("../widget_id.zig");
const core = @import("core");

pub const Widget = enum(u16) {
    grid = 1,
    _,
};

pub const LAYER_BASE: u8 = 247;
pub const Action = enum { none, select, back };

pub fn wid(w: Widget) widget_id.WidgetId {
    return widget_id.from(Widget, w);
}

pub fn run(ui: *Ui, blocks: []const core.consts.Block, slot: *u8) Action {
    var col = ui.stack(.{ .axis = .vertical, .anchor = .middle_center, .cross_align = .center });
    var action: Action = .none;
    if (ui.slot_grid(wid(.grid), .{
        .cols = 9,
        .rows = 5,
        .cell = 24,
        .blocks = blocks,
        .cursor = slot,
    }) != null) action = .select;
    col.end();
    ui.prompts(&.{ Prompts.select(), Prompts.back() });
    if (action == .none and (ui.cancel_pressed() or ui.inventory_pressed())) action = .back;
    return action;
}
