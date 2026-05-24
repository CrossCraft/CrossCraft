const Ui = @import("../Ui.zig");
const widget_id = @import("../widget_id.zig");

pub const Widget = enum(u16) {
    ip = 1,
    name = 2,
    join = 3,
    back = 4,
    _,
};

pub const IP_MAX: u8 = 32;
pub const NAME_MAX: u8 = 16;

pub const Ctx = struct {
    ip: *[IP_MAX]u8,
    ip_len: *u8,
    name: *[NAME_MAX]u8,
    name_len: *u8,
};

pub const Action = enum { none, join, back };

pub fn wid(w: Widget) widget_id.WidgetId {
    return widget_id.from(Widget, w);
}

pub fn run(ui: *Ui, ctx: *Ctx) Action {
    var col = ui.stack(.{ .axis = .vertical, .anchor = .middle_center, .cross_align = .center, .gap = 4 });
    var action: Action = .none;

    ui.label("Direct Connect");
    ui.label("Server Address");
    var ip_buf: Ui.TextBuf = .{ .bytes = ctx.ip, .len = ctx.ip_len, .max = IP_MAX };
    _ = ui.text_field(wid(.ip), &ip_buf, .{ .placeholder = "ip:port", .session_id = "direct_connect.ip" });
    ui.label("Name");
    var name_buf: Ui.TextBuf = .{ .bytes = ctx.name, .len = ctx.name_len, .max = NAME_MAX };
    _ = ui.text_field(wid(.name), &name_buf, .{ .placeholder = "Player", .session_id = "direct_connect.name" });
    if (ui.button(wid(.join), "Join Server", .{})) action = .join;
    if (ui.button(wid(.back), "Back", .{}) and action == .none) action = .back;
    col.end();

    ui.contextual_prompts();
    if (action == .none and ui.cancel_pressed()) action = .back;
    return action;
}
