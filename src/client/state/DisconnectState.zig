/// Disconnect screen: shown when the server disconnects the player (via the
/// DisconnectPlayer packet) or when the TCP connection drops unexpectedly, and
/// also when a load-phase error prevents the session from starting.
///
/// Displays the dirt-tile background, a "You were disconnected" header, the
/// server-supplied reason string, and a "Back to menu" button.
const std = @import("std");
const ae = @import("aether");
const Core = ae.Core;
const Util = ae.Util;
const Engine = ae.Engine;
const Rendering = ae.Rendering;
const State = Core.State;

const SpriteBatcher = @import("../ui/SpriteBatcher.zig");
const FontBatcher = @import("../ui/FontBatcher.zig");
const Screen = @import("../ui/Screen.zig");
const component = @import("../ui/component.zig");
const Component = component.Component;
const Scaling = @import("../ui/Scaling.zig");
const Vertex = @import("../graphics/Vertex.zig").Vertex;
const ResourcePack = @import("../ResourcePack.zig");
const ui_input = @import("../ui/input.zig");
const Session = @import("Session.zig");
const MenuState = @import("MenuState.zig");
const Color = @import("../graphics/Color.zig").Color;

const log = std.log.scoped(.disconnect);

// Module-level singletons -- only one DisconnectState may exist at a time.
var pipeline: Rendering.Pipeline.Handle = undefined;
var disconnect_state: @This() = undefined;
var disconnect_state_inst: State = undefined;
var pending_menu: bool = false;

pub fn transition_here(engine: *Engine) !void {
    disconnect_state_inst = disconnect_state.state();
    try ae.Core.state_machine.transition(engine, &disconnect_state_inst);
}

const components = [_]Component{
    .{ .button = .{
        .label = "Back to menu",
        .width = 200,
        .height = 20,
        .pos_x = 0,
        .pos_y = 24,
        .reference = .middle_center,
        .origin = .middle_center,
        .on_activate = on_back_to_menu,
    } },
};

fn on_back_to_menu(_: *anyopaque) void {
    pending_menu = true;
}

/// Context passed to the Screen's draw_underlay callback.
const Context = struct {
    dirt: *const Rendering.Texture,
};

batcher: SpriteBatcher,
font_batcher: FontBatcher,
screen: Screen,
ui_repeat: ui_input.Repeat,
ctx: Context,
render_alloc: std.mem.Allocator,

fn init(ctx: *anyopaque, engine: *Engine) anyerror!void {
    var self = Util.ctx_to_self(@This(), ctx);
    const vert align(@alignOf(u32)) = @embedFile("basic_vert").*;
    const frag align(@alignOf(u32)) = @embedFile("basic_frag").*;
    pipeline = try Rendering.Pipeline.new(Vertex.Layout, &vert, &frag);

    const render_alloc = engine.allocator(.render);
    self.render_alloc = render_alloc;
    // Apply the minimal texture set for this screen; unloads game textures
    // (terrain, water, lava) that were active during gameplay.
    try ResourcePack.apply_tex_set(&.{ .dirt, .font, .gui });

    self.batcher = try SpriteBatcher.init(render_alloc, pipeline);
    self.font_batcher = try FontBatcher.init(render_alloc, pipeline, ResourcePack.get_tex(.font));
    self.ui_repeat = .{};
    pending_menu = false;

    self.ctx = .{ .dirt = ResourcePack.get_tex(.dirt) };
    self.screen = .{
        .components = components[0..],
        .ctx = &self.ctx,
        .nav = .stack,
        .draw_underlay = draw_underlay,
    };
    self.screen.open(!ui_input.profile_uses_pointer());

    engine.report();
}

fn deinit(ctx: *anyopaque, _: *Engine) void {
    var self = Util.ctx_to_self(@This(), ctx);
    self.font_batcher.deinit();
    self.batcher.deinit();
    Rendering.Pipeline.deinit(pipeline);
}

fn tick(_: *anyopaque, _: *Engine) anyerror!void {}

fn update(ctx: *anyopaque, engine: *Engine, dt: f32, _: *const Util.BudgetContext) anyerror!void {
    var self = Util.ctx_to_self(@This(), ctx);

    const in = ui_input.build_frame(dt, &self.ui_repeat);
    self.screen.update(&in);

    if (pending_menu or self.screen.cancel_pressed) {
        pending_menu = false;
        // Clear reason so stale text doesn't bleed into the next disconnect.
        Session.disconnect_reason_len = 0;
        try MenuState.transition_here(engine);
    }
}

fn draw_underlay(ctx: *anyopaque, sprites: *SpriteBatcher, _: *FontBatcher, _: *const Rendering.Texture) void {
    const dc: *const Context = @ptrCast(@alignCast(ctx));
    const screen_w = Rendering.gfx.surface.get_width();
    const screen_h = Rendering.gfx.surface.get_height();
    const scale = Scaling.compute(screen_w, screen_h);
    const extent_x: i16 = @intCast((screen_w + scale - 1) / scale);
    const extent_y: i16 = @intCast((screen_h + scale - 1) / scale);

    var y: i16 = 0;
    const tile_size: i16 = 32;
    while (y < extent_y) : (y += tile_size) {
        var x: i16 = 0;
        while (x < extent_x) : (x += tile_size) {
            sprites.add_sprite(&.{
                .texture = dc.dirt,
                .pos_offset = .{ .x = x, .y = y },
                .pos_extent = .{ .x = tile_size, .y = tile_size },
                .tex_offset = .{ .x = 0, .y = 0 },
                .tex_extent = .{ .x = @intCast(dc.dirt.width), .y = @intCast(dc.dirt.height) },
                .color = .menu_tiles,
                .layer = 0,
            });
        }
    }
}

fn draw(ctx: *anyopaque, _: *Engine, _: f32, _: *const Util.BudgetContext) anyerror!void {
    var self = Util.ctx_to_self(@This(), ctx);

    self.batcher.clear();
    self.font_batcher.clear();
    self.screen.draw(&self.batcher, &self.font_batcher, ResourcePack.get_tex(.gui));

    self.font_batcher.add_text(&.{
        .str = "You were disconnected",
        .pos_x = 0,
        .pos_y = -26,
        .color = .white,
        .shadow_color = .menu_gray,
        .spacing = 0,
        .layer = 2,
        .reference = .middle_center,
        .origin = .middle_center,
    });

    const reason = Session.disconnect_reason();
    if (reason.len > 0) {
        self.font_batcher.add_text(&.{
            .str = reason,
            .pos_x = 0,
            .pos_y = 0,
            .color = .white,
            .shadow_color = .menu_gray,
            .spacing = 0,
            .layer = 2,
            .reference = .middle_center,
            .origin = .middle_center,
        });
    }

    try self.batcher.flush();
    try self.font_batcher.flush();
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
