const Ui = @import("../Ui.zig");
const widget_id = @import("../widget_id.zig");

pub const NAME_MAX: u8 = @import("game").World.DumpName.NAME_MAX;

pub const Widget = enum(u16) {
    name = 1,
    save = 2,
    back = 3,
    _,
};

pub const Ctx = struct {
    name: *[NAME_MAX]u8,
    name_len: *u8,
    save_enabled: bool,
};

pub const Action = enum { none, save, back };

pub const LAYER_BASE: u8 = 2;
const TITLE_TOP_OFFSET: i16 = 52;

pub fn wid(w: Widget) widget_id.WidgetId {
    return widget_id.from(Widget, w);
}

pub fn run(ui: *Ui, ctx: *Ctx) Action {
    var title = ui.stack(.{
        .axis = .vertical,
        .anchor = .top_center,
        .cross_align = .center,
        .padding = .{ .top = TITLE_TOP_OFFSET },
    });
    ui.label("Dump World");
    title.end();

    var col = ui.stack(.{ .axis = .vertical, .anchor = .middle_center, .cross_align = .center, .gap = 4 });
    var action: Action = .none;

    ui.label("World Name");
    var name_buf: Ui.TextBuf = .{ .bytes = ctx.name, .len = ctx.name_len, .max = NAME_MAX };
    const text_event = ui.text_field(wid(.name), &name_buf, .{ .placeholder = "world", .session_id = "dump_world.name" });
    if (ui.button(wid(.save), "Save", .{ .enabled = ctx.save_enabled }) and action == .none) action = .save;
    if (ui.button(wid(.back), "Back", .{}) and action == .none) action = .back;
    col.end();

    ui.contextual_prompts();
    if (action == .none and text_event == .submit and ctx.save_enabled) action = .save;
    if (action == .none and ui.cancel_pressed()) action = .back;
    return action;
}
