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
const Zip = @import("../util/Zip.zig");
const ui_input = @import("../ui/input.zig");
const Screen = @import("../ui/Screen.zig");
const MainMenuScreen = @import("../ui/MainMenuScreen.zig");
const DirectConnectScreen = @import("../ui/DirectConnectScreen.zig");
const LoadState = @import("LoadState.zig");
const Session = @import("Session.zig");

const log = std.log.scoped(.menu);

const MenuTextures = struct {
    dirt: Rendering.Texture,
    logo: Rendering.Texture,
    font: Rendering.Texture,
    gui: Rendering.Texture,

    /// Valid between MenuTextures.init() and MenuTextures.deinit().
    var inst: MenuTextures = undefined;

    fn load_from_pack(alloc: std.mem.Allocator, pack: *Zip, file: []const u8) !Rendering.Texture {
        var buf: [256]u8 = undefined;
        const path = try std.fmt.bufPrint(&buf, "assets/{s}.png", .{file});

        var stream = try pack.open(path);
        defer pack.closeStream(&stream);

        return try Rendering.Texture.load_from_reader(alloc, stream.reader);
    }

    pub fn init(alloc: std.mem.Allocator, pack: *Zip) !void {
        inst.dirt = try load_from_pack(alloc, pack, "minecraft/textures/dirt");
        inst.logo = try load_from_pack(alloc, pack, "crosscraft/textures/menu/logo");
        inst.logo.force_resident();
        inst.font = try load_from_pack(alloc, pack, "minecraft/textures/default");
        inst.gui = try load_from_pack(alloc, pack, "minecraft/textures/gui/gui");
    }

    pub fn deinit(alloc: std.mem.Allocator) void {
        inst.gui.deinit(alloc);
        inst.font.deinit(alloc);
        inst.logo.deinit(alloc);
        inst.dirt.deinit(alloc);
    }
};

pack: *Zip,
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

    self.pack = try Zip.init(engine.allocator(.game), engine.io, "pack.zip");
    try MenuTextures.init(render_alloc, self.pack);

    self.batcher = try SpriteBatcher.init(render_alloc, pipeline);
    self.font_batcher = try FontBatcher.init(render_alloc, pipeline, &MenuTextures.inst.font);
    self.splash_mesh = try self.font_batcher.build_mesh("Classic!", .splash_front, .splash_back, 0, 1);
    self.time = 0;
    self.ui_repeat = .{};

    try ui_input.ensure_registered();
    ui_input.set_profile(ui_input.default_profile());
    self.main_menu_ctx = .{
        .dirt = &MenuTextures.inst.dirt,
        .logo = &MenuTextures.inst.logo,
    };
    self.direct_connect_ctx = .{
        .dirt = &MenuTextures.inst.dirt,
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

    MenuTextures.deinit(self.render_alloc);
    self.pack.deinit();
    Rendering.Pipeline.deinit(pipeline);
}

fn tick(ctx: *anyopaque, _: *Engine) anyerror!void {
    _ = ctx;
}

fn update(ctx: *anyopaque, engine: *Engine, dt: f32, _: *const Util.BudgetContext) anyerror!void {
    var self = Util.ctx_to_self(@This(), ctx);
    self.time += dt;

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
    self.screen.draw(&self.batcher, &self.font_batcher, &MenuTextures.inst.gui);

    try self.batcher.flush();
    try self.font_batcher.flush();

    // Draw "Classic!" splash text only on the main menu.
    const on_main = @intFromPtr(self.screen.ctx) == @intFromPtr(&self.main_menu_ctx);
    if (on_main) {
        const pulse = @sin(self.time * 15.0) * 0.05 + 2.0;
        const model = self.font_batcher.mesh_matrix("Classic!", 0, 1, 112, 80, .top_center, .top_center, 25, pulse, 2);

        Rendering.Pipeline.bind(pipeline);
        MenuTextures.inst.font.bind();
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
