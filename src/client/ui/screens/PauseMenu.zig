const Ui = @import("../Ui.zig");
const Prompts = @import("../Prompts.zig");
const widget_id = @import("../widget_id.zig");

pub const Widget = enum(u16) {
    back = 1,
    options = 2,
    save = 3,
    quit = 4,
    _,
};

pub const Action = enum { none, back, options, save, quit };

pub const DIM_LAYER: u8 = 1;
pub const LAYER_BASE: u8 = 2;

pub fn wid(w: Widget) widget_id.WidgetId {
    return widget_id.from(Widget, w);
}

pub fn run(ui: *Ui, is_singleplayer: bool) Action {
    var col = ui.stack(.{ .axis = .vertical, .anchor = .middle_center, .cross_align = .center, .gap = 4 });
    var action: Action = .none;

    ui.label("Game menu");
    if (ui.button(wid(.back), "Back to game", .{})) action = .back;
    if (ui.button(wid(.options), "Options...", .{}) and action == .none) action = .options;
    if (ui.button(wid(.save), "Save level...", .{ .enabled = is_singleplayer }) and action == .none) action = .save;
    if (ui.button(wid(.quit), if (is_singleplayer) "Save and quit to menu" else "Disconnect", .{}) and action == .none) action = .quit;
    col.end();

    ui.prompts(&.{ Prompts.select(), Prompts.back() });
    if (action == .none and ui.cancel_pressed()) action = .back;
    return action;
}
