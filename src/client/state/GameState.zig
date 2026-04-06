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
const SelectionOutline = @import("../world/SelectionOutline.zig");
const Player = @import("../player/Player.zig");
const SpriteBatcher = @import("../ui/SpriteBatcher.zig");
const Zip = @import("../util/Zip.zig");

const log = std.log.scoped(.game);

const GameTextures = struct {
    terrain: Rendering.Texture,
    clouds: Rendering.Texture,
    gui: Rendering.Texture,
    atlas: TextureAtlas,

    /// Valid between GameTextures.init() and GameTextures.deinit().
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
        inst.gui = try load_from_pack(pack, "minecraft/textures/gui/gui");
        inst.gui.force_resident();
        inst.atlas = TextureAtlas.init(256, 256, 16, 16);
    }

    pub fn deinit() void {
        inst.gui.deinit();
        inst.clouds.deinit();
        inst.terrain.deinit();
    }
};

fake_conn: FakeConn,
conn: ClientConn,
pipeline: Rendering.Pipeline.Handle,
world: WorldRenderer,
player: Player,
ui_batcher: SpriteBatcher,
selection: SelectionOutline,

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

    // Player -- owns the camera; spawn Y is eye-level from the server
    if (self.conn.handshake_complete) {
        try self.player.init(
            @as(f32, @floatFromInt(self.conn.spawn_x)) / 32.0,
            @as(f32, @floatFromInt(self.conn.spawn_y)) / 32.0,
            @as(f32, @floatFromInt(self.conn.spawn_z)) / 32.0,
            &self.fake_conn.client_writer,
        );
    } else {
        try self.player.init(128.0, 44.0, 128.0, &self.fake_conn.client_writer);
    }

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
        &self.player.camera,
    );

    // Let block-change packets find the renderer so they can mark sections.
    self.conn.world_renderer = &self.world;

    // UI sprite batcher for HUD overlay (crosshair, etc.)
    self.ui_batcher = try SpriteBatcher.init(self.pipeline);

    // Block selection outline (line mesh, drawn after the world pass).
    self.selection = try SelectionOutline.init(self.pipeline);

    Util.report();
}

fn deinit(ctx: *anyopaque) void {
    var self = Util.ctx_to_self(@This(), ctx);
    self.selection.deinit();
    self.ui_batcher.deinit();
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
    self.player.update(dt);
    self.world.update(dt, budget, &self.player.camera);
}

fn draw(ctx: *anyopaque, _: f32, _: *const Util.BudgetContext) anyerror!void {
    var self = Util.ctx_to_self(@This(), ctx);
    self.conn.drain_packets();
    self.player.camera.apply();
    self.world.draw(&self.player.camera);

    // Selection outline: still in the 3D pass, depth-tested against the
    // opaque world. WorldRenderer leaves alpha blend on after the
    // transparent pass; force it off so the line shader doesn't discard.
    if (self.player.selected) |hit| {
        Rendering.gfx.api.set_alpha_blend(false);
        Rendering.Texture.Default.bind();
        var t = Rendering.Transform.new();
        t.pos = .{
            .x = @as(f32, @floatFromInt(hit.x)),
            .y = @as(f32, @floatFromInt(hit.y)),
            .z = @as(f32, @floatFromInt(hit.z)),
        };
        // Vertices live in SNORM16 block-units (1 block = 2048 / 32768);
        // scale by 16 to recover world units, matching ChunkMesh.
        t.scale = .{ .x = 16.0, .y = 16.0, .z = 16.0 };
        self.selection.draw(&t);
        // Restore alpha blending for the HUD pass so the crosshair's
        // transparent texels stay transparent (the basic shader forces
        // color.a = 1.0 when blending is off).
        Rendering.gfx.api.set_alpha_blend(true);
    }

    // UI pass: orthographic overlay drawn on top of the 3D scene.
    // clear_depth so HUD sprites aren't z-rejected by world geometry;
    // SpriteBatcher.flush() sets identity proj/view (orthographic NDC).
    Rendering.gfx.api.clear_depth();
    self.ui_batcher.clear();
    self.player.draw_ui(&self.ui_batcher, &GameTextures.inst.gui);
    try self.ui_batcher.flush();
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
