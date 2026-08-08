const std = @import("std");
const ae = @import("aether");
const Core = ae.Core;
const Util = ae.Util;
const Engine = ae.Engine;
const Rendering = ae.Rendering;
const State = Core.State;

const SpriteBatcher = ae.UI.SpriteBatcher;
const FontBatcher = ae.UI.FontBatcher;
const UiDrawList = @import("../ui/UiDrawList.zig");
const Ui = @import("../ui/Ui.zig");
const UiState = @import("../ui/UiState.zig");
const Scaling = ae.UI.Scaling;
const Colors = @import("../graphics/Color.zig");
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
    draw_dirt_tiles(self);

    var list: UiDrawList = .{};
    var none = empty_input();
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
        .screen = current_screen_rect(),
    });
}

fn current_screen_rect() Ui.LogicalRect {
    const screen_w = Rendering.gfx.surface.get_width();
    const screen_h = Rendering.gfx.surface.get_height();
    const scale = Scaling.compute(screen_w, screen_h);
    return .{
        .x0 = 0,
        .y0 = 0,
        .x1 = @intCast((screen_w + scale - 1) / scale),
        .y1 = @intCast((screen_h + scale - 1) / scale),
    };
}

fn empty_input() ui_input.UiInput {
    return .{
        .input_system = null,
        .cursor_x = 0,
        .cursor_y = 0,
        .cursor_available = false,
        .cursor_moved = false,
        .click_edge = false,
        .click_held = false,
        .nav = .none,
        .confirm_edge = false,
        .cancel_edge = false,
        .pause_edge = false,
        .title_exit_edge = false,
        .inventory_edge = false,
        .wheel_dy = 0,
        .text_events = false,
    };
}

fn draw_dirt_tiles(self: *@This()) void {
    const rect = current_screen_rect();
    var y: i16 = 0;
    const tile_size: i16 = 32;
    while (y < rect.y1) : (y += tile_size) {
        var x: i16 = 0;
        while (x < rect.x1) : (x += tile_size) {
            add_dirt_tile(self, x, y, tile_size);
        }
    }
}

fn add_dirt_tile(self: *@This(), x: i16, y: i16, tile_size: i16) void {
    self.batcher.add_sprite(&.{
        .texture = self.dirt,
        .pos_offset = .{ .x = x, .y = y },
        .pos_extent = .{ .x = tile_size, .y = tile_size },
        .tex_offset = .{ .x = 0, .y = 0 },
        .tex_extent = .{ .x = @intCast(self.dirt.width), .y = @intCast(self.dirt.height) },
        .color = Colors.menu_tiles,
        .layer = 0,
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
