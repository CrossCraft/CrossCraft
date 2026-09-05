const Ui = @import("../Ui.zig");
const widget_id = @import("../widget_id.zig");
const core = @import("core");
const std = @import("std");

const wd = core.world_dims;

pub const NameMax: u8 = @import("core").World.CreateName.NameMax;
pub const SeedMax: u8 = NameMax;
const OptionW: i16 = 150;

pub const Widget = enum(u16) {
    name = 1,
    seed = 2,
    world_size = 3,
    world_height = 4,
    world_type = 5,
    gamemode = 6,
    create = 7,
    back = 8,
    _,
};

pub const Ctx = struct {
    name: *[NameMax]u8,
    name_len: *u8,
    seed: *[SeedMax]u8,
    seed_len: *u8,
    size: *wd.WorldSize,
    height: *wd.WorldHeight,
    create_enabled: bool,
};

pub const Action = enum { none, create, back };

pub fn wid(w: Widget) widget_id.WidgetId {
    return widget_id.from(Widget, w);
}

fn cycle(comptime E: type, v: E) E {
    const n = @typeInfo(E).@"enum".fields.len;
    return @enumFromInt((@intFromEnum(v) + 1) % n);
}

pub fn run(ui: *Ui, ctx: *Ctx) Action {
    var col = ui.stack(.{ .axis = .vertical, .anchor = .middle_center, .cross_align = .center, .gap = 4 });
    var action: Action = .none;

    ui.label("Create world");
    ui.spacer(0, 2);
    ui.label("Name");
    var name_buf: Ui.TextBuf = .{ .bytes = ctx.name, .len = ctx.name_len, .max = NameMax };
    const name_event = ui.text_field(wid(.name), &name_buf, .{ .placeholder = "world", .session_id = "create_world.name" });

    ui.label("Seed");
    var seed_buf: Ui.TextBuf = .{ .bytes = ctx.seed, .len = ctx.seed_len, .max = SeedMax };
    const seed_event = ui.text_field(wid(.seed), &seed_buf, .{ .placeholder = "", .session_id = "create_world.seed" });

    ui.spacer(0, 2);
    {
        var row = ui.stack(.{ .axis = .horizontal, .anchor = .middle_center, .cross_align = .center, .gap = 4 });
        _ = ui.button(wid(.gamemode), "Gamemode: Classic", .{ .width = OptionW, .enabled = false });
        _ = ui.button(wid(.world_type), "World Type: Normal", .{ .width = OptionW, .enabled = false });
        row.end();
    }
    {
        var row = ui.stack(.{ .axis = .horizontal, .anchor = .middle_center, .cross_align = .center, .gap = 4 });
        var size_buf: [32]u8 = undefined;
        const size_label = std.fmt.bufPrint(&size_buf, "World Size: {s}", .{ctx.size.label()}) catch "World Size";
        if (ui.button(wid(.world_size), size_label, .{ .width = OptionW })) {
            ctx.size.* = cycle(wd.WorldSize, ctx.size.*);
        }
        var height_buf: [32]u8 = undefined;
        const height_label = std.fmt.bufPrint(&height_buf, "World Height: {s}", .{ctx.height.label()}) catch "World Height";
        if (ui.button(wid(.world_height), height_label, .{ .width = OptionW })) {
            ctx.height.* = cycle(wd.WorldHeight, ctx.height.*);
        }
        row.end();
    }

    ui.spacer(0, 2);
    if (ui.button(wid(.create), "Create", .{ .enabled = ctx.create_enabled }) and action == .none) action = .create;
    if (ui.button(wid(.back), "Back", .{}) and action == .none) action = .back;
    col.end();

    ui.contextual_prompts();
    if (action == .none and (name_event == .submit or seed_event == .submit) and ctx.create_enabled) action = .create;
    if (action == .none and ui.cancel_pressed()) action = .back;
    return action;
}
