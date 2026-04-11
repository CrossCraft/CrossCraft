const std = @import("std");
const ae = @import("aether");
const Core = ae.Core;
const Util = ae.Util;
const Rendering = ae.Rendering;
const State = Core.State;

const Server = @import("game").Server;
const World = @import("game").World;
const c = @import("common").consts;
const proto = @import("common").protocol;
const collision = @import("../player/collision.zig");
const FakeConn = @import("../connection/FakeConn.zig").FakeConn;
const ClientConn = @import("../connection/ClientConn.zig");
const Session = @import("Session.zig");
const Vertex = @import("../graphics/Vertex.zig").Vertex;
const TextureAtlas = @import("../graphics/TextureAtlas.zig").TextureAtlas;
const WorldRenderer = @import("../world/world.zig");
const SelectionOutline = @import("../world/SelectionOutline.zig");
const Player = @import("../player/Player.zig");
const BlockHand = @import("../player/BlockHand.zig");
const SpriteBatcher = @import("../ui/SpriteBatcher.zig");
const FontBatcher = @import("../ui/FontBatcher.zig");
const IsoBlockDrawer = @import("../ui/IsoBlockDrawer.zig");
const Inventory = @import("../ui/Inventory.zig");
const ui_input = @import("../ui/input.zig");
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
    font: Rendering.Texture,
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
        inst.gui = try load_from_pack(pack, "minecraft/textures/gui/gui");
        // Bitmap font texture used by the inventory tooltip. Same atlas the
        // load/menu states use.
        inst.font = try load_from_pack(pack, "minecraft/textures/default");
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
        inst.font.deinit();
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
// Background read-loop task for MP mode; owns the TCP read side of the
// live Stream and pumps packets through ClientConn's callbacks. Left
// running for the lifetime of the process -- on disconnect the loop
// exits and sets `Session.mp_connected` to false so the draw path can
// observe the drop.
mp_read_future: ?std.Io.Future(void),
pipeline: Rendering.Pipeline.Handle,
world: WorldRenderer,
player: Player,
ui_batcher: SpriteBatcher,
font_batcher: FontBatcher,
iso_blocks: IsoBlockDrawer,
inventory: Inventory,
selection: SelectionOutline,
held: BlockHand,

fn init(ctx: *anyopaque) anyerror!void {
    var self = Util.ctx_to_self(@This(), ctx);
    self.mp_read_future = null;

    // Connection setup: singleplayer uses FakeConn + an in-process server;
    // multiplayer wraps ClientConn around the live TCP stream that
    // LoadState opened, skipping the fake ring buffers entirely.
    switch (Session.mode) {
        .singleplayer => {
            self.fake_conn.init();

            _ = Server.local_join(
                &self.fake_conn.server_reader,
                &self.fake_conn.server_writer,
                &self.fake_conn.connected,
            ) orelse return error.ServerFull;

            self.conn.init(&self.fake_conn.client_reader, &self.fake_conn.client_writer);
            try self.conn.join(Session.username());

            Server.drain_local_packets();
            self.conn.drain_packets();
        },
        .multiplayer => {
            // LoadState.connectTask already sent PlayerIdentification and
            // consumed through LevelFinalize; the socket is positioned at
            // whatever the server sent next (typically SpawnPlayer).
            self.conn.init(&Session.mp_reader.interface, &Session.mp_writer.interface);

            // Mirror the server's per-client read-loop task: one Io async
            // task owns the blocking TCP reads and drives ClientConn's
            // packet callbacks, so the game thread never blocks on recv.
            // Callbacks mutate World/WorldRenderer directly, matching
            // how the server mutates its world from its read tasks.
            Session.mp_connected.store(true, .release);
            self.mp_read_future = Util.io().async(
                ClientConn.read_loop,
                .{ &self.conn, &Session.mp_connected },
            );
        },
    }

    // Redistribute memory for game state
    @import("../config.zig").apply_runtime_budgets();

    // Pipeline
    const vert align(@alignOf(u32)) = @embedFile("basic_vert").*;
    const frag align(@alignOf(u32)) = @embedFile("basic_frag").*;
    self.pipeline = try Rendering.Pipeline.new(Vertex.Layout, &vert, &frag);

    // Player -- owns the camera; spawn Y is eye-level from the server.
    // Use whichever writer the active connection drains position packets
    // into: the FakeConn ring for SP, or the live TCP stream for MP.
    const player_writer: *std.Io.Writer = switch (Session.mode) {
        .singleplayer => &self.fake_conn.client_writer,
        .multiplayer => &Session.mp_writer.interface,
    };
    if (self.conn.handshake_complete) {
        try self.player.init(
            @as(f32, @floatFromInt(self.conn.spawn_x)) / 32.0,
            @as(f32, @floatFromInt(self.conn.spawn_y)) / 32.0,
            @as(f32, @floatFromInt(self.conn.spawn_z)) / 32.0,
            player_writer,
        );
    } else {
        try self.player.init(128.0, 44.0, 128.0, player_writer);
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

    // UI sprite batcher for HUD overlay (crosshair, hotbar bg, selector).
    self.ui_batcher = try SpriteBatcher.init(self.pipeline);

    // Font batcher used by the inventory tooltip. The bitmap font texture
    // sits in GameTextures alongside the rest of the GUI assets.
    self.font_batcher = try FontBatcher.init(self.pipeline, &GameTextures.inst.font);

    // Iso-projected block icons for hotbar + inventory slots; draws to the
    // same terrain atlas as the world.
    self.iso_blocks = try IsoBlockDrawer.init(
        self.pipeline,
        &GameTextures.inst.terrain,
        GameTextures.inst.atlas,
    );

    // Inventory overlay (Classic block-picker). MenuState already calls
    // ensure_registered, but state init order is not load-bearing here, so
    // call it again -- it is idempotent and guarantees the ui_cursor /
    // ui_click / ui_confirm / ui_cancel actions exist for the overlay.
    try ui_input.ensure_registered();
    ui_input.set_profile(ui_input.default_profile());
    self.inventory = Inventory.init();

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
    self.font_batcher.deinit();
    self.ui_batcher.deinit();
    self.world.deinit();
    GameTextures.deinit();
    Rendering.Pipeline.deinit(self.pipeline);
    switch (Session.mode) {
        .singleplayer => self.fake_conn.connected = false,
        .multiplayer => {
            if (Session.mp_stream) |*s| {
                s.close(Util.io());
                Session.mp_stream = null;
            }
        },
    }
}

fn tick(ctx: *anyopaque) anyerror!void {
    var self = Util.ctx_to_self(@This(), ctx);
    // Only the in-process server ticks its own world; in MP, world state
    // updates arrive as SetBlockToClient packets and ClientConn applies
    // them from `draw` via drain_packets.
    if (Session.mode == .singleplayer) {
        Server.drain_local_packets();
        Server.tick();
    }
    GameTextures.tick_animations();
    send_player_position(&self.player);
}

/// Emit a PositionAndOrientationToServer using the player's current
/// feet position + camera. Runs every game tick in both SP and MP -- in
/// SP it feeds the local server via the FakeConn ring (harmless since
/// there's only one player), and in MP it's what keeps the remote
/// server's view of us in sync. Classic's wire format is u16 fixed-point
/// (world_unit * 32) for position and u8 Fixed8 (one turn = 256) for
/// yaw/pitch.
fn send_player_position(player: *Player) void {
    const tau = std.math.tau;
    const eye_y = player.pos_y + collision.EYE_HEIGHT;
    const x_fp: u16 = fp_coord(player.pos_x);
    const y_fp: u16 = fp_coord(eye_y);
    const z_fp: u16 = fp_coord(player.pos_z);

    // Our camera.yaw rotates counter-clockwise; Classic's u8 yaw rotates
    // clockwise. Negate to flip handedness; the zero point already lines
    // up with Classic's yaw=0.
    const yaw_classic = @mod(-player.camera.yaw, tau);
    const pitch_norm = @mod(player.camera.pitch, tau);
    const yaw_u8: u8 = @intFromFloat(@min(255.0, yaw_classic * (256.0 / tau)));
    const pitch_u8: u8 = @intFromFloat(@min(255.0, pitch_norm * (256.0 / tau)));

    proto.send_position_to_server(player.writer, -1, x_fp, y_fp, z_fp, yaw_u8, pitch_u8) catch |err| {
        log.err("send position: {}", .{err});
        return;
    };
    player.writer.flush() catch |err| {
        log.err("flush position: {}", .{err});
    };
}

fn fp_coord(v: f32) u16 {
    const scaled = v * 32.0;
    if (scaled < 0.0) return 0;
    if (scaled > 65535.0) return 65535;
    return @intFromFloat(scaled);
}

fn update(ctx: *anyopaque, dt: f32, budget: *const Util.BudgetContext) anyerror!void {
    var self = Util.ctx_to_self(@This(), ctx);

    // Drain the ui_input edges every frame so they never accumulate stale
    // values across an open/close transition. The snapshot is only consumed
    // by the inventory; when the overlay is closed it just gets discarded.
    const ui_in = ui_input.build_frame(dt, &self.inventory.ui_repeat);

    if (self.player.inventory_toggle_pending) {
        self.player.inventory_toggle_pending = false;
        if (self.inventory.open) {
            self.inventory.close_overlay(&self.player);
        } else {
            self.inventory.open_overlay(&self.player);
        }
    }

    if (self.inventory.open) self.inventory.update(&ui_in, &self.player);

    // Player physics keep ticking with the inventory open (matching Classic).
    // mouse_captured is false while open, so apply_look ignores deltas and
    // on_break/on_place early-return.
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
    // SP: packets arrive on the game thread via the FakeConn ring, so we
    // have to drain them here. MP: the background read-loop task owns the
    // TCP reader and pushes through ClientConn's callbacks on its own.
    if (Session.mode == .singleplayer) {
        self.conn.drain_packets();
    } else if (!Session.mp_connected.load(.acquire)) {
        // Read loop exited (EOF or error): treat as disconnect -> quit.
        ae.App.quit();
    }
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
    // Draw order is hotbar bg -> selector -> inventory panel -> iso block
    // icons -> tooltip text. The 2D sprites all batch into one pass; the
    // iso blocks flush after them so they sit on top of the selector frame
    // and the inventory panel. The font batcher flushes last for the
    // tooltip. A depth clear between each pass keeps z-tests clean.
    Rendering.gfx.api.clear_depth();
    self.ui_batcher.clear();
    self.font_batcher.clear();
    self.iso_blocks.begin();
    self.player.draw_ui(&self.ui_batcher, &self.iso_blocks, &GameTextures.inst.gui);
    if (self.inventory.open) {
        self.inventory.draw(&self.ui_batcher, &self.iso_blocks, &self.font_batcher);
    }
    try self.ui_batcher.flush();

    Rendering.gfx.api.clear_depth();
    self.iso_blocks.flush();

    Rendering.gfx.api.clear_depth();
    try self.font_batcher.flush();
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
