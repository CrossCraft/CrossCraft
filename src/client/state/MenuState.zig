const std = @import("std");
const ae = @import("aether");
const Core = ae.Core;
const Util = ae.Util;
const Rendering = ae.Rendering;
const State = Core.State;

const SpriteBatcher = @import("../ui/SpriteBatcher.zig");
const FontBatcher = @import("../ui/FontBatcher.zig");
const Vertex = @import("../graphics/Vertex.zig").Vertex;
const Zip = @import("../util/Zip.zig");
const ui_input = @import("../ui/input.zig");
const Screen = @import("../ui/Screen.zig");
const MainMenuScreen = @import("../ui/MainMenuScreen.zig");

const MenuTextures = struct {
    dirt: Rendering.Texture,
    logo: Rendering.Texture,
    font: Rendering.Texture,
    gui: Rendering.Texture,

    /// Valid between MenuTextures.init() and MenuTextures.deinit().
    var inst: MenuTextures = undefined;

    fn load_from_pack(pack: *Zip, file: []const u8) !Rendering.Texture {
        var buf: [256]u8 = undefined;
        const path = try std.fmt.bufPrint(&buf, "assets/{s}.png", .{file});

        var stream = try pack.open(path);
        defer pack.closeStream(&stream);

        return try Rendering.Texture.load_from_reader(stream.reader);
    }

    pub fn init(pack: *Zip) !void {
        inst.dirt = try load_from_pack(pack, "minecraft/textures/dirt");
        inst.logo = try load_from_pack(pack, "crosscraft/textures/menu/logo");
        inst.logo.force_resident();
        inst.font = try load_from_pack(pack, "minecraft/textures/default");
        inst.gui = try load_from_pack(pack, "minecraft/textures/gui/gui");
    }

    pub fn deinit() void {
        inst.gui.deinit();
        inst.font.deinit();
        inst.logo.deinit();
        inst.dirt.deinit();
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

var pipeline: Rendering.Pipeline.Handle = undefined;

fn init(ctx: *anyopaque) anyerror!void {
    var self = Util.ctx_to_self(@This(), ctx);
    const vert align(@alignOf(u32)) = @embedFile("basic_vert").*;
    const frag align(@alignOf(u32)) = @embedFile("basic_frag").*;
    pipeline = try Rendering.Pipeline.new(Vertex.Layout, &vert, &frag);

    self.pack = try Zip.init(Util.allocator(.game), Util.io(), "pack.zip");
    try MenuTextures.init(self.pack);

    self.batcher = try SpriteBatcher.init(pipeline);
    self.font_batcher = try FontBatcher.init(pipeline, &MenuTextures.inst.font);
    self.splash_mesh = try self.font_batcher.build_mesh("Classic!", .splash_front, .splash_back, 0, 1);
    self.time = 0;
    self.ui_repeat = .{};

    try ui_input.ensure_registered();
    ui_input.set_profile(ui_input.default_profile());
    self.main_menu_ctx = .{
        .dirt = &MenuTextures.inst.dirt,
        .logo = &MenuTextures.inst.logo,
    };
    self.screen = MainMenuScreen.build(&self.main_menu_ctx);
    self.screen.open(!ui_input.profile_uses_pointer());

    Util.report();
}

fn deinit(ctx: *anyopaque) void {
    var self = Util.ctx_to_self(@This(), ctx);
    self.splash_mesh.deinit();
    self.font_batcher.deinit();
    self.batcher.deinit();

    MenuTextures.deinit();
    self.pack.deinit();
    Rendering.Pipeline.deinit(pipeline);
}

fn tick(ctx: *anyopaque) anyerror!void {
    _ = ctx;
}

fn update(ctx: *anyopaque, dt: f32, _: *const Util.BudgetContext) anyerror!void {
    var self = Util.ctx_to_self(@This(), ctx);
    self.time += dt;

    const in = ui_input.build_frame(dt, &self.ui_repeat);
    self.screen.update(&in);
}

fn draw(ctx: *anyopaque, _: f32, _: *const Util.BudgetContext) anyerror!void {
    var self = Util.ctx_to_self(@This(), ctx);

    self.batcher.clear();
    self.font_batcher.clear();
    self.screen.draw(&self.batcher, &self.font_batcher, &MenuTextures.inst.gui);

    try self.batcher.flush();
    try self.font_batcher.flush();

    // Draw "Classic!" splash text as an independent transformed mesh.
    const pulse = @sin(self.time * 15.0) * 0.05 + 2.0;
    const model = self.font_batcher.mesh_matrix("Classic!", 0, 1, 112, 80, .top_center, .top_center, 25, pulse, 2);

    Rendering.Pipeline.bind(pipeline);
    MenuTextures.inst.font.bind();
    self.splash_mesh.draw(&model);
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
