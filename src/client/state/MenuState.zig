const std = @import("std");
const ae = @import("aether");
const Core = ae.Core;
const Util = ae.Util;
const Engine = ae.Engine;
const Rendering = ae.Rendering;
const State = Core.State;

const SpriteBatcher = @import("../ui/SpriteBatcher.zig");
const FontBatcher = @import("../ui/FontBatcher.zig");
const Vertex = @import("../graphics/Vertex.zig").Vertex;
const ResourcePack = @import("../ResourcePack.zig");
const SoundManager = @import("../SoundManager.zig");
const ui_input = @import("../ui/input.zig");
const Screen = @import("../ui/Screen.zig");
const MainMenuScreen = @import("../ui/MainMenuScreen.zig");
const DirectConnectScreen = @import("../ui/DirectConnectScreen.zig");
const LoadState = @import("LoadState.zig");
const Session = @import("Session.zig");

const log = std.log.scoped(.menu);

batcher: SpriteBatcher,
font_batcher: FontBatcher,
splash_mesh: FontBatcher.BatchMesh,
time: f32,
screen: Screen,
ui_repeat: ui_input.Repeat,
main_menu_ctx: MainMenuScreen.Context,
direct_connect_ctx: DirectConnectScreen.Context,
render_alloc: std.mem.Allocator,

var pipeline: Rendering.Pipeline.Handle = undefined;

fn init(ctx: *anyopaque, engine: *Engine) anyerror!void {
    var self = Util.ctx_to_self(@This(), ctx);
    const vert align(@alignOf(u32)) = @embedFile("basic_vert").*;
    const frag align(@alignOf(u32)) = @embedFile("basic_frag").*;
    pipeline = try Rendering.Pipeline.new(Vertex.Layout, &vert, &frag);

    const render_alloc = engine.allocator(.render);
    self.render_alloc = render_alloc;

    try ResourcePack.init(render_alloc, engine.allocator(.game), engine.io);
    errdefer ResourcePack.deinit();
    try ResourcePack.apply_tex_set(&.{ .dirt, .logo, .font, .gui });

    SoundManager.init(ResourcePack.get_pack());

    self.batcher = try SpriteBatcher.init(render_alloc, pipeline);
    self.font_batcher = try FontBatcher.init(render_alloc, pipeline, ResourcePack.get_tex(.font));
    self.splash_mesh = try self.font_batcher.build_mesh("Classic!", .splash_front, .splash_back, 0, 1);
    self.time = 0;
    self.ui_repeat = .{};

    try ui_input.ensure_registered();
    ui_input.set_profile(ui_input.default_profile());
    self.main_menu_ctx = .{
        .dirt = ResourcePack.get_tex(.dirt),
        .logo = ResourcePack.get_tex(.logo),
    };
    self.direct_connect_ctx = .{
        .dirt = ResourcePack.get_tex(.dirt),
    };
    self.screen = MainMenuScreen.build(&self.main_menu_ctx);
    self.screen.open(!ui_input.profile_uses_pointer());

    engine.report();
}

fn deinit(ctx: *anyopaque, _: *Engine) void {
    var self = Util.ctx_to_self(@This(), ctx);
    self.splash_mesh.deinit(self.render_alloc);
    self.font_batcher.deinit();
    self.batcher.deinit();

    Rendering.Pipeline.deinit(pipeline);
}

fn tick(ctx: *anyopaque, _: *Engine) anyerror!void {
    _ = ctx;
}

fn update(ctx: *anyopaque, engine: *Engine, dt: f32, _: *const Util.BudgetContext) anyerror!void {
    var self = Util.ctx_to_self(@This(), ctx);
    self.time += dt;
    SoundManager.update(dt, 0, 0, 0, 0, 0);

    // PSP: service deferred OSK at the top of update — the previous
    // frame's end_frame has completed so the GE is idle.
    if (ae.platform == .psp) {
        if (self.screen.osk_request) |idx| {
            self.screen.osk_request = null;
            self.screen.open_psp_osk(idx);
        }
    }

    const in = ui_input.build_frame(dt, &self.ui_repeat);
    self.screen.update(&in);

    // Screen-switch signals set by button callbacks.
    if (MainMenuScreen.pending_direct_connect) {
        MainMenuScreen.pending_direct_connect = false;
        self.screen = DirectConnectScreen.build(&self.direct_connect_ctx);
        self.screen.open(!ui_input.profile_uses_pointer());
        return;
    }

    if (MainMenuScreen.pending_singleplayer) {
        MainMenuScreen.pending_singleplayer = false;
        Session.mode = .singleplayer;
        Session.set_username("Player");
        LoadState.transition_here(engine) catch |err| {
            log.err("transition to LoadState failed: {}", .{err});
        };
        return;
    }

    const on_direct_connect = @intFromPtr(self.screen.ctx) == @intFromPtr(&self.direct_connect_ctx);
    if (on_direct_connect and (DirectConnectScreen.pending_back or self.screen.cancel_pressed)) {
        DirectConnectScreen.pending_back = false;
        self.screen = MainMenuScreen.build(&self.main_menu_ctx);
        self.screen.open(!ui_input.profile_uses_pointer());
    }

    if (DirectConnectScreen.pending_join) {
        DirectConnectScreen.pending_join = false;

        // PSP: service the system network config dialog before we try to
        // connect, so the socket stack is brought up on first use.
        const net_ready = if (ae.platform == .psp) ae.Psp.showNetDialog() else true;
        if (!net_ready) return;

        Session.mode = .multiplayer;
        LoadState.transition_here(engine) catch |err| {
            log.err("transition to LoadState failed: {}", .{err});
        };
    }
}

fn draw(ctx: *anyopaque, _: *Engine, _: f32, _: *const Util.BudgetContext) anyerror!void {
    var self = Util.ctx_to_self(@This(), ctx);

    self.batcher.clear();
    self.font_batcher.clear();
    self.screen.draw(&self.batcher, &self.font_batcher, ResourcePack.get_tex(.gui));

    try self.batcher.flush();
    try self.font_batcher.flush();

    // Draw "Classic!" splash text only on the main menu.
    const on_main = @intFromPtr(self.screen.ctx) == @intFromPtr(&self.main_menu_ctx);
    if (on_main) {
        const pulse = @sin(self.time * 15.0) * 0.05 + 2.0;
        const model = self.font_batcher.mesh_matrix("Classic!", 0, 1, 112, 80, .top_center, .top_center, 25, pulse, 2);

        Rendering.Pipeline.bind(pipeline);
        ResourcePack.get_tex(.font).bind();
        self.splash_mesh.draw(&model);
    }
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
