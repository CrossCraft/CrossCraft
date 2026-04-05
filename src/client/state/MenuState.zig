const std = @import("std");
const ae = @import("aether");
const Core = ae.Core;
const Util = ae.Util;
const Rendering = ae.Rendering;
const State = Core.State;

const SpriteBatcher = @import("../ui/SpriteBatcher.zig");
const FontBatcher = @import("../ui/FontBatcher.zig");
const Scaling = @import("../ui/Scaling.zig");
const Vertex = @import("../graphics/Vertex.zig").Vertex;
const Zip = @import("../util/Zip.zig");

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
}

fn draw(ctx: *anyopaque, _: f32, _: *const Util.BudgetContext) anyerror!void {
    var self = Util.ctx_to_self(@This(), ctx);

    const screen_w = Rendering.gfx.surface.get_width();
    const screen_h = Rendering.gfx.surface.get_height();
    const scale = Scaling.compute(screen_w, screen_h);
    const extent_x: i16 = @intCast((screen_w + scale - 1) / scale);
    const extent_y: i16 = @intCast((screen_h + scale - 1) / scale);

    self.batcher.clear();
    var y: i16 = 0;
    const tile_size = 32;
    while (y < extent_y) : (y += tile_size) {
        var x: i16 = 0;
        while (x < extent_x) : (x += tile_size) {
            const dirt = &MenuTextures.inst.dirt;
            self.batcher.add_sprite(&.{
                .texture = dirt,
                .pos_offset = .{ .x = x, .y = y },
                .pos_extent = .{ .x = tile_size, .y = tile_size },
                .tex_offset = .{ .x = 0, .y = 0 },
                .tex_extent = .{ .x = @intCast(dirt.width), .y = @intCast(dirt.height) },
                .color = .menu_tiles,
                .layer = 0,
            });
        }
    }
    const logo = &MenuTextures.inst.logo;
    self.batcher.add_sprite(&.{
        .texture = logo,
        .pos_offset = .{ .x = 0, .y = 24 },
        .pos_extent = .{ .x = 512, .y = 64 },
        .tex_offset = .{ .x = 0, .y = 0 },
        .tex_extent = .{ .x = @intCast(logo.width), .y = @intCast(logo.height) },
        .color = .white,
        .layer = 1,
        .reference = .top_center,
        .origin = .top_center,
    });

    // Button sprites: disabled, normal, highlight, and a second normal.
    const gui = &MenuTextures.inst.gui;
    const btn_uv = [_]SpriteBatcher.Sprite.Range{
        .{ .x = 0, .y = 46 }, // disabled
        .{ .x = 0, .y = 66 }, // normal
        .{ .x = 0, .y = 86 }, // highlight
    };
    const btn_y = [_]i16{ 120, 144, 168, 202 };
    for (0..4) |i| {
        self.batcher.add_sprite(&.{
            .texture = gui,
            .pos_offset = .{ .x = 0, .y = btn_y[i] },
            .pos_extent = .{ .x = 200, .y = 20 },
            .tex_offset = btn_uv[1],
            .tex_extent = .{ .x = 200, .y = 20 },
            .color = .white,
            .layer = 2,
            .reference = .top_center,
            .origin = .top_center,
        });
    }

    try self.batcher.flush();

    self.font_batcher.clear();
    const btn_labels = [_][]const u8{ "Singleplayer", "Multiplayer", "Mods and Texture Packs", "Options..." };
    for (btn_labels, 0..) |label, i| {
        self.font_batcher.add_text(&.{
            .str = label,
            .pos_x = 0,
            .pos_y = btn_y[i] + 6,
            .color = .white,
            .shadow_color = .menu_gray,
            .spacing = 0,
            .layer = 3,
            .reference = .top_center,
            .origin = .top_center,
        });
    }
    const version: []const u8 = "CrossCraft Classic v0.1.0";
    self.font_batcher.add_text(&.{
        .str = version,
        .pos_x = 2,
        .pos_y = 2,
        .color = .dark_gray,
        .shadow_color = .menu_version,
        .spacing = 0,
        .layer = 2,
        .reference = .top_left,
        .origin = .top_left,
    });
    const copyleft: []const u8 = "Copyleft CrossCraft Team. Distribute!";
    self.font_batcher.add_text(&.{
        .str = copyleft,
        .pos_x = -2,
        .pos_y = -2,
        .color = .white,
        .shadow_color = .menu_copyright,
        .spacing = 0,
        .layer = 2,
        .reference = .bottom_right,
        .origin = .bottom_right,
    });
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
