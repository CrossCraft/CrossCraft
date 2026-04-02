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
const Server = @import("game").Server;
const World = @import("game").World;
const GameState = @import("GameState.zig");

const log = std.log.scoped(.game);

var server_ready: std.atomic.Value(bool) = .init(false);

fn serverTask(alloc: std.mem.Allocator, scratch: std.mem.Allocator, seed: u64, io: std.Io) void {
    // TODO: user pool (8 MiB) may need expansion once multiplayer clients join
    Server.init(alloc, scratch, seed, io) catch |err| {
        log.err("server init failed: {}", .{err});
        return;
    };
    server_ready.store(true, .release);
}

const LoadTextures = struct {
    dirt: Rendering.Texture,
    font: Rendering.Texture,

    var inst: LoadTextures = undefined;

    fn load_from_pack(pack: *Zip, file: []const u8) !Rendering.Texture {
        var buf: [256]u8 = undefined;
        const path = try std.fmt.bufPrint(&buf, "assets/{s}.png", .{file});

        var stream = try pack.open(path);
        defer pack.closeStream(&stream);

        return try Rendering.Texture.load_from_reader(stream.reader);
    }

    pub fn init(pack: *Zip) !void {
        inst.dirt = try load_from_pack(pack, "minecraft/textures/dirt");
        inst.font = try load_from_pack(pack, "minecraft/textures/default");
    }

    pub fn deinit() void {
        inst.font.deinit();
        inst.dirt.deinit();
    }
};

pack: *Zip,
batcher: SpriteBatcher,
font_batcher: FontBatcher,
time: f32,
server_future: std.Io.Future(void),
server_notified: bool,

var pipeline: Rendering.Pipeline.Handle = undefined;
var game_state: GameState = undefined;
var state_inst: State = undefined;

fn init(ctx: *anyopaque) anyerror!void {
    var self = Util.ctx_to_self(@This(), ctx);
    const vert align(@alignOf(u32)) = @embedFile("basic_vert").*;
    const frag align(@alignOf(u32)) = @embedFile("basic_frag").*;
    pipeline = try Rendering.Pipeline.new(Vertex.Layout, &vert, &frag);

    self.pack = try Zip.init(Util.allocator(.game), Util.io(), "pack.zip");
    try LoadTextures.init(self.pack);

    self.batcher = try SpriteBatcher.init(pipeline);
    self.font_batcher = try FontBatcher.init(pipeline, &LoadTextures.inst.font);
    self.time = 0;
    self.server_notified = false;

    const io = Util.io();
    const seed: u64 = @bitCast(@as(i64, @truncate(std.Io.Clock.Timestamp.now(io, .boot).raw.nanoseconds)));
    server_ready.store(false, .monotonic);
    // TODO: allocator pool budget may need tuning for server + client coexistence
    self.server_future = io.async(serverTask, .{ Util.allocator(.user), Util.allocator(.user), seed, io });

    Util.report();
}

fn deinit(ctx: *anyopaque) void {
    var self = Util.ctx_to_self(@This(), ctx);
    self.server_future.await(Util.io());
    self.font_batcher.deinit();
    self.batcher.deinit();

    LoadTextures.deinit();
    self.pack.deinit();
    Rendering.Pipeline.deinit(pipeline);
}

fn tick(ctx: *anyopaque) anyerror!void {
    var self = Util.ctx_to_self(@This(), ctx);
    if (!self.server_notified and server_ready.load(.acquire)) {
        self.server_notified = true;
        state_inst = game_state.state();
        try ae.Core.state_machine.transition(&state_inst);
    }
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
            const dirt = &LoadTextures.inst.dirt;
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

    // Loading bar
    const bar_width: i16 = 100;
    const bar_height: i16 = 2;
    const bar_y: i16 = 16;
    const progress: f32 = switch (World.load_status) {
        .loading => @min(self.time / 3.0, 1.0),
        .generating => |phase| @as(f32, @floatFromInt(@intFromEnum(phase))) / 10.0,
        .complete => 1.0,
    };
    const default_tex = &Rendering.Texture.Default;

    self.batcher.add_sprite(&.{
        .texture = default_tex,
        .pos_offset = .{ .x = 0, .y = bar_y },
        .pos_extent = .{ .x = bar_width, .y = bar_height },
        .tex_offset = .{ .x = 0, .y = 0 },
        .tex_extent = .{ .x = @intCast(default_tex.width), .y = @intCast(default_tex.height) },
        .color = .progress_bg,
        .layer = 1,
        .reference = .middle_center,
        .origin = .middle_center,
    });

    const progress_w: i16 = @intFromFloat(@as(f32, @floatFromInt(bar_width)) * progress);
    if (progress_w > 0) {
        self.batcher.add_sprite(&.{
            .texture = default_tex,
            .pos_offset = .{ .x = -@divTrunc(bar_width, 2), .y = bar_y },
            .pos_extent = .{ .x = progress_w, .y = bar_height },
            .tex_offset = .{ .x = 0, .y = 0 },
            .tex_extent = .{ .x = @intCast(default_tex.width), .y = @intCast(default_tex.height) },
            .color = .progress_bar,
            .layer = 2,
            .reference = .middle_center,
            .origin = .middle_left,
        });
    }

    try self.batcher.flush();

    self.font_batcher.clear();

    const load_status = World.load_status;
    const loading: []const u8 = switch (load_status) {
        .loading => "Loading level",
        .generating, .complete => "Generating level",
    };
    self.font_batcher.add_text(&.{
        .str = loading,
        .pos_x = 0,
        .pos_y = -16,
        .color = .white,
        .shadow_color = .menu_gray,
        .spacing = 0,
        .layer = 2,
        .reference = .middle_center,
        .origin = .middle_center,
    });

    const status: []const u8 = switch (load_status) {
        .loading => "Loading...",
        .generating => |phase| switch (phase) {
            .raising => "Raising...",
            .erosion => "Eroding...",
            .strata => "Layering...",
            .caves => "Carving...",
            .ores => "Placing ores...",
            .merge => "Merging...",
            .water => "Flooding water...",
            .lava => "Flooding lava...",
            .surface => "Surfacing...",
            .plants => "Planting...",
        },
        .complete => "Done!",
    };
    self.font_batcher.add_text(&.{
        .str = status,
        .pos_x = 0,
        .pos_y = 7,
        .color = .white,
        .shadow_color = .menu_gray,
        .spacing = 0,
        .layer = 2,
        .reference = .middle_center,
        .origin = .middle_center,
    });

    try self.font_batcher.flush();
    try std.Io.sleep(Util.io(), std.Io.Duration.fromMilliseconds(50), .real);
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
