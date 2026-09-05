const std = @import("std");
const ae = @import("aether");
const Core = ae.Core;
const Util = ae.Util;
const Engine = ae.Engine;
const Rendering = ae.Rendering;
const State = Core.State;

const SpriteBatcher = ae.Ui.SpriteBatcher;
const FontBatcher = ae.Ui.FontBatcher;
const UiDrawList = @import("../ui/UiDrawList.zig");
const Ui = @import("../ui/Ui.zig");
const UiState = @import("../ui/UiState.zig");
const Screen = @import("../ui/Screen.zig");
const ResourcePack = @import("../ResourcePack.zig");
const ui_input = @import("../ui/input.zig");
const DisconnectScreen = @import("../ui/screens/Disconnect.zig");
const Session = @import("Session.zig");
const MenuState = @import("MenuState.zig");

var disconnect_state: @This() = undefined;
var disconnect_state_inst: State = undefined;

pub fn transition_here(engine: *Engine) void {
    disconnect_state_inst = disconnect_state.state();
    engine.transition(&disconnect_state_inst);
}

batcher: SpriteBatcher,
font_batcher: FontBatcher,
ui_state: UiState,
ui_repeat: ui_input.Repeat,
dirt: *const Rendering.Texture,
render_alloc: std.mem.Allocator,
inited: bool,

fn init(ctx: *anyopaque, engine: *Engine) anyerror!void {
    var self = Util.ctx_to_self(@This(), ctx);
    self.inited = false;

    const render_alloc = engine.allocator(.render);
    self.render_alloc = render_alloc;
    try ResourcePack.apply_tex_set(&.{ .dirt, .font, .gui, .glyphs });

    self.batcher = try SpriteBatcher.init(render_alloc);
    self.font_batcher = try FontBatcher.init(render_alloc, ResourcePack.get_tex(.font));
    self.ui_repeat = .{};
    self.ui_state = .{};

    try ui_input.ensure_registered(&engine.input);
    try engine.input.push_context(&.{
        .name = "disconnect",
        .cursor_mode = .visible,
        .actions = ui_input.menu_set(),
        .consumes_text = false,
    });

    self.dirt = ResourcePack.get_tex(.dirt);
    self.ui_state.open(ui_input.seed_focus_on_open());
    self.inited = true;
    engine.report();
}

fn deinit(ctx: *anyopaque, engine: *Engine) void {
    var self = Util.ctx_to_self(@This(), ctx);
    if (!self.inited) return;
    _ = engine.input.pop_context() catch {};
    self.font_batcher.deinit();
    self.batcher.deinit();
    self.inited = false;
}

fn tick(_: *anyopaque, _: *Engine) anyerror!void {}

fn update(ctx: *anyopaque, engine: *Engine, dt: f32, _: *const Util.BudgetContext) anyerror!void {
    var self = Util.ctx_to_self(@This(), ctx);
    const in = ui_input.build_frame(&engine.input, dt, &self.ui_repeat);
    var list: UiDrawList = .{};
    var ui = self.begin_ui(&list, &in);
    const go_back = DisconnectScreen.run(&ui, Session.disconnect_reason());
    ui.end();
    if (go_back) {
        Session.clear_disconnect_reason();
        MenuState.transition_here(engine);
        return;
    }
    try prepare_batches(self);
}

fn prepare_batches(self: *@This()) !void {
    self.batcher.clear();
    self.font_batcher.clear();
    Screen.add_dirt_background(&self.batcher, self.dirt);

    var list: UiDrawList = .{};
    var none: ui_input.UiInput = .{};
    var ui = self.begin_ui(&list, &none);
    _ = DisconnectScreen.run(&ui, Session.disconnect_reason());
    ui.end();
    list.flush_into(&self.batcher, &self.font_batcher, null);

    try self.batcher.update();
    try self.font_batcher.update();
}

fn draw(ctx: *anyopaque, _: *Engine, _: f32, _: *const Util.BudgetContext) anyerror!void {
    var self = Util.ctx_to_self(@This(), ctx);
    self.batcher.draw();
    self.font_batcher.draw();
}

fn begin_ui(self: *@This(), list: *UiDrawList, in: *const ui_input.UiInput) Ui {
    return Ui.begin(.{
        .draw = list,
        .state = &self.ui_state,
        .input = in,
        .fonts = &self.font_batcher,
        .gui_tex = ResourcePack.get_tex(.gui),
        .glyphs_tex = ResourcePack.get_tex(.glyphs),
        .screen = Screen.logical_rect(),
    });
}

pub fn state(self: *@This()) State {
    return .{ .ptr = self, .tab = &.{
        .init = init,
        .deinit = deinit,
        .tick = tick,
        .update = update,
        .draw = draw,
    } };
}
