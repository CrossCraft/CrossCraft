const std = @import("std");
const ae = @import("aether");
const Core = ae.Core;
const Util = ae.Util;
const Rendering = ae.Rendering;
const State = Core.State;

const Server = @import("game").Server;
const FakeConn = @import("../connection/FakeConn.zig").FakeConn;
const ClientConn = @import("../connection/ClientConn.zig");
const Vertex = @import("../graphics/Vertex.zig").Vertex;
const TextureAtlas = @import("../graphics/TextureAtlas.zig").TextureAtlas;
const WorldRenderer = @import("../world/world.zig");
const Camera = @import("../player/Camera.zig");
const Zip = @import("../util/Zip.zig");

const log = std.log.scoped(.game);

const GameTextures = struct {
    terrain: Rendering.Texture,
    clouds: Rendering.Texture,
    atlas: TextureAtlas,

    var inst: GameTextures = undefined;

    fn load_from_pack(pack: *Zip, file: []const u8) !Rendering.Texture {
        var buf: [256]u8 = undefined;
        const path = try std.fmt.bufPrint(&buf, "assets/{s}.png", .{file});
        var stream = try pack.open(path);
        defer pack.closeStream(&stream);
        return try Rendering.Texture.load_from_reader(stream.reader);
    }

    pub fn init(pack: *Zip) !void {
        inst.terrain = try load_from_pack(pack, "minecraft/textures/terrain");
        inst.terrain.force_resident();
        inst.clouds = try load_from_pack(pack, "minecraft/textures/clouds");
        inst.clouds.force_resident();
        inst.atlas = TextureAtlas.init(256, 256, 16, 16);
    }

    pub fn deinit() void {
        inst.clouds.deinit();
        inst.terrain.deinit();
    }
};

fake_conn: FakeConn,
conn: ClientConn,
pipeline: Rendering.Pipeline.Handle,
world: WorldRenderer,
camera: Camera,
time: f32,

fn init(ctx: *anyopaque) anyerror!void {
    var self = Util.ctx_to_self(@This(), ctx);
    self.fake_conn.init();

    _ = Server.local_join(
        &self.fake_conn.server_reader,
        &self.fake_conn.server_writer,
        &self.fake_conn.connected,
    ) orelse return error.ServerFull;

    self.conn.init(&self.fake_conn.client_reader, &self.fake_conn.client_writer);
    try self.conn.join("Player");

    Server.drain_local_packets();
    self.conn.drain_packets();

    // Redistribute memory for game state
    @import("../config.zig").apply_runtime_budgets();

    // Pipeline
    const vert align(@alignOf(u32)) = @embedFile("basic_vert").*;
    const frag align(@alignOf(u32)) = @embedFile("basic_frag").*;
    self.pipeline = try Rendering.Pipeline.new(Vertex.Layout, &vert, &frag);

    // Sky color
    const sky = @import("../graphics/Color.zig").Color.game_daytime;
    Rendering.gfx.api.set_clear_color(
        @as(f32, @floatFromInt(sky.r)) / 255.0,
        @as(f32, @floatFromInt(sky.g)) / 255.0,
        @as(f32, @floatFromInt(sky.b)) / 255.0,
        1.0,
    );

    // Camera
    self.camera = Camera.init(128.0, 44.0, 128.0);
    self.camera.pitch = 0;

    // Textures
    var pack = try Zip.init(Util.allocator(.game), Util.io(), "pack.zip");
    defer pack.deinit();
    try GameTextures.init(pack);

    // World renderer
    self.world = try WorldRenderer.init(
        self.pipeline,
        &GameTextures.inst.terrain,
        &GameTextures.inst.clouds,
        GameTextures.inst.atlas,
        &self.camera,
    );

    self.time = 0;
    Util.report();
}

fn deinit(ctx: *anyopaque) void {
    var self = Util.ctx_to_self(@This(), ctx);
    self.world.deinit();
    GameTextures.deinit();
    Rendering.Pipeline.deinit(self.pipeline);
    self.fake_conn.connected = false;
}

fn tick(_: *anyopaque) anyerror!void {
    Server.drain_local_packets();
    Server.tick();
}

fn update(ctx: *anyopaque, dt: f32, budget: *const Util.BudgetContext) anyerror!void {
    var self = Util.ctx_to_self(@This(), ctx);
    self.time += dt;
    self.camera.yaw = self.time * 0.3;
    self.world.update(dt, budget);
}

fn draw(ctx: *anyopaque, _: f32, _: *const Util.BudgetContext) anyerror!void {
    var self = Util.ctx_to_self(@This(), ctx);
    self.conn.drain_packets();
    self.camera.apply();
    self.world.draw(&self.camera);
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
