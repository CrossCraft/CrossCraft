const std = @import("std");
const ae = @import("aether");
const Core = ae.Core;
const Util = ae.Util;
const Rendering = ae.Rendering;
const State = Core.State;

const SpriteBatcher = @import("../ui/SpriteBatcher.zig");
const Scaling = @import("../ui/Scaling.zig");
const Vertex = @import("../vertex.zig").Vertex;
const Zip = @import("../util/Zip.zig");

const MenuTextures = struct {
    dirt: Rendering.Texture,
    logo: Rendering.Texture,

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
    }

    pub fn deinit() void {
        inst.logo.deinit();
        inst.dirt.deinit();
    }
};

pack: *Zip,
batcher: SpriteBatcher,

var pipeline: Rendering.Pipeline.Handle = undefined;

fn init(ctx: *anyopaque) anyerror!void {
    var self = Util.ctx_to_self(@This(), ctx);
    const vert align(@alignOf(u32)) = @embedFile("basic_vert").*;
    const frag align(@alignOf(u32)) = @embedFile("basic_frag").*;
    pipeline = try Rendering.Pipeline.new(Vertex.Layout, &vert, &frag);

    self.pack = try Zip.init(Util.allocator(.game), Util.io(), "pack.zip");
    try MenuTextures.init(self.pack);

    self.batcher = try SpriteBatcher.init(pipeline);

    Util.report();
}

fn deinit(ctx: *anyopaque) void {
    var self = Util.ctx_to_self(@This(), ctx);
    self.batcher.deinit();

    MenuTextures.deinit();
    self.pack.deinit();
    Rendering.Pipeline.deinit(pipeline);
}

fn tick(ctx: *anyopaque) anyerror!void {
    _ = ctx;
}

fn update(ctx: *anyopaque, dt: f32, _: *const Util.BudgetContext) anyerror!void {
    const self = Util.ctx_to_self(@This(), ctx);
    _ = self;
    _ = dt;
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
    while (y < extent_y) : (y += 32) {
        var x: i16 = 0;
        while (x < extent_x) : (x += 32) {
            const dirt = &MenuTextures.inst.dirt;
            self.batcher.add_sprite(&.{
                .texture = dirt,
                .pos_offset = .{ .x = x, .y = y },
                .pos_extent = .{ .x = 32, .y = 32 },
                .tex_offset = .{ .x = 0, .y = 0 },
                .tex_extent = .{ .x = @intCast(dirt.width), .y = @intCast(dirt.height) },
                .color = .dark_gray,
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

    try self.batcher.flush();
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
