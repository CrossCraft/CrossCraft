const std = @import("std");
const ae = @import("aether");
const Core = ae.Core;
const Util = ae.Util;
const Engine = ae.Engine;
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
const DisconnectState = @import("DisconnectState.zig");

const ResourcePack = @import("../ResourcePack.zig");
const SoundManager = @import("../SoundManager.zig");
const Vertex = @import("../graphics/Vertex.zig").Vertex;
const WorldRenderer = @import("../world/world.zig");
const SelectionOutline = @import("../world/SelectionOutline.zig");
const Player = @import("../player/Player.zig");
const BlockHand = @import("../player/BlockHand.zig");
const SpriteBatcher = @import("../ui/SpriteBatcher.zig");
const FontBatcher = @import("../ui/FontBatcher.zig");
const IsoBlockDrawer = @import("../ui/IsoBlockDrawer.zig");
const Inventory = @import("../ui/Inventory.zig");
const PlayerList = @import("../ui/PlayerList.zig");
const Chat = @import("../ui/Chat.zig");
const BlockNames = @import("../ui/BlockNames.zig");
const Color = @import("../graphics/Color.zig").Color;
const ui_input = @import("../ui/input.zig");

const log = std.log.scoped(.game);

const selection_depth_nudge: f32 = 1.0 / 160.0;

fake_conn: FakeConn,
conn: ClientConn,
// MP read-loop task: owns the TCP read side, drives ClientConn
// callbacks, clears `Session.mp_connected` on exit.
mp_read_future: ?std.Io.Future(void),
pipeline: Rendering.Pipeline.Handle,
world: WorldRenderer,
player: Player,
ui_batcher: SpriteBatcher,
font_batcher: FontBatcher,
iso_blocks: IsoBlockDrawer,
inventory: Inventory,
player_list: PlayerList,
chat: Chat,
/// PSP only: true while the Select-toggled social overlay (player list +
/// chat cursor) is visible.  Cleared when Select is pressed again or the
/// OSK completes.
psp_social_mode: bool,
selection: SelectionOutline,
held: BlockHand,
render_alloc: std.mem.Allocator,
hotbar_tooltip_timer: f32,
prev_selected_slot: u8,
report_timer: f32,

fn init(ctx: *anyopaque, engine: *Engine) anyerror!void {
    var self = Util.ctx_to_self(@This(), ctx);
    self.mp_read_future = null;

    // SP uses FakeConn + in-process server; MP wraps ClientConn around the
    // live TCP stream that LoadState opened.
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
            const pspsdk = if (ae.platform == .psp) @import("pspsdk") else {};
            const PSP_MAIN_PRIO_RUNTIME: i32 = 64;
            const psp_main_thid = if (ae.platform == .psp)
                pspsdk.kernel.get_thread_id()
            else {};
            const psp_orig_prio: i32 = if (ae.platform == .psp)
                pspsdk.kernel.get_thread_current_priority()
            else
                0;
            if (ae.platform == .psp) {
                try pspsdk.kernel.change_thread_priority(psp_main_thid, psp_orig_prio - 10);
            }
            defer if (ae.platform == .psp) {
                pspsdk.kernel.change_thread_priority(psp_main_thid, PSP_MAIN_PRIO_RUNTIME) catch {};
            };

            // Handshake + LevelFinalize were already consumed in
            // LoadState.connectTask; the socket's now pointed at SpawnPlayer.
            self.conn.init(&Session.mp_reader.interface, &Session.mp_writer.interface);
            Session.mp_connected.store(true, .release);

            // Wire up player_list and chat BEFORE the read loop starts so
            // that SpawnPlayer packets for already-connected players (sent
            // by the server right after LevelFinalize) are not silently
            // dropped due to null pointers.
            self.player_list = PlayerList.init();
            self.conn.player_list = &self.player_list;
            self.chat = Chat.init();
            self.conn.chat = &self.chat;

            // Must be `concurrent`, not `async`: PSP's `async` falls back
            // to inline execution when it can't spawn a thread, which
            // would hang GameState.init inside an infinite read loop.
            self.mp_read_future = try engine.io.concurrent(
                ClientConn.read_loop,
                .{ &self.conn, &Session.mp_connected },
            );
        },
    }

    // Redistribute memory for game state
    @import("../config.zig").apply_runtime_budgets(engine);

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

    const render_alloc = engine.allocator(.render);
    self.render_alloc = render_alloc;

    // Textures
    try ResourcePack.apply_tex_set(&.{ .font, .gui, .terrain, .clouds, .water_still, .lava_still });

    // World renderer
    self.world = try WorldRenderer.init(
        render_alloc,
        engine.io,
        self.pipeline,
        ResourcePack.get_tex(.terrain),
        ResourcePack.get_tex(.clouds),
        ResourcePack.atlas,
        &self.player.camera,
    );

    // Let block-change packets find the renderer so they can mark sections.
    self.conn.world_renderer = &self.world;

    // Wire break particles now that both player and world exist.
    self.player.particle_sink = &self.world.particles;

    // UI sprite batcher for HUD overlay (crosshair, hotbar bg, selector).
    self.ui_batcher = try SpriteBatcher.init(render_alloc, self.pipeline);

    // Font batcher used by the inventory tooltip.
    self.font_batcher = try FontBatcher.init(render_alloc, self.pipeline, ResourcePack.get_tex(.font));

    // Iso-projected block icons for hotbar + inventory slots; draws to the
    // same terrain atlas as the world.
    self.iso_blocks = try IsoBlockDrawer.init(
        render_alloc,
        self.pipeline,
        ResourcePack.get_tex(.terrain),
        ResourcePack.atlas,
    );

    // Inventory overlay (Classic block-picker). MenuState already calls
    // ensure_registered, but state init order is not load-bearing here, so
    // call it again -- it is idempotent and guarantees the ui_cursor /
    // ui_click / ui_confirm / ui_cancel actions exist for the overlay.
    try ui_input.ensure_registered();
    ui_input.set_profile(ui_input.default_profile());
    self.inventory = Inventory.init();
    // Multiplayer already initialised player_list and chat before the
    // read-loop thread was spawned (to avoid losing initial spawn packets).
    if (Session.mode == .singleplayer) {
        self.player_list = PlayerList.init();
        self.conn.player_list = &self.player_list;
        self.chat = Chat.init();
        self.conn.chat = &self.chat;
    }
    self.psp_social_mode = false;
    self.hotbar_tooltip_timer = 0;
    self.prev_selected_slot = 0;
    self.report_timer = 0;

    // Block selection outline (line mesh, drawn after the world pass).
    self.selection = try SelectionOutline.init(render_alloc, self.pipeline);

    // Held-block viewmodel. Uses the same terrain atlas as the world.
    self.held = try BlockHand.init(render_alloc, self.pipeline, ResourcePack.atlas);
    self.player.held_renderer = &self.held;

    engine.report();
}

fn deinit(ctx: *anyopaque, engine: *Engine) void {
    var self = Util.ctx_to_self(@This(), ctx);
    // Stop the read-loop task before freeing any resources it may still
    // be accessing (world_renderer, conn.buffer, etc.).
    switch (Session.mode) {
        .singleplayer => self.fake_conn.connected = false,
        .multiplayer => {
            // Signal the loop to exit, then close the socket to unblock any
            // pending read, then await the task so we know it has returned.
            Session.mp_connected.store(false, .release);
            if (Session.mp_stream) |*s| {
                s.close(engine.io);
                Session.mp_stream = null;
            }
            if (self.mp_read_future) |*f| {
                f.await(engine.io);
                self.mp_read_future = null;
            }
        },
    }
    self.held.deinit();
    self.selection.deinit();
    self.iso_blocks.deinit();
    self.font_batcher.deinit();
    self.ui_batcher.deinit();
    self.world.deinit();
    Rendering.Pipeline.deinit(self.pipeline);
}

fn tick(ctx: *anyopaque, _: *Engine) anyerror!void {
    var self = Util.ctx_to_self(@This(), ctx);
    // MP updates arrive as packets; no local world tick.
    if (Session.mode == .singleplayer) {
        Server.drain_local_packets();
        Server.tick();
    }
    ResourcePack.tick_animations();
    send_player_position(&self.player);
}

/// Emit PositionAndOrientationToServer every tick. Classic's wire format
/// is u16 fixed-point (world*32) for position and u8 (turn/256) for
/// yaw/pitch.
fn send_player_position(player: *Player) void {
    const tau = std.math.tau;
    const eye_y = player.pos_y + collision.EYE_HEIGHT;
    const x_fp: u16 = fp_coord(player.pos_x);
    const y_fp: u16 = fp_coord(eye_y);
    const z_fp: u16 = fp_coord(player.pos_z);

    // camera.yaw rotates CCW; Classic's u8 yaw rotates CW. Negate to
    // flip handedness; the zero point already matches.
    const yaw_classic = @mod(-player.camera.yaw, tau);
    const pitch_norm = @mod(player.camera.pitch, tau);
    const yaw_u8: u8 = @intFromFloat(@min(255.0, yaw_classic * (256.0 / tau)));
    const pitch_u8: u8 = @intFromFloat(@min(255.0, pitch_norm * (256.0 / tau)));

    // Skip if the Writer is still holding data from a previous failed
    // flush (transient ENOBUFS on PSP). Retry the flush so pending
    // block/chat bytes get another chance; stale position history isn't
    // worth preserving. Real disconnects go through the read_loop.
    if (Session.mode == .multiplayer and Session.mp_writer.interface.end > 0) {
        player.writer.flush() catch {};
        return;
    }

    proto.send_position_to_server(player.writer, -1, x_fp, y_fp, z_fp, yaw_u8, pitch_u8) catch return;
    player.writer.flush() catch {};
}

fn fp_coord(v: f32) u16 {
    const scaled = v * 32.0;
    if (scaled < 0.0) return 0;
    if (scaled > 65535.0) return 65535;
    return @intFromFloat(scaled);
}

fn update(ctx: *anyopaque, engine: *Engine, dt: f32, budget: *const Util.BudgetContext) anyerror!void {
    var self = Util.ctx_to_self(@This(), ctx);

    // PSP: service a deferred chat OSK request now that the previous frame's
    // end_frame has completed and the GE is idle.
    if (ae.platform == .psp and self.chat.psp_osk_pending) {
        self.chat.psp_osk_pending = false;
        self.chat.service_psp_osk(&self.player);
        // OSK either sent or cancelled -- exit social mode either way.
        self.psp_social_mode = false;
    }

    // PSP: Select (playerlist_edge) toggles the social overlay -- player list
    // visible simultaneously with the chat input cursor.  Pressing Select a
    // second time exits without sending.  Cross (X / psp_osk_edge) arms the
    // OSK so it fires at the top of the next frame.
    if (ae.platform == .psp) {
        if (self.player.playerlist_edge) {
            self.player.playerlist_edge = false;
            if (self.psp_social_mode) {
                self.psp_social_mode = false;
                self.chat.psp_osk_pending = false;
                self.chat.close_overlay(&self.player);
            } else if (Session.mode == .multiplayer and !self.inventory.open) {
                self.psp_social_mode = true;
                self.chat.open_overlay_social(&self.player);
            }
        }
        if (self.player.psp_osk_edge) {
            self.player.psp_osk_edge = false;
            if (self.psp_social_mode) self.chat.psp_osk_pending = true;
        }
    }

    // Drain ui_input edges each frame. Use the active overlay's repeat state
    // so backspace autorepeat is owned by whichever overlay is open.
    const active_repeat = if (self.chat.open) &self.chat.ui_repeat else &self.inventory.ui_repeat;
    const ui_in = ui_input.build_frame(dt, active_repeat);

    if (self.player.inventory_toggle_pending) {
        self.player.inventory_toggle_pending = false;
        if (self.inventory.open) {
            self.inventory.close_overlay(&self.player);
        } else if (!self.chat.open) {
            self.inventory.open_overlay(&self.player);
        }
    }

    // Chat open/close.  Inventory and chat are mutually exclusive; neither
    // opens while the other is active.
    if (self.player.chat_open_pending) {
        self.player.chat_open_pending = false;
        if (!self.chat.open and !self.inventory.open) {
            self.chat.open_overlay(&self.player, false);
        }
    }
    if (self.player.chat_cmd_pending) {
        self.player.chat_cmd_pending = false;
        if (!self.chat.open and !self.inventory.open) {
            self.chat.open_overlay(&self.player, true);
        }
    }

    if (self.inventory.open) self.inventory.update(&ui_in, &self.player);

    // Chat update: pass the chat_send flag separately so Enter sends without
    // Space accidentally triggering a send (Space fires ui_confirm AND types
    // a space char; chat ignores confirm_edge and uses chat_send_pending).
    if (self.chat.open) {
        const send = self.player.chat_send_pending;
        self.player.chat_send_pending = false;
        self.chat.update(&ui_in, send, &self.player);
    } else {
        self.player.chat_send_pending = false;
    }

    self.chat.tick(dt);

    // Player physics keep ticking with the inventory open (matching Classic).
    // mouse_captured is false while open, so apply_look ignores deltas and
    // on_break/on_place early-return.
    self.player.update(dt);
    self.world.update(dt, budget, &self.player.camera);
    SoundManager.update(
        dt,
        self.player.camera.x,
        self.player.camera.y,
        self.player.camera.z,
        self.player.camera.yaw,
        self.player.camera.pitch,
    );
    const slot_block = self.player.hotbar[self.player.selected_slot];
    self.held.update(dt, slot_block, player_in_shadow(&self.player));

    self.report_timer += dt;
    if (self.report_timer >= 10.0) {
        self.report_timer -= 10.0;
        engine.report();
    }

    // Hotbar tooltip: reset timer on slot change, tick down otherwise.
    if (self.player.selected_slot != self.prev_selected_slot) {
        self.prev_selected_slot = self.player.selected_slot;
        self.hotbar_tooltip_timer = 2.0;
    } else if (self.hotbar_tooltip_timer > 0) {
        self.hotbar_tooltip_timer -= dt;
        if (self.hotbar_tooltip_timer < 0) self.hotbar_tooltip_timer = 0;
    }
}

/// True when the voxel containing the player's eye is not directly sunlit.
/// Used to tint the held-block viewmodel to match the surrounding lighting,
/// matching the per-face shading the chunk mesher applies to world geometry.
/// Out-of-world positions (e.g. the brief above-ceiling case during a
/// teleport) read as lit so the held block never goes dark unexpectedly.
fn player_in_shadow(player: *const Player) bool {
    const eye_y = player.pos_y + collision.EYE_HEIGHT;
    const fx = @floor(player.pos_x);
    const fy = @floor(eye_y);
    const fz = @floor(player.pos_z);
    if (fx < 0.0 or fx >= @as(f32, @floatFromInt(c.WorldLength))) return false;
    if (fy < 0.0 or fy >= @as(f32, @floatFromInt(c.WorldHeight))) return false;
    if (fz < 0.0 or fz >= @as(f32, @floatFromInt(c.WorldDepth))) return false;
    const bx_i: i32 = @intFromFloat(fx);
    const by_i: i32 = @intFromFloat(fy);
    const bz_i: i32 = @intFromFloat(fz);
    return !World.is_sunlit(@intCast(bx_i), @intCast(by_i), @intCast(bz_i));
}

fn draw(ctx: *anyopaque, engine: *Engine, _: f32, _: *const Util.BudgetContext) anyerror!void {
    var self = Util.ctx_to_self(@This(), ctx);
    // SP drains packets on the game thread; MP has the bg read-loop
    // task doing it and just checks the connection flag here.
    if (Session.mode == .singleplayer) {
        self.conn.drain_packets();
    } else if (!Session.mp_connected.load(.acquire)) {
        try DisconnectState.transition_here(engine);
        return;
    }
    if (self.conn.quit_requested) {
        try DisconnectState.transition_here(engine);
        return;
    }
    self.player.camera.apply();
    self.world.draw(&self.player.camera);

    // Selection outline: still in the 3D pass, depth-tested against the world.
    // Nudge it slightly toward the camera so it does not z-fight the selected
    // block face, without making it show through other geometry.
    // The outline shape matches the block's subvoxel bounds (e.g. half-height
    // for slabs, small box for flowers/mushrooms).
    if (self.player.selected) |hit| {
        Rendering.Texture.Default.bind();
        var t = Rendering.Transform.new();
        const cp = @cos(self.player.camera.pitch);
        const toward_camera = .{
            .x = @sin(self.player.camera.yaw) * cp,
            .y = @sin(self.player.camera.pitch),
            .z = @cos(self.player.camera.yaw) * cp,
        };
        const bounds = c.block_bounds(World.get_block(hit.x, hit.y, hit.z));
        const Q: f32 = 0.0625;
        t.pos = .{
            .x = @as(f32, @floatFromInt(hit.x)) + @as(f32, @floatFromInt(bounds.min_x)) * Q + toward_camera.x * selection_depth_nudge,
            .y = @as(f32, @floatFromInt(hit.y)) + @as(f32, @floatFromInt(bounds.min_y)) * Q + toward_camera.y * selection_depth_nudge,
            .z = @as(f32, @floatFromInt(hit.z)) + @as(f32, @floatFromInt(bounds.min_z)) * Q + toward_camera.z * selection_depth_nudge,
        };
        // Vertices live in SNORM16 block-units (1 block = 2048 / 32768);
        // (max - min) * 1.0 gives the correct world-unit scale per axis.
        t.scale = .{
            .x = @as(f32, @floatFromInt(bounds.max_x - bounds.min_x)),
            .y = @as(f32, @floatFromInt(bounds.max_y - bounds.min_y)),
            .z = @as(f32, @floatFromInt(bounds.max_z - bounds.min_z)),
        };
        self.selection.draw(&t);
    }

    // Held-block viewmodel: swaps in its own projection + identity view,
    // clears depth internally so it never z-fights against nearby world
    // geometry. Matrices are left in that state on exit; the UI pass
    // below installs its own identity proj/view before drawing.
    self.held.draw(ResourcePack.get_tex(.terrain), &self.player.camera);

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
    self.player.draw_ui(&self.ui_batcher, &self.iso_blocks, ResourcePack.get_tex(.gui), self.inventory.open);
    if (self.inventory.open) {
        self.inventory.draw(&self.ui_batcher, &self.iso_blocks, &self.font_batcher);
    }
    // Desktop: hold Tab to show player list (hidden while inventory or chat open).
    // PSP: show during social mode, which coexists with the chat input field.
    const show_playerlist = if (ae.platform == .psp)
        self.psp_social_mode
    else
        self.player.playerlist_held and Session.mode == .multiplayer and !self.inventory.open and !self.chat.open;
    if (show_playerlist) {
        self.player_list.draw(&self.ui_batcher, &self.font_batcher, Session.username());
    }
    self.chat.draw(&self.ui_batcher, &self.font_batcher);

    // Hotbar tooltip: block name above the hotbar, fades out over the last 0.5s.
    if (self.hotbar_tooltip_timer > 0 and !self.inventory.open) {
        const block = self.player.hotbar[self.player.selected_slot];
        const name = BlockNames.get(block);
        if (name.len > 0) {
            const alpha: u8 = if (self.hotbar_tooltip_timer >= 0.5)
                255
            else
                @intFromFloat(self.hotbar_tooltip_timer / 0.5 * 255.0);
            const shadow_alpha: u8 = if (self.hotbar_tooltip_timer >= 0.5)
                255
            else
                @intFromFloat(self.hotbar_tooltip_timer / 0.5 * 255.0);
            self.font_batcher.add_text(&.{
                .str = name,
                .pos_x = 0,
                .pos_y = -26,
                .color = Color.rgba(255, 255, 255, alpha),
                .shadow_color = Color.rgba(50, 50, 50, shadow_alpha),
                .spacing = 0,
                .layer = 252,
                .reference = .bottom_center,
                .origin = .bottom_center,
            });
        }
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
