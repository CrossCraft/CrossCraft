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
const WorldRenderer = @import("../world/world.zig");
const Camera = @import("../player/Camera.zig");
const Zip = @import("../util/Zip.zig");

const log = std.log.scoped(.game);
const config = @import("../config.zig").current;

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
    self.camera.pitch = 0.4;

    // World renderer (loads terrain texture, creates sections + pool)
    var pack = try Zip.init(Util.allocator(.game), Util.io(), "pack.zip");
    defer pack.deinit();
    const textures = try WorldRenderer.Textures.init(pack);
    self.world = try WorldRenderer.init(self.pipeline, textures, &self.camera);

    self.time = 0;
    Util.report();
}

fn deinit(ctx: *anyopaque) void {
    var self = Util.ctx_to_self(@This(), ctx);
    self.world.deinit();
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
    self.world.update(budget);
}

fn draw(ctx: *anyopaque, _: f32, _: *const Util.BudgetContext) anyerror!void {
    var self = Util.ctx_to_self(@This(), ctx);
    self.conn.drain_packets();
    self.camera.apply();

    const sky = @import("../graphics/Color.zig").Color.game_daytime;
    const fog_end: f32 = @floatFromInt(config.chunk_radius * 16 - 16);
    const fog_start: f32 = fog_end * 0.4;
    Rendering.gfx.api.set_fog(
        true,
        fog_start,
        fog_end,
        @as(f32, @floatFromInt(sky.r)) / 255.0,
        @as(f32, @floatFromInt(sky.g)) / 255.0,
        @as(f32, @floatFromInt(sky.b)) / 255.0,
    );

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
