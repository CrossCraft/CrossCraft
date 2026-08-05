const Ui = @import("../Ui.zig");
const Prompts = @import("../Prompts.zig");
const widget_id = @import("../widget_id.zig");

pub const Widget = enum(u16) {
    singleplayer = 1,
    multiplayer = 2,
    texture_packs = 3,
    options = 4,
    _,
};

pub const Action = enum { none, singleplayer, multiplayer, texture_packs, options };

pub const Options = struct {
    multiplayer_enabled: bool = true,
    texture_packs_enabled: bool = true,
};

pub fn wid(w: Widget) widget_id.WidgetId {
    return widget_id.from(Widget, w);
}

pub fn run(ui: *Ui, opts: Options) Action {
    var col = ui.stack(.{ .axis = .vertical, .anchor = .top_center, .cross_align = .center, .gap = 4 });

    var action: Action = .none;
    ui.spacer(0, 116);
    if (ui.button(wid(.singleplayer), "Singleplayer", .{})) action = .singleplayer;
    if (ui.button(wid(.multiplayer), "Multiplayer", .{ .enabled = opts.multiplayer_enabled }) and action == .none) action = .multiplayer;
    if (ui.button(wid(.texture_packs), "Mods and Texture Packs", .{ .enabled = opts.texture_packs_enabled }) and action == .none) action = .texture_packs;
    ui.spacer(0, 6);
    if (ui.button(wid(.options), "Options...", .{}) and action == .none) action = .options;
    col.end();

    ui.prompts(&.{Prompts.select()});
    return action;
}
