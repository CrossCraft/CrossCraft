const std = @import("std");
const ae = @import("aether");
const Math = ae.Math;
const Core = ae.Core;
const Util = ae.Util;
const Rendering = ae.Rendering;
const State = Core.State;

// TODO: Make these options stuff nice
pub const std_options = Util.std_options;

const sdk = if (ae.platform == .psp) @import("pspsdk") else void;
comptime {
    if (sdk != void)
        asm (sdk.extra.module.module_info("CrossCraft", .{ .mode = .User }, 1, 0));
}

pub const psp_stack_size: u32 = 256 * 1024;

// PSP: override panic/IO handlers that would otherwise pull in posix symbols.
pub const panic = if (ae.platform == .psp) sdk.extra.debug.panic else std.debug.FullPanic(std.debug.defaultPanic);
pub const std_options_debug_threaded_io = if (ae.platform == .psp) null else std.Io.Threaded.global_single_threaded;
pub const std_options_debug_io = if (ae.platform == .psp) sdk.extra.Io.psp_io else std.Io.Threaded.global_single_threaded.io();
pub const std_options_cwd = if (ae.platform == .psp) psp_cwd else null;
fn psp_cwd() std.Io.Dir {
    return .{ .handle = -1 };
}

const SpriteBatcher = @import("ui/SpriteBatcher.zig");
const Vertex = @import("vertex.zig").Vertex;

const Zip = @import("util/Zip.zig");

const MyState = struct {
    texture: Rendering.Texture,
    pack: *Zip,
    batcher: SpriteBatcher,

    fn init(ctx: *anyopaque) anyerror!void {
        var self = Util.ctx_to_self(MyState, ctx);
        const vert align(@alignOf(u32)) = @embedFile("basic_vert").*;
        const frag align(@alignOf(u32)) = @embedFile("basic_frag").*;
        pipeline = try Rendering.Pipeline.new(Vertex.Layout, &vert, &frag);

        self.pack = try Zip.init(Util.allocator(.game), Util.io(), "pack.zip");
        var stream = try self.pack.open("assets/minecraft/textures/dirt.png");
        defer self.pack.closeStream(&stream);
        self.texture = try Rendering.Texture.load_from_reader(stream.reader);
        self.batcher = try SpriteBatcher.init(pipeline);

        Util.report();
    }

    fn deinit(ctx: *anyopaque) void {
        var self = Util.ctx_to_self(MyState, ctx);
        self.batcher.deinit();
        self.texture.deinit();
        self.pack.deinit();
        Rendering.Pipeline.deinit(pipeline);
    }

    fn tick(ctx: *anyopaque) anyerror!void {
        _ = ctx;
    }

    fn update(ctx: *anyopaque, dt: f32, _: *const Util.BudgetContext) anyerror!void {
        const self = Util.ctx_to_self(MyState, ctx);
        _ = self;
        _ = dt;
    }

    fn draw(ctx: *anyopaque, _: f32, _: *const Util.BudgetContext) anyerror!void {
        var self = Util.ctx_to_self(MyState, ctx);

        // 2D UI pass
        self.batcher.clear();
        self.batcher.add_sprite(&.{
            .texture = &self.texture,
            .pos_offset = .{ .x = 0, .y = 0 },
            .pos_extent = .{ .x = 64, .y = 64 },
            .tex_offset = .{ .x = 0, .y = 0 },
            .tex_extent = .{ .x = @intCast(self.texture.width), .y = @intCast(self.texture.height) },
            .color = SpriteBatcher.Sprite.Color.white(),
            .layer = 0,
        });
        try self.batcher.flush();
    }

    pub fn state(self: *MyState) State {
        return .{ .ptr = self, .tab = &.{
            .init = init,
            .deinit = deinit,
            .tick = tick,
            .update = update,
            .draw = draw,
        } };
    }
};

var pipeline: Rendering.Pipeline.Handle = undefined;

pub fn main(init: std.process.Init) !void {
    const memory = try init.arena.allocator().alloc(u8, 32 * 1024 * 1024);

    const config = Util.MemoryConfig{
        .render = 8 * 1024 * 1024,
        .audio = 2 * 1024 * 1024,
        .game = 2 * 1024 * 1024,
        .user = 16 * 1024 * 1024,
        .scratch = 4 * 1024 * 1024,
    };
    var state: MyState = undefined;
    try ae.App.init(init.io, memory, config, 1280, 720, "Aether", false, false, &state.state());
    defer ae.App.deinit();
    try ae.App.main_loop();
}
