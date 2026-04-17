const std = @import("std");
const ae = @import("aether");
const Core = ae.Core;
const Util = ae.Util;
const Engine = ae.Engine;
const Rendering = ae.Rendering;
const State = Core.State;

const game = @import("game");
const Server = game.Server;
const World = game.World;
const c = @import("common").consts;
const proto = @import("common").protocol;
const collision = @import("../player/collision.zig");
const FakeConn = @import("../connection/FakeConn.zig").FakeConn;
const ClientConn = @import("../connection/ClientConn.zig");
const Session = @import("Session.zig");
const DisconnectState = @import("DisconnectState.zig");
const MenuState = @import("MenuState.zig");
const Options = @import("../Options.zig");

const ResourcePack = @import("../ResourcePack.zig");
const SoundManager = @import("../SoundManager.zig");
const Vertex = @import("../graphics/Vertex.zig").Vertex;
const WorldRenderer = @import("../world/world.zig");
const SelectionOutline = @import("../world/SelectionOutline.zig");
const SteveModel = @import("../world/SteveModel.zig");
const Player = @import("../player/Player.zig");
const BlockHand = @import("../player/BlockHand.zig");
const SpriteBatcher = @import("../ui/SpriteBatcher.zig");
const FontBatcher = @import("../ui/FontBatcher.zig");
const IsoBlockDrawer = @import("../ui/IsoBlockDrawer.zig");
const Inventory = @import("../ui/Inventory.zig");
const PlayerList = @import("../ui/PlayerList.zig");
const Chat = @import("../ui/Chat.zig");
const BlockNames = @import("../ui/BlockNames.zig");
const ControllerGlyphs = @import("../ui/ControllerGlyphs.zig");
const Color = @import("../graphics/Color.zig").Color;
const ui_input = @import("../ui/input.zig");
const PauseMenuScreen = @import("../ui/PauseMenuScreen.zig");
const OptionsMenuScreen = @import("../ui/OptionsMenuScreen.zig");
const Screen = @import("../ui/Screen.zig");
const ae_input = ae.Core.input;

/// Set by the Aether lost-focus callback (which can fire from the GLFW
/// poll thread). Module-static so it survives across GameState transitions
/// and never points at freed memory.
var pause_focus_request: bool = false;
/// Stable singleton sink for the lost-focus callback; pointer is required
/// non-null but the value is unused. Avoids handing Aether a pointer to the
/// GameState struct (which gets deinit'd on transition).
var lost_focus_sink: u8 = 0;

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
steve: SteveModel,
held: BlockHand,
render_alloc: std.mem.Allocator,
hotbar_tooltip_timer: f32,
prev_selected_slot: u8,
report_timer: f32,
paused: bool,
pause_screen: Screen,
pause_ctx: PauseMenuScreen.Context,
/// True while the options screen (opened from pause) is visible.  When set,
/// pause_screen holds the OptionsMenuScreen instead of PauseMenuScreen.
in_options: bool,
options_ctx: OptionsMenuScreen.Context,
pause_ui_repeat: ui_input.Repeat,
pause_saved_mouse_captured: bool,
pause_batcher: SpriteBatcher,
pause_font_batcher: FontBatcher,
/// True once `init` has run to completion. Guards `deinit` so a partially
/// initialised state -- e.g. `init` errored on OOM after enough world reload
/// cycles -- does not crash on undefined sub-allocations.
inited: bool,

fn init(ctx: *anyopaque, engine: *Engine) anyerror!void {
    var self = Util.ctx_to_self(@This(), ctx);
    self.inited = false;
    self.mp_read_future = null;

    // Wipe any leftover input actions from the previous state (MenuState
    // registered ui_*; a previous GameState may have registered movement /
    // hotbar / etc.). Aether's input state is module-static and persists
    // across transitions; without this, `Player.init`'s `bindings.init`
    // would hit ActionAlreadyExists on a second session and abort init
    // mid-way.
    ae_input.clear();
    ui_input.invalidate_registration();

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
    // Apply persisted look settings; Player.init sets hardcoded defaults so
    // we override immediately after to pick up the options values.
    ae_input.mouse_sensitivity = Options.current.sensitivity;
    self.player.camera.fov = Options.current.fov * std.math.pi / 180.0;

    const render_alloc = engine.allocator(.render);
    self.render_alloc = render_alloc;

    // Textures
    try ResourcePack.apply_tex_set(&.{ .font, .gui, .terrain, .clouds, .water_still, .lava_still, .char, .glyphs });

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

    // Pause menu: built lazily-by-config. The lost-focus callback is a no-op
    // on PSP (Aether never fires it there). Pause uses dedicated batchers so
    // its dim quad and panel sprites/text flush after every gameplay UI pass
    // (HUD sprites, iso blocks, HUD font) and cleanly sit on top of all of
    // them without depending on layer ordering across separate render passes.
    self.pause_batcher = try SpriteBatcher.init(render_alloc, self.pipeline);
    self.pause_font_batcher = try FontBatcher.init(render_alloc, self.pipeline, ResourcePack.get_tex(.font));
    self.paused = false;
    self.pause_ctx = .{};
    self.in_options = false;
    self.options_ctx = .{ .dirt = null };
    self.pause_ui_repeat = .{};
    self.pause_saved_mouse_captured = true;
    self.pause_screen = PauseMenuScreen.build(&self.pause_ctx, Session.mode == .singleplayer);
    PauseMenuScreen.pending_resume = false;
    PauseMenuScreen.pending_quit = false;
    PauseMenuScreen.pending_save = false;
    PauseMenuScreen.pending_options = false;
    OptionsMenuScreen.pending_done = false;
    pause_focus_request = false;
    ae_input.set_lost_focus_callback(&lost_focus_sink, on_lost_focus);

    // Block selection outline (line mesh, drawn after the world pass).
    self.selection = try SelectionOutline.init(render_alloc, self.pipeline);

    // Remote player Steve model renderer.
    self.steve = try SteveModel.init(render_alloc, self.pipeline);

    // Held-block viewmodel. Uses the same terrain atlas as the world.
    self.held = try BlockHand.init(render_alloc, self.pipeline, ResourcePack.atlas);
    self.player.held_renderer = &self.held;

    self.inited = true;
    engine.report();
}

fn deinit(ctx: *anyopaque, engine: *Engine) void {
    var self = Util.ctx_to_self(@This(), ctx);
    if (!self.inited) return;
    // Drop the lost-focus callback so it cannot fire into the next state.
    ae_input.set_lost_focus_callback(&lost_focus_sink, noop_lost_focus);
    pause_focus_request = false;
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
            // PSP: tear down the networking stack so the next connect cycle
            // re-runs net dialog + net.init from a clean state. Skipping this
            // leaves sceNet/Apctl/Resolver loaded and the second connect fails.
            if (ae.platform == .psp) {
                const pspsdk = @import("pspsdk");
                pspsdk.extra.net.disconnect();
                pspsdk.extra.net.deinit();
            }
        },
    }
    self.held.deinit();
    self.steve.deinit();
    self.selection.deinit();
    self.iso_blocks.deinit();
    self.pause_font_batcher.deinit();
    self.pause_batcher.deinit();
    self.font_batcher.deinit();
    self.ui_batcher.deinit();
    self.world.deinit();
    Rendering.Pipeline.deinit(self.pipeline);

    // Tear down the game-side world/server allocations. SP went through
    // Server.init (which sets up the static allocator + compressor and owns
    // World), so Server.deinit unwinds the whole stack. MP only ran
    // World.init_empty, so only World.deinit is needed (Server.deinit would
    // try to free a compressor that was never initialised).
    switch (Session.mode) {
        .singleplayer => Server.deinit(),
        .multiplayer => World.deinit(),
    }
    self.inited = false;
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

fn on_lost_focus(_: *anyopaque) void {
    // Runs on the platform poll thread (or callback context); defer the
    // actual menu open to the next update tick on the game thread.
    pause_focus_request = true;
}

fn noop_lost_focus(_: *anyopaque) void {}

fn open_pause(self: *@This()) void {
    if (self.paused) return;
    self.paused = true;
    self.in_options = false;
    self.pause_saved_mouse_captured = self.player.mouse_captured;
    self.player.mouse_captured = false;
    ae_input.set_mouse_relative_mode(false);
    self.pause_ui_repeat = .{};
    PauseMenuScreen.pending_resume = false;
    PauseMenuScreen.pending_quit = false;
    PauseMenuScreen.pending_save = false;
    PauseMenuScreen.pending_options = false;
    OptionsMenuScreen.pending_done = false;
    self.pause_screen = PauseMenuScreen.build(&self.pause_ctx, Session.mode == .singleplayer);
    self.pause_screen.open(!ui_input.profile_uses_pointer());
}

fn close_pause(self: *@This()) void {
    if (!self.paused) return;
    self.paused = false;
    self.in_options = false;
    self.player.mouse_captured = self.pause_saved_mouse_captured;
    ae_input.set_mouse_relative_mode(self.pause_saved_mouse_captured);
    // Discard the spurious cursor delta produced by the relative-mode swap.
    self.player.look_delta = .{ 0, 0 };
    PauseMenuScreen.pending_resume = false;
    PauseMenuScreen.pending_quit = false;
    PauseMenuScreen.pending_save = false;
    PauseMenuScreen.pending_options = false;
    OptionsMenuScreen.pending_done = false;
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
    const active_repeat = if (self.paused)
        &self.pause_ui_repeat
    else if (self.chat.open)
        &self.chat.ui_repeat
    else
        &self.inventory.ui_repeat;
    const ui_in = ui_input.build_frame(dt, active_repeat);

    // Pause menu open/close. Focus loss only auto-pauses when nothing else is
    // already grabbing input -- otherwise the chat or inventory overlay would
    // sit awkwardly behind the pause panel.
    const can_open_pause = !self.paused and !self.chat.open and !self.inventory.open;
    var just_opened_pause = false;
    if (pause_focus_request) {
        pause_focus_request = false;
        if (can_open_pause) {
            open_pause(self);
            just_opened_pause = true;
        }
    }
    if (ui_in.pause_edge and can_open_pause) {
        open_pause(self);
        just_opened_pause = true;
    }
    if (self.paused) {
        // Skip screen.update on the open frame so the same Escape press that
        // opened the menu (which also raises cancel_edge) does not immediately
        // close it.
        if (!just_opened_pause) self.pause_screen.update(&ui_in);

        if (self.in_options) {
            // Options screen is active: Done or Escape returns to pause menu.
            if (OptionsMenuScreen.pending_done or self.pause_screen.cancel_pressed) {
                OptionsMenuScreen.pending_done = false;
                Options.save(engine.io, engine.dirs.data);
                // Re-apply settings that are cached at init time.
                ae_input.mouse_sensitivity = Options.current.sensitivity;
                self.player.camera.fov = Options.current.fov * std.math.pi / 180.0;
                engine.vsync = Options.current.vsync;
                self.in_options = false;
                self.pause_screen = PauseMenuScreen.build(&self.pause_ctx, Session.mode == .singleplayer);
                self.pause_screen.open(!ui_input.profile_uses_pointer());
            }
        } else {
            // Pause menu is active: dispatch its pending signals.
            if (PauseMenuScreen.pending_options) {
                PauseMenuScreen.pending_options = false;
                self.in_options = true;
                self.pause_screen = OptionsMenuScreen.build(&self.options_ctx);
                self.pause_screen.open(!ui_input.profile_uses_pointer());
            }
            if (PauseMenuScreen.pending_save) {
                PauseMenuScreen.pending_save = false;
                // World.save no-ops in MP (owned_locally is false there); the
                // pause menu also disables the button in MP, so this is a
                // belt-and-braces guard.
                World.save() catch |err| {
                    log.err("Save level failed: {}", .{err});
                };
            }
            if (PauseMenuScreen.pending_quit) {
                // SP saves automatically inside Server.deinit -> World.deinit;
                // do not duplicate the ~4 MB write here. MP's "Disconnect" path
                // never saves (owned_locally is false).
                // Quitting straight to the main menu: release the cursor instead
                // of restoring the saved gameplay capture, otherwise MenuState
                // inherits a captured-but-invisible cursor.
                self.paused = false;
                self.in_options = false;
                self.player.mouse_captured = false;
                ae_input.set_mouse_relative_mode(false);
                self.player.look_delta = .{ 0, 0 };
                PauseMenuScreen.pending_resume = false;
                PauseMenuScreen.pending_quit = false;
                PauseMenuScreen.pending_save = false;
                PauseMenuScreen.pending_options = false;
                OptionsMenuScreen.pending_done = false;
                try MenuState.transition_here(engine);
                return;
            }
            if (!just_opened_pause and (PauseMenuScreen.pending_resume or self.pause_screen.cancel_pressed)) {
                close_pause(self);
            }
        }
        // While paused, drop other pending input edges so they do not fire on
        // resume. Remote-player smoothing, world meshing, sound, and the
        // periodic report keep ticking in the shared tail below.
        self.player.inventory_toggle_pending = false;
        self.player.chat_open_pending = false;
        self.player.chat_cmd_pending = false;
        self.player.chat_send_pending = false;
    } else {
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

        // Chat update: pass the chat_send flag separately so Enter sends
        // without Space accidentally triggering a send (Space fires
        // ui_confirm AND types a space char; chat ignores confirm_edge and
        // uses chat_send_pending).
        if (self.chat.open) {
            const send = self.player.chat_send_pending;
            self.player.chat_send_pending = false;
            self.chat.update(&ui_in, send, &self.player);
        } else {
            self.player.chat_send_pending = false;
        }

        self.chat.tick(dt);

        // Player physics keep ticking with the inventory open (matching
        // Classic). mouse_captured is false while open, so apply_look
        // ignores deltas and on_break/on_place early-return.
        self.player.update(dt);
    }

    self.steve.update(dt, &self.player_list, &self.font_batcher);
    self.world.update(dt, budget, &self.player.camera);
    SoundManager.update(
        dt,
        self.player.camera.x,
        self.player.camera.y,
        self.player.camera.z,
        self.player.camera.yaw,
        self.player.camera.pitch,
    );

    self.report_timer += dt;
    if (self.report_timer >= 10.0) {
        self.report_timer -= 10.0;
        engine.report();
    }

    if (self.paused) return;

    const slot_block = self.player.hotbar[self.player.selected_slot];
    self.held.update(dt, slot_block, player_in_shadow(&self.player));

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
    self.world.draw_world_pass(&self.player.camera);

    // Remote player models: drawn in the 3D pass, depth-tested against the world.
    // Slotted before the fluid pass so water/lava correctly occludes them.
    self.steve.draw(&self.player);
    self.steve.draw_nametags(&self.player, &self.font_batcher);

    // Selection outline: still in the 3D pass, depth-tested against the world.
    // Nudge it slightly toward the camera so it does not z-fight the selected
    // block face, without making it show through other geometry.
    // The outline shape matches the block's subvoxel bounds (e.g. half-height
    // for slabs, small box for flowers/mushrooms).
    if (self.player.selected) |hit| blk: {
        const block_id = World.get_block(hit.x, hit.y, hit.z);
        if (block_id == c.Block.Air) break :blk;
        Rendering.Texture.Default.bind();
        var t = Rendering.Transform.new();
        const cp = @cos(self.player.camera.pitch);
        const toward_camera = .{
            .x = @sin(self.player.camera.yaw) * cp,
            .y = @sin(self.player.camera.pitch),
            .z = @cos(self.player.camera.yaw) * cp,
        };
        const bounds = c.block_bounds(block_id);
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

    // Fluid pass last so water/lava alpha-blends over the outline, steve
    // models, and particles drawn just above instead of the depth-writeless
    // fluid letting those overlays bleed through.
    self.world.draw_fluid_pass();

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

    // Controller-tooltip strip only applies to the in-world HUD.  Hidden
    // (and the hotbar returns to its base position) whenever another
    // overlay owns the bottom row: inventory or pause menu.  The chat
    // overlay coexists with the strip -- chat rides up by hud_y_shift.
    const show_glyphs = ControllerGlyphs.enabled() and
        !self.inventory.open and
        !self.paused;
    const hud_y_shift: i16 = if (show_glyphs) ControllerGlyphs.strip_height() else 0;

    self.player.draw_ui(&self.ui_batcher, &self.iso_blocks, ResourcePack.get_tex(.gui), self.inventory.open, hud_y_shift);
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
    self.chat.draw(&self.ui_batcher, &self.font_batcher, hud_y_shift);

    // Hotbar tooltip: block name above the hotbar, fades out over the last 0.5s.
    // Rides the hotbar up when the controller-tooltip strip is visible.
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
                .pos_y = -26 - hud_y_shift,
                .color = Color.rgba(255, 255, 255, alpha),
                .shadow_color = Color.rgba(50, 50, 50, shadow_alpha),
                .spacing = 0,
                .layer = 252,
                .reference = .bottom_center,
                .origin = .bottom_center,
            });
        }
    }

    if (show_glyphs) {
        self.draw_controller_tooltips();
    }

    try self.ui_batcher.flush();

    Rendering.gfx.api.clear_depth();
    self.iso_blocks.flush();

    Rendering.gfx.api.clear_depth();
    try self.font_batcher.flush();

    // Pause overlay uses its own batchers so it flushes cleanly after every
    // gameplay UI pass without depending on cross-batcher layer ordering.
    if (self.paused) {
        self.pause_batcher.clear();
        self.pause_font_batcher.clear();
        self.pause_screen.draw(&self.pause_batcher, &self.pause_font_batcher, ResourcePack.get_tex(.gui));

        // Options labels are mutable buffers updated in-place: the FontBatcher
        // diff sees no change across frames.  Force a rebuild while the options
        // screen is open so button text updates are visible immediately.
        if (self.in_options) {
            self.pause_font_batcher.mark_dirty();
        }

        Rendering.gfx.api.clear_depth();
        try self.pause_batcher.flush();

        Rendering.gfx.api.clear_depth();
        try self.pause_font_batcher.flush();
    }
}

/// Render the bottom-left controller-prompt strip.
///
/// Layout: origin at (20, 23) from the bottom-left.  Each entry is a
/// glyph followed by its label, all vertically centered on the glyph.
/// Entries: Inventory (always), Place (if an aimable block is
/// selected), Break (if any non-air block is selected).  PSP renders
/// the L+R chord for Inventory as two shoulder glyphs side-by-side.
fn draw_controller_tooltips(self: *@This()) void {
    const strip_x0: i16 = 20;
    const strip_y: i16 = 3; // bottom edge of glyphs, from screen bottom
    const glyph_pad: i16 = 4; // gap between glyph and its label
    const entry_pad: i16 = 12; // gap between one entry's label and the next glyph
    const chord_pad: i16 = 2; // gap between the two PSP inventory glyphs
    const text_layer: u8 = 252;
    const sprite_layer: u8 = 252;

    const glyphs_tex = ResourcePack.get_tex(.glyphs);

    var cursor_x: i16 = strip_x0;

    // Inventory (always).
    cursor_x = self.draw_glyph_entry(
        glyphs_tex,
        .inventory,
        cursor_x,
        strip_y,
        glyph_pad,
        chord_pad,
        sprite_layer,
        text_layer,
    );

    // Place / Break only when something is aimed at.
    if (self.player.selected) |hit| {
        const block_id = World.get_block(hit.x, hit.y, hit.z);
        if (block_id != c.Block.Air) {
            if (hit.has_place) {
                cursor_x += entry_pad;
                cursor_x = self.draw_glyph_entry(
                    glyphs_tex,
                    .place,
                    cursor_x,
                    strip_y,
                    glyph_pad,
                    chord_pad,
                    sprite_layer,
                    text_layer,
                );
            }
            cursor_x += entry_pad;
            _ = self.draw_glyph_entry(
                glyphs_tex,
                .break_,
                cursor_x,
                strip_y,
                glyph_pad,
                chord_pad,
                sprite_layer,
                text_layer,
            );
        }
    }
}

/// Draws one glyph (or two side-by-side for the PSP inventory chord)
/// plus its label, anchored bottom-left.  Returns the x just past the
/// label so the caller can chain the next entry.
fn draw_glyph_entry(
    self: *@This(),
    glyphs_tex: *const Rendering.Texture,
    which: ControllerGlyphs.Glyph,
    x0: i16,
    y: i16,
    glyph_pad: i16,
    chord_pad: i16,
    sprite_layer: u8,
    text_layer: u8,
) i16 {
    var x = x0;
    const count = if (which == .inventory) ControllerGlyphs.inventory_glyph_count() else 1;
    // Per-style baseline nudge so keyboard art can drop a pixel without
    // changing the desktop-gamepad/PSP alignment.  Positive = down, which
    // means subtracting from the bottom-anchored logical y.
    const glyph_y = y - ControllerGlyphs.glyph_y_offset();
    var last_rect: ControllerGlyphs.Rect = undefined;
    var i: u8 = 0;
    while (i < count) : (i += 1) {
        const rect = ControllerGlyphs.lookup(which, i);
        last_rect = rect;
        self.ui_batcher.add_sprite(&.{
            .texture = glyphs_tex,
            .pos_offset = .{ .x = x, .y = -glyph_y },
            .pos_extent = .{ .x = rect.render_w, .y = rect.render_h },
            .tex_offset = .{ .x = rect.tex_x, .y = rect.tex_y },
            .tex_extent = .{ .x = rect.tex_w, .y = rect.tex_h },
            .color = .white_fg,
            .layer = sprite_layer,
            .reference = .bottom_left,
            .origin = .bottom_left,
        });
        // KB+M inventory uses the Blank Key art with a letter rastered on
        // top of it; other glyphs are self-describing.  The letter drops
        // one extra logical pixel below the key center -- the font's cap
        // line sits above its bounding-box center, so pure geometric
        // centering reads as floating above the key face.
        if (ControllerGlyphs.letter_overlay(which)) |overlay| {
            self.font_batcher.add_text(&.{
                .str = overlay,
                // Glyph center = (x + render_w/2, glyph_y + render_h/2) from bottom-left.
                .pos_x = x + @divTrunc(rect.render_w, 2),
                .pos_y = -(glyph_y + @divTrunc(rect.render_h, 2) - 1),
                .color = .white_fg,
                .shadow_color = .menu_gray,
                .spacing = 0,
                .layer = text_layer,
                .reference = .bottom_left,
                .origin = .middle_center,
            });
        }
        x += rect.render_w;
        if (i + 1 < count) x += chord_pad;
    }

    // Label, vertically centered on the glyph.  Nudged 1 logical px below
    // the true glyph center so the text baseline sits visually aligned with
    // the bottom half of the glyph instead of floating above it.
    const label = ControllerGlyphs.label(which);
    const label_y_center: i16 = y + @divTrunc(last_rect.render_h, 2) - 1;
    x += glyph_pad;
    self.font_batcher.add_text(&.{
        .str = label,
        .pos_x = x,
        .pos_y = -label_y_center,
        .color = .white_fg,
        .shadow_color = .menu_gray,
        .spacing = 0,
        .layer = text_layer,
        .reference = .bottom_left,
        .origin = .middle_left,
    });
    return x + self.font_batcher.string_width(label, 0, 1);
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
