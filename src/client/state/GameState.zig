const std = @import("std");
const ae = @import("aether");
const Core = ae.Core;
const Util = ae.Util;
const Rendering = ae.Rendering;
const State = Core.State;

const Server = @import("game").Server;
const World = @import("game").World;
const c = @import("common").consts;
const collision = @import("../player/collision.zig");
const FakeConn = @import("../connection/FakeConn.zig").FakeConn;
const ClientConn = @import("../connection/ClientConn.zig");
const Vertex = @import("../graphics/Vertex.zig").Vertex;
const TextureAtlas = @import("../graphics/TextureAtlas.zig").TextureAtlas;
const WorldRenderer = @import("../world/world.zig");
const SelectionOutline = @import("../world/SelectionOutline.zig");
const Player = @import("../player/Player.zig");
const BlockHand = @import("../player/BlockHand.zig");
const SpriteBatcher = @import("../ui/SpriteBatcher.zig");
const IsoBlockDrawer = @import("../ui/IsoBlockDrawer.zig");
const Zip = @import("../util/Zip.zig");

const log = std.log.scoped(.game);

// Still-water tile sits at atlas (14, 0); still-lava at (14, 1). The animation
// source PNGs are vertical strips of 16x16 frames.
const water_tile_col: u32 = 14;
const water_tile_row: u32 = 0;
const lava_tile_col: u32 = 14;
const lava_tile_row: u32 = 1;
const tile_size: u32 = 16;
const anim_period_ticks: u32 = 2;
const selection_depth_nudge: f32 = 1.0 / 160.0;

const GameTextures = struct {
    terrain: Rendering.Texture,
    clouds: Rendering.Texture,
    gui: Rendering.Texture,
    water_still: Rendering.Texture,
    lava_still: Rendering.Texture,
    atlas: TextureAtlas,
    anim_tick: u32,

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
        // Animation source strips: kept CPU-side only; never bound. We read
        // frames via get_pixel and blit them into the terrain atlas.
        inst.water_still = try load_from_pack(pack, "crosscraft/textures/water_still");
        inst.lava_still = try load_from_pack(pack, "crosscraft/textures/lava_still");
        std.debug.assert(inst.water_still.width == tile_size);
        std.debug.assert(inst.lava_still.width == tile_size);
        std.debug.assert(inst.water_still.height % tile_size == 0);
        std.debug.assert(inst.lava_still.height % tile_size == 0);
        inst.atlas = TextureAtlas.init(256, 256, 16, 16);
        inst.anim_tick = 0;
    }

    pub fn deinit() void {
        inst.lava_still.deinit();
        inst.water_still.deinit();
        inst.gui.deinit();
        inst.clouds.deinit();
        inst.terrain.deinit();
    }

    /// Blits one 16x16 frame from a vertical-strip animation source into the
    /// given atlas tile, via get_pixel/set_pixel so that platform-specific
    /// swizzling and pixel formats are handled correctly.
    fn blit_frame(
        src: *const Rendering.Texture,
        frame: u32,
        dst_col: u32,
        dst_row: u32,
    ) void {
        const dst_x0 = dst_col * tile_size;
        const dst_y0 = dst_row * tile_size;
        const src_y0 = frame * tile_size;
        var y: u32 = 0;
        while (y < tile_size) : (y += 1) {
            var x: u32 = 0;
            while (x < tile_size) : (x += 1) {
                const px = src.get_pixel(x, src_y0 + y);
                inst.terrain.set_pixel(dst_x0 + x, dst_y0 + y, px);
            }
        }
    }

    /// Advance fluid animations. Called every game tick; actually updates
    /// terrain once every `anim_period_ticks` ticks.
    pub fn tick_animations() void {
        inst.anim_tick +%= 1;
        if (inst.anim_tick % anim_period_ticks != 0) return;

        const water_frames: u32 = inst.water_still.height / tile_size;
        const lava_frames: u32 = inst.lava_still.height / tile_size;
        const step = inst.anim_tick / anim_period_ticks;

        blit_frame(&inst.water_still, step % water_frames, water_tile_col, water_tile_row);
        blit_frame(&inst.lava_still, step % lava_frames, lava_tile_col, lava_tile_row);
        inst.terrain.update();
    }
};

fake_conn: FakeConn,
conn: ClientConn,
pipeline: Rendering.Pipeline.Handle,
world: WorldRenderer,
player: Player,
ui_batcher: SpriteBatcher,
ui_selector_batcher: SpriteBatcher,
iso_blocks: IsoBlockDrawer,
selection: SelectionOutline,
held: BlockHand,

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

    // Wire break particles now that both player and world exist.
    self.player.particle_sink = &self.world.particles;

    // UI sprite batcher for HUD overlay (crosshair, etc.)
    self.ui_batcher = try SpriteBatcher.init(self.pipeline);
    self.ui_selector_batcher = try SpriteBatcher.init(self.pipeline);

    // Iso-projected block icons for hotbar slots; draws to the same terrain
    // atlas as the world.
    self.iso_blocks = try IsoBlockDrawer.init(
        self.pipeline,
        &GameTextures.inst.terrain,
        GameTextures.inst.atlas,
    );

    // Block selection outline (line mesh, drawn after the world pass).
    self.selection = try SelectionOutline.init(self.pipeline);

    // Held-block viewmodel. Uses the same terrain atlas as the world.
    self.held = try BlockHand.init(self.pipeline, GameTextures.inst.atlas);
    self.player.held_renderer = &self.held;

    Util.report();
}

fn deinit(ctx: *anyopaque) void {
    var self = Util.ctx_to_self(@This(), ctx);
    self.held.deinit();
    self.selection.deinit();
    self.iso_blocks.deinit();
    self.ui_selector_batcher.deinit();
    self.ui_batcher.deinit();
    self.world.deinit();
    GameTextures.deinit();
    Rendering.Pipeline.deinit(self.pipeline);
    self.fake_conn.connected = false;
}

fn tick(_: *anyopaque) anyerror!void {
    Server.drain_local_packets();
    Server.tick();
    GameTextures.tick_animations();
}

fn update(ctx: *anyopaque, dt: f32, budget: *const Util.BudgetContext) anyerror!void {
    var self = Util.ctx_to_self(@This(), ctx);
    self.player.update(dt);
    self.world.update(dt, budget, &self.player.camera);
    const slot_block = self.player.hotbar[self.player.selected_slot];
    self.held.update(dt, slot_block, player_in_shadow(&self.player));
}

/// True when the voxel containing the player's eye is not directly sunlit.
/// Used to tint the held-block viewmodel to match the surrounding lighting,
/// matching the per-face shading the chunk mesher applies to world geometry.
/// Out-of-world positions (e.g. the brief above-ceiling case during a
/// teleport) read as lit so the held block never goes dark unexpectedly.
fn player_in_shadow(player: *const Player) bool {
    const eye_y = player.pos_y + collision.EYE_HEIGHT;
    const bx_i: i32 = @intFromFloat(@floor(player.pos_x));
    const by_i: i32 = @intFromFloat(@floor(eye_y));
    const bz_i: i32 = @intFromFloat(@floor(player.pos_z));
    if (bx_i < 0 or bx_i >= c.WorldLength or
        by_i < 0 or by_i >= c.WorldHeight or
        bz_i < 0 or bz_i >= c.WorldDepth) return false;
    return !World.is_sunlit(@intCast(bx_i), @intCast(by_i), @intCast(bz_i));
}

fn draw(ctx: *anyopaque, _: f32, _: *const Util.BudgetContext) anyerror!void {
    var self = Util.ctx_to_self(@This(), ctx);
    self.conn.drain_packets();
    self.player.camera.apply();
    self.world.draw(&self.player.camera);

    // Selection outline: still in the 3D pass, depth-tested against the world.
    // Nudge it slightly toward the camera so it does not z-fight the selected
    // block face, without making it show through other geometry.
    if (self.player.selected) |hit| {
        Rendering.Texture.Default.bind();
        var t = Rendering.Transform.new();
        const cp = @cos(self.player.camera.pitch);
        const toward_camera = .{
            .x = @sin(self.player.camera.yaw) * cp,
            .y = @sin(self.player.camera.pitch),
            .z = @cos(self.player.camera.yaw) * cp,
        };
        t.pos = .{
            .x = @as(f32, @floatFromInt(hit.x)) + toward_camera.x * selection_depth_nudge,
            .y = @as(f32, @floatFromInt(hit.y)) + toward_camera.y * selection_depth_nudge,
            .z = @as(f32, @floatFromInt(hit.z)) + toward_camera.z * selection_depth_nudge,
        };
        // Vertices live in SNORM16 block-units (1 block = 2048 / 32768);
        // scale by 16 to recover world units, matching ChunkMesh.
        t.scale = .{ .x = 16.0, .y = 16.0, .z = 16.0 };
        self.selection.draw(&t);
    }

    // Held-block viewmodel: swaps in its own projection + identity view,
    // clears depth internally so it never z-fights against nearby world
    // geometry. Matrices are left in that state on exit; the UI pass
    // below installs its own identity proj/view before drawing.
    self.held.draw(&GameTextures.inst.terrain, &self.player.camera);

    // UI pass: orthographic overlay drawn on top of the 3D scene.
    // clear_depth so HUD sprites aren't z-rejected by world geometry;
    // SpriteBatcher.flush() sets identity proj/view (orthographic NDC).
    // HUD pass split in three with a depth clear between each so draw order
    // is explicit: hotbar bg + crosshair, then iso block icons, then the
    // selector frame on top. This avoids relying on tiny layer differences
    // near PSP's +Z clip/depth edge.
    Rendering.gfx.api.clear_depth();
    self.ui_batcher.clear();
    self.iso_blocks.begin();
    self.player.draw_ui(&self.ui_batcher, &self.iso_blocks, &GameTextures.inst.gui);
    try self.ui_batcher.flush();

    Rendering.gfx.api.clear_depth();
    self.iso_blocks.flush();

    Rendering.gfx.api.clear_depth();
    self.ui_selector_batcher.clear();
    self.player.draw_ui_selector(&self.ui_selector_batcher, &GameTextures.inst.gui);
    try self.ui_selector_batcher.flush();
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
