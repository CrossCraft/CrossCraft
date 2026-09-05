const std = @import("std");
const assert = std.debug.assert;
const ae = @import("aether");
const Core = ae.Core;
const Util = ae.Util;
const Engine = ae.Engine;
const Rendering = ae.Rendering;
const State = Core.State;

const core = @import("core");
const Server = core.Server;
const World = core.World;
const CompressWorker = core.CompressWorker;
const CompressorThread = @import("CompressorThread.zig");
const proto = core.protocol;
const collision = @import("../player/collision.zig");
const FakeConn = @import("../connection/FakeConn.zig").FakeConn;
const ClientConn = @import("../connection/ClientConn.zig");
const Session = @import("Session.zig");
const DisconnectState = @import("DisconnectState.zig");
const MenuState = @import("MenuState.zig");
const Options = @import("../Options.zig");

const ResourcePack = @import("../ResourcePack.zig");
const SoundManager = @import("../SoundManager.zig");
const WorldRenderer = @import("../world/world.zig");
const SelectionOutline = @import("../world/SelectionOutline.zig");
const SteveModel = @import("../world/SteveModel.zig");
const Player = @import("../player/Player.zig");
const BlockHand = @import("../player/BlockHand.zig");
const SpriteBatcher = ae.Ui.SpriteBatcher;
const FontBatcher = ae.Ui.FontBatcher;
const IsoBlockDrawer = @import("../ui/IsoBlockDrawer.zig");
const blocks = core.blocks;
const PlayerList = @import("../ui/PlayerList.zig");
const Chat = @import("../ui/Chat.zig");
const Buttons = @import("../ui/Buttons.zig");
const PromptStrip = @import("../ui/PromptStrip.zig");
const Prompts = @import("../ui/Prompts.zig");
const Ui = @import("../ui/Ui.zig");
const UiState = @import("../ui/UiState.zig");
const UiDrawList = @import("../ui/UiDrawList.zig");
const Screen = @import("../ui/Screen.zig");
const Colors = @import("../graphics/Color.zig");
const Color = Colors.Color;
const ui_input = @import("../ui/input.zig");
const InventoryUi = @import("../ui/screens/Inventory.zig");
const PauseMenu = @import("../ui/screens/PauseMenu.zig");
const OptionsScreen = @import("../ui/screens/Options.zig");
const ControlsScreen = @import("../ui/screens/Controls.zig");
const DumpWorldScreen = @import("../ui/screens/DumpWorld.zig");
const bindings = @import("../player/bindings.zig");
const ae_input = ae.Core.input;

const log = std.log.scoped(.game);

const caps = @import("capabilities").ClientType(ae);
const execution = @import("capabilities").execution;

const selection_depth_nudge: f32 = 1.0 / 320.0;
const MpReadStackSize = 512 * 1024;
const MpFlyWarning = "&cUsing fly in multiplayer may get you banned! Know what you're doing! Triple tap to enable.";
const PauseScreen = enum { main, options, controls, dump_world };

fake_conn: FakeConn,
conn: ClientConn,
// Owns the multiplayer TCP read side and clears mp_connected on exit.
mp_read_thread: ?Util.Thread,
compressor_thread: ?Util.Thread,
world: WorldRenderer,
player: Player,
ui_batcher: SpriteBatcher,
font_batcher: FontBatcher,
iso_blocks: IsoBlockDrawer,
inventory_open: bool,
inventory_slot: u8,
inventory_ui_state: UiState,
inventory_repeat: ui_input.Repeat,
inventory_blocks: [core.blocks.InventorySlots]core.blocks.Block,
player_list: PlayerList,
chat: Chat,
social_mode: bool,
mp_fly_unlocked: bool,
selection: SelectionOutline,
steve: SteveModel,
held: BlockHand,
render_alloc: std.mem.Allocator,
hotbar_tooltip_timer: f32,
prev_selected_slot: u8,
report_timer: f32,
hud_hidden: bool,
paused: bool,
pause_screen: PauseScreen,
pause_ui_state: UiState,
pause_options_ui_state: UiState,
pause_controls_ui_state: UiState,
pause_dump_ui_state: UiState,
pause_options_rd_view: f32,
pause_controls_capture: ?Options.PcControl,
pause_controls_status: ControlsScreen.Status,
dump_world_name: [DumpWorldScreen.NameMax]u8,
dump_world_name_len: u8,
pause_ui_repeat: ui_input.Repeat,
pause_batcher: SpriteBatcher,
pause_font_batcher: FontBatcher,
inited: bool,

fn init(ctx: *anyopaque, engine: *Engine) anyerror!void {
    var self = Util.ctx_to_self(@This(), ctx);
    self.inited = false;
    self.mp_read_thread = null;
    self.compressor_thread = null;
    const gameplay_set = try bindings.init(&engine.input);
    try engine.input.push_context(&.{
        .name = "gameplay",
        .cursor_mode = .captured,
        .actions = gameplay_set,
        .consumes_text = false,
    });

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
            if (comptime !caps.networking.multiplayer) return error.UnsupportedPlatform;

            try caps.networking.begin_connect_setup();
            defer caps.networking.end_connect_setup();

            // LoadState consumed the handshake through LevelFinalize.
            self.conn.init(&Session.mp_reader.interface, &Session.mp_writer.interface);
            Session.mp_connected.store(true, .release);

            // Install recipients before the read loop can dispatch their packets.
            self.player_list = PlayerList.init();
            self.conn.player_list = &self.player_list;
            self.chat = Chat.init();
            self.conn.chat = &self.chat;

            self.mp_read_thread = try Util.Thread.spawn(
                .{
                    .name = "mp_read",
                    .stack_size = MpReadStackSize,
                    .priority = .normal,
                    .allocator = engine.allocator(.user),
                },
                ClientConn.read_loop,
                .{ &self.conn, &Session.mp_connected },
            );
        },
    }

    @import("../config.zig").apply_runtime_budgets(engine);

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
        // Handshake has not landed yet. Fall back to the world center at
        // eye-level-ish rather than a fixed position, so tiny worlds do not
        // start on their edge; the spawn packet corrects this on arrival.
        const dims = World.data.dims;
        try self.player.init(
            @as(f32, @floatFromInt(dims.length / 2)),
            @as(f32, @floatFromInt(dims.height - 20)),
            @as(f32, @floatFromInt(dims.depth / 2)),
            player_writer,
        );
    }
    self.player.camera.fov = Options.current.fov * std.math.pi / 180.0;

    const render_alloc = engine.allocator(.render);
    self.render_alloc = render_alloc;

    try ResourcePack.apply_tex_set(&.{ .font, .gui, .terrain, .clouds, .water_still, .lava_still, .char, .glyphs, .rain, .particles });

    try self.world.init_in_place(
        render_alloc,
        engine.io,
        ResourcePack.get_tex(.terrain),
        ResourcePack.get_tex(.clouds),
        ResourcePack.get_tex(.rain),
        ResourcePack.get_tex(.particles),
        ResourcePack.atlas,
        &self.player.camera,
    );

    self.conn.world_renderer = &self.world;

    self.player.particle_sink = &self.world.particles;

    self.ui_batcher = try SpriteBatcher.init(render_alloc);

    self.font_batcher = try FontBatcher.init(render_alloc, ResourcePack.get_tex(.font));

    self.iso_blocks = try IsoBlockDrawer.init(
        render_alloc,
        ResourcePack.get_tex(.terrain),
        ResourcePack.atlas,
    );

    try ui_input.ensure_registered(&engine.input);
    ui_input.set_profile(ui_input.default_profile());
    self.inventory_open = false;
    self.inventory_slot = 0;
    self.inventory_ui_state = .{};
    self.inventory_repeat = .{};
    var inv_i: u8 = 0;
    while (inv_i < blocks.InventorySlots) : (inv_i += 1) {
        self.inventory_blocks[inv_i] = blocks.inventory_block(inv_i);
    }
    if (Session.mode == .singleplayer) {
        self.player_list = PlayerList.init();
        self.conn.player_list = &self.player_list;
        self.chat = Chat.init();
        self.conn.chat = &self.chat;
    }
    self.social_mode = false;
    self.mp_fly_unlocked = false;
    self.hotbar_tooltip_timer = 0;
    self.prev_selected_slot = 0;
    self.report_timer = 0;
    self.hud_hidden = false;

    // Separate batchers guarantee the pause overlay flushes after gameplay UI.
    self.pause_batcher = try SpriteBatcher.init(render_alloc);
    self.pause_font_batcher = try FontBatcher.init(render_alloc, ResourcePack.get_tex(.font));
    self.paused = false;
    self.pause_screen = .main;
    self.pause_ui_repeat = .{};
    self.pause_ui_state = .{};
    self.pause_options_ui_state = .{};
    self.pause_controls_ui_state = .{};
    self.pause_dump_ui_state = .{};
    self.pause_options_rd_view = @floatFromInt(Options.capped_render_distance());
    self.pause_controls_capture = null;
    self.pause_controls_status = .none;
    self.dump_world_name = @splat(0);
    self.dump_world_name_len = 0;

    self.selection = try SelectionOutline.init(render_alloc);

    self.steve = try SteveModel.init(render_alloc);

    self.held = try BlockHand.init(render_alloc, ResourcePack.atlas);
    self.player.held_renderer = &self.held;

    switch (Session.mode) {
        .singleplayer => {},
        .multiplayer => {
            if (comptime !caps.networking.multiplayer) return error.UnsupportedPlatform;

            try CompressWorker.init(engine.allocator(.user), engine.io);
            errdefer CompressWorker.deinit();
            self.compressor_thread = try CompressorThread.spawn("world_compress", engine.allocator(.user));
        },
    }

    self.inited = true;
    engine.report();
}

fn deinit(ctx: *anyopaque, engine: *Engine) void {
    var self = Util.ctx_to_self(@This(), ctx);
    if (!self.inited) return;

    // Aether allows only one non-terminal text session at a time; cancel
    // any leftover so the next state can begin its own.
    if (engine.input.current_text_session()) |s| {
        if (s.status == .active or s.status == .suspended) engine.input.cancel_text() catch {};
    }
    ControlsScreen.cancel_capture(&engine.input, pause_controls_ctx(self));

    while (engine.input.stack_top()) |top| {
        if (std.mem.eql(u8, top.name, "gameplay")) {
            _ = engine.input.pop_context() catch {};
            break;
        }
        if (std.mem.eql(u8, top.name, "menu") or std.mem.eql(u8, top.name, "loading")) break;
        _ = engine.input.pop_context() catch break;
    }

    // Join the reader before freeing its world and UI recipients.
    switch (Session.mode) {
        .singleplayer => self.fake_conn.connected = false,
        .multiplayer => {
            Session.mp_connected.store(false, .release);
            if (Session.mp_stream) |*s| {
                s.close(engine.io);
                Session.mp_stream = null;
            }
            if (self.mp_read_thread) |t| {
                t.join();
                self.mp_read_thread = null;
            }
            // PSP reconnects fail unless the networking stack is reinitialized.
            caps.networking.release();
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

    // Keep compression alive until the final singleplayer save completes.
    switch (Session.mode) {
        .singleplayer => {
            self.ensure_sp_compressor_started(engine) catch |err| {
                log.err("failed to start SP compressor before shutdown: {}", .{err});
            };
            Server.deinit();
        },
        .multiplayer => World.deinit(),
    }
    if (self.compressor_thread) |*t| {
        CompressWorker.signal_exit();
        t.join();
        self.compressor_thread = null;
    }
    CompressWorker.deinit();
    self.inited = false;
}

fn tick(ctx: *anyopaque, engine: *Engine) anyerror!void {
    var self = Util.ctx_to_self(@This(), ctx);
    if (Session.mode == .singleplayer) {
        Server.drain_local_packets();
        Server.tick();
        try self.ensure_sp_compressor_started(engine);
    }
    ResourcePack.tick_animations();
    send_player_position(&self.player);
}

fn ensure_sp_compressor_started(self: *@This(), engine: *Engine) !void {
    if (comptime !execution.background_workers) return;

    if (self.compressor_thread != null) return;
    // Drain save jobs queued by Server.init only after the state transition
    // and initial memory report have completed.
    self.compressor_thread = try CompressorThread.spawn("world_compress", engine.allocator(.user));
}

fn send_player_position(player: *Player) void {
    const eye_y = player.pos_y + collision.EyeHeight;
    const x_fp: u16 = fp_coord(player.pos_x);
    const y_fp: u16 = fp_coord(eye_y);
    const z_fp: u16 = fp_coord(player.pos_z);

    // Camera yaw is CCW; Classic yaw is CW with the same zero point.
    const yaw_u8 = angle_to_classic_u8(-player.camera.yaw);
    const pitch_u8 = angle_to_classic_u8(player.camera.pitch);

    // Retry buffered chat/block packets after PSP ENOBUFS before adding newer positions.
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

fn angle_to_classic_u8(angle: f32) u8 {
    const tau: f32 = std.math.tau;
    var normalized = angle;
    while (normalized < 0.0) normalized += tau;
    while (normalized >= tau) normalized -= tau;
    const scaled = normalized * (256.0 / tau);
    if (scaled <= 0.0) return 0;
    if (scaled >= 255.0) return 255;
    return @intFromFloat(scaled);
}

fn focus_lost_this_frame(sys: *ae_input.InputSystem) bool {
    for (sys.frame_events()) |ev| {
        switch (ev.kind) {
            .focus_lost => return true,
            else => {},
        }
    }
    return false;
}

fn update_pause_menu(self: *@This(), engine: *Engine, in: *const ui_input.UiInput) !bool {
    var list: UiDrawList = .{};
    var ui = begin_pause_ui(self, &list, &self.pause_ui_state, in, PauseMenu.LayerBase);
    const action = PauseMenu.run(&ui, Session.mode == .singleplayer);
    ui.end();

    switch (action) {
        .none => {},
        .back => close_pause(self, engine),
        .options => enter_pause_options(self),
        .save => save_pause_world(),
        .dump_world => enter_pause_dump_world(self),
        .quit => {
            self.paused = false;
            self.pause_screen = .main;
            self.player.look_delta = .{ 0, 0 };
            self.pause_ui_state.cancel_active_text();
            self.pause_options_ui_state.cancel_active_text();
            self.pause_controls_ui_state.cancel_active_text();
            self.pause_dump_ui_state.cancel_active_text();
            ControlsScreen.cancel_capture(&engine.input, pause_controls_ctx(self));
            MenuState.transition_here(engine);
            return true;
        },
    }
    return false;
}

fn update_pause_options(self: *@This(), engine: *Engine, in: *const ui_input.UiInput) !void {
    var list: UiDrawList = .{};
    var ui = begin_pause_ui(self, &list, &self.pause_options_ui_state, in, OptionsScreen.LayerBase);
    const action = OptionsScreen.run(&ui, &Options.current, &self.pause_options_rd_view, .{});
    ui.end();
    self.player.camera.fov = Options.current.fov * std.math.pi / 180.0;
    switch (action) {
        .none => {},
        .controls => enter_pause_controls(self, engine),
        .close => {
            Options.save(engine.io, engine.dirs.data);
            engine.set_vsync(Options.current.vsync);
            leave_pause_options(self);
        },
    }
}

fn update_pause_controls(self: *@This(), engine: *Engine, in: *const ui_input.UiInput) !void {
    var list: UiDrawList = .{};
    var ui = begin_pause_ui(self, &list, &self.pause_controls_ui_state, in, OptionsScreen.LayerBase);
    const result = ControlsScreen.run(&ui, &Options.current, pause_controls_ctx(self));
    ui.end();
    if (result.changed) apply_control_options(engine);
    if (result.back) {
        Options.save(engine.io, engine.dirs.data);
        enter_pause_options(self);
    }
}

fn enter_pause_options(self: *@This()) void {
    self.pause_screen = .options;
    self.pause_options_rd_view = @floatFromInt(Options.capped_render_distance());
    self.pause_options_ui_state.open(ui_input.seed_focus_on_open());
}

fn leave_pause_options(self: *@This()) void {
    self.pause_screen = .main;
    self.pause_ui_state.open(ui_input.seed_focus_on_open());
}

fn enter_pause_controls(self: *@This(), engine: *Engine) void {
    ControlsScreen.cancel_capture(&engine.input, pause_controls_ctx(self));
    self.pause_controls_status = .none;
    self.pause_screen = .controls;
    self.pause_controls_ui_state.open(ui_input.seed_focus_on_open());
}

fn pause_controls_ctx(self: *@This()) ControlsScreen.Ctx {
    return .{
        .capture = &self.pause_controls_capture,
        .status = &self.pause_controls_status,
    };
}

fn apply_control_options(engine: *Engine) void {
    ui_input.apply_options(&engine.input) catch |err| log.warn("failed to apply UI control bindings: {}", .{err});
    bindings.apply_options(&engine.input) catch |err| log.warn("failed to apply gameplay control bindings: {}", .{err});
}

fn update_pause_dump_world(self: *@This(), in: *const ui_input.UiInput) !void {
    var path_buf: [World.DumpName.PathMax]u8 = undefined;
    var name_buf: [World.DumpName.NameMax]u8 = undefined;
    const can_save = blk: {
        _ = World.DumpName.build_path(self.dump_world_name_slice(), &path_buf, &name_buf) catch break :blk false;
        break :blk true;
    };

    var list: UiDrawList = .{};
    var ui = begin_pause_ui(self, &list, &self.pause_dump_ui_state, in, DumpWorldScreen.LayerBase);
    var dump_ctx: DumpWorldScreen.Ctx = .{
        .name = &self.dump_world_name,
        .name_len = &self.dump_world_name_len,
        .save_enabled = can_save,
    };
    const action = DumpWorldScreen.run(&ui, &dump_ctx);
    ui.end();

    switch (action) {
        .none => {},
        .back => leave_pause_dump_world(self),
        .save => {
            if (try_dump_world(self)) leave_pause_dump_world(self);
        },
    }
}

fn enter_pause_dump_world(self: *@This()) void {
    seed_dump_world_name(self);
    self.pause_screen = .dump_world;
    self.pause_dump_ui_state.open(ui_input.seed_focus_on_open());
}

fn leave_pause_dump_world(self: *@This()) void {
    self.pause_screen = .main;
    self.pause_ui_state.open(ui_input.seed_focus_on_open());
}

fn dump_world_name_slice(self: *const @This()) []const u8 {
    return self.dump_world_name[0..self.dump_world_name_len];
}

fn seed_dump_world_name(self: *@This()) void {
    const source = if (Session.server().len > 0) Session.server() else "world";
    if (World.DumpName.sanitize_name(source, self.dump_world_name[0..])) |name| {
        self.dump_world_name_len = @intCast(name.len);
        return;
    } else |_| {}

    const fallback = "world";
    @memset(&self.dump_world_name, 0);
    @memcpy(self.dump_world_name[0..fallback.len], fallback);
    self.dump_world_name_len = @intCast(fallback.len);
}

fn try_dump_world(self: *@This()) bool {
    var path_buf: [World.DumpName.PathMax]u8 = undefined;
    var name_buf: [World.DumpName.NameMax]u8 = undefined;
    const result = World.DumpName.build_path(self.dump_world_name_slice(), &path_buf, &name_buf) catch |err| {
        log.warn("invalid world dump name: {}", .{err});
        return false;
    };
    const metadata_name = std.mem.trim(u8, self.dump_world_name_slice(), " ");
    World.dump_named(result.path, metadata_name) catch |err| {
        log.err("failed to dump world: {}", .{err});
        return false;
    };
    log.info("world dump queued: {s}", .{result.path});
    return true;
}

fn save_pause_world() void {
    World.save();
    if (comptime caps.saves.download) {
        World.wait_for_save();
        const session_save = Session.singleplayer_save();
        const save_path = if (session_save.len > 0) session_save else Server.default_save_location;
        if (!caps.saves.download_file(save_path)) {
            log.warn("failed to download save file '{s}'", .{save_path});
        }
    }
}

fn open_pause(self: *@This(), engine: *Engine) void {
    if (self.paused) return;
    self.paused = true;
    self.pause_screen = .main;
    self.pause_ui_repeat = .{};
    self.pause_ui_state.open(ui_input.seed_focus_on_open());
    engine.input.push_context(&.{
        .name = "pause",
        .cursor_mode = .visible,
        .actions = ui_input.menu_set(),
        .consumes_text = true,
    }) catch {};
}

fn close_pause(self: *@This(), engine: *Engine) void {
    if (!self.paused) return;
    self.paused = false;
    self.pause_screen = .main;
    _ = engine.input.pop_context() catch {};
    bindings.refresh_active_context(&engine.input) catch |err| log.warn("failed to refresh gameplay controls: {}", .{err});
    self.player.look_delta = .{ 0, 0 };
    self.pause_ui_state.cancel_active_text();
    self.pause_options_ui_state.cancel_active_text();
    self.pause_controls_ui_state.cancel_active_text();
    self.pause_dump_ui_state.cancel_active_text();
    ControlsScreen.cancel_capture(&engine.input, pause_controls_ctx(self));
}

fn open_inventory(self: *@This(), engine: *Engine) void {
    if (self.inventory_open) return;
    self.inventory_open = true;
    self.inventory_slot = if (self.player.selected_slot < blocks.InventoryFilled)
        self.player.selected_slot
    else
        0;
    self.inventory_repeat = .{};
    self.inventory_ui_state.open(ui_input.seed_focus_on_open());
    self.inventory_ui_state.focused = InventoryUi.wid(.grid);
    engine.input.push_context(&.{
        .name = "inventory",
        .cursor_mode = .visible,
        .actions = ui_input.menu_set(),
        .consumes_text = false,
    }) catch {};
}

fn close_inventory(self: *@This(), engine: *Engine) void {
    if (!self.inventory_open) return;
    self.inventory_open = false;
    _ = engine.input.pop_context() catch {};
    bindings.refresh_active_context(&engine.input) catch |err| log.warn("failed to refresh gameplay controls: {}", .{err});
    // Discard the spurious look delta produced by the cursor-mode swap.
    self.player.look_delta = .{ 0, 0 };
    self.inventory_ui_state.cancel_active_text();
}

fn update_inventory_tree(self: *@This(), engine: *Engine, in: *const ui_input.UiInput) void {
    var list: UiDrawList = .{};
    var ui = begin_game_ui(self, &list, &self.inventory_ui_state, in, InventoryUi.LayerBase);
    const action = InventoryUi.run(&ui, self.inventory_blocks[0..], &self.inventory_slot);
    ui.end();
    switch (action) {
        .none => {},
        .select => {
            assert(self.player.selected_slot < Player.HotbarSlots);
            self.player.hotbar[self.player.selected_slot] = blocks.inventory_block(self.inventory_slot);
            close_inventory(self, engine);
        },
        .back => close_inventory(self, engine),
    }
}

fn begin_game_ui(self: *@This(), list: *UiDrawList, ui_state: *UiState, in: *const ui_input.UiInput, layer_base: u8) Ui {
    return Ui.begin(.{
        .draw = list,
        .state = ui_state,
        .input = in,
        .fonts = &self.font_batcher,
        .gui_tex = ResourcePack.get_tex(.gui),
        .glyphs_tex = ResourcePack.get_tex(.glyphs),
        .screen = Screen.logical_rect(),
        .layer_base = layer_base,
    });
}

fn begin_pause_ui(self: *@This(), list: *UiDrawList, ui_state: *UiState, in: *const ui_input.UiInput, layer_base: u8) Ui {
    return Ui.begin(.{
        .draw = list,
        .state = ui_state,
        .input = in,
        .fonts = &self.pause_font_batcher,
        .gui_tex = ResourcePack.get_tex(.gui),
        .glyphs_tex = ResourcePack.get_tex(.glyphs),
        .screen = Screen.logical_rect(),
        .layer_base = layer_base,
    });
}

fn update(ctx: *anyopaque, engine: *Engine, dt: f32, budget: *const Util.BudgetContext) anyerror!void {
    var self = Util.ctx_to_self(@This(), ctx);

    // Controller Select/Back toggles the social overlay (player list + chat
    // cursor). Keyboard Tab still uses the Classic hold-to-show player list.
    if (self.player.playerlist_edge) {
        const controller_edge = self.player.playerlist_edge_controller;
        self.player.playerlist_edge = false;
        self.player.playerlist_edge_controller = false;
        if (controller_edge) {
            if (self.social_mode) {
                self.social_mode = false;
                self.chat.close_overlay(&engine.input, &self.player);
            } else if (Session.mode == .multiplayer and !self.inventory_open) {
                self.social_mode = true;
                self.chat.open_overlay_social(&engine.input, &self.player);
            }
        }
    }

    const active_repeat = if (self.paused)
        &self.pause_ui_repeat
    else
        &self.inventory_repeat;
    const ui_in = ui_input.build_frame(&engine.input, dt, active_repeat);

    const can_open_pause = !self.paused and !self.chat.open and !self.inventory_open;
    var just_opened_pause = false;
    if (focus_lost_this_frame(&engine.input) and can_open_pause) {
        open_pause(self, engine);
        just_opened_pause = true;
    }
    const gameplay_pause = if (can_open_pause)
        engine.input.button(bindings.actions().ui_pause).pressed()
    else
        false;
    if ((ui_in.pause_edge or gameplay_pause) and can_open_pause) {
        open_pause(self, engine);
        just_opened_pause = true;
    }
    if (self.paused) {
        if (!just_opened_pause) {
            switch (self.pause_screen) {
                .main => {
                    // Do not let the opening Escape press close the menu again.
                    if (try update_pause_menu(self, engine, &ui_in)) return;
                },
                .options => try update_pause_options(self, engine, &ui_in),
                .controls => try update_pause_controls(self, engine, &ui_in),
                .dump_world => try update_pause_dump_world(self, &ui_in),
            }
        }
        // Clear leftover one-frame edges so they cannot fire on resume.
        self.player.inventory_toggle_pending = false;
        self.player.hud_toggle_pending = false;
        self.player.rain_toggle_pending = false;
        self.player.chat_open_pending = false;
        self.player.chat_cmd_pending = false;
        self.player.clear_fly_tap_state();
    } else {
        handle_fly_tap(self);

        if (self.player.hud_toggle_pending) {
            self.player.hud_toggle_pending = false;
            self.hud_hidden = !self.hud_hidden;
        }

        if (self.player.rain_toggle_pending) {
            self.player.rain_toggle_pending = false;
            Options.current.rain = !Options.current.rain;
            Options.save(engine.io, engine.dirs.data);
        }

        if (self.player.inventory_toggle_pending) {
            self.player.inventory_toggle_pending = false;
            if (self.inventory_open) {
                close_inventory(self, engine);
            } else if (!self.chat.open) {
                open_inventory(self, engine);
            }
        }

        if (self.player.chat_open_pending) {
            self.player.chat_open_pending = false;
            if (!self.chat.open and !self.inventory_open) {
                self.chat.open_overlay(&engine.input, &self.player, false);
            }
        }
        if (self.player.chat_cmd_pending) {
            self.player.chat_cmd_pending = false;
            if (!self.chat.open and !self.inventory_open) {
                self.chat.open_overlay(&engine.input, &self.player, true);
            }
        }

        if (self.inventory_open) update_inventory_tree(self, engine, &ui_in);

        if (self.chat.open) self.chat.update(&engine.input, &self.player);
        if (self.social_mode and !self.chat.open) self.social_mode = false;

        self.chat.tick(dt);

        // Player physics keep ticking with overlays open (matching
        // Classic); the masked ActionSet zeroes input.
        self.player.update(&engine.input, dt);
        if (self.player.selected) |hit| {
            const block_id = World.data.get_block(hit.x, hit.y, hit.z);
            if (!block_id.is_air()) try self.selection.update(block_id.bounds());
        }
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

    if (self.paused) {
        try prepare_ui_batches(self, engine);
        return;
    }

    const slot_block = self.player.hotbar[self.player.selected_slot];
    self.held.update(dt, slot_block, player_in_shadow(&self.player));

    if (self.player.selected_slot != self.prev_selected_slot) {
        self.prev_selected_slot = self.player.selected_slot;
        self.hotbar_tooltip_timer = 2.0;
    } else if (self.hotbar_tooltip_timer > 0) {
        self.hotbar_tooltip_timer -= dt;
        if (self.hotbar_tooltip_timer < 0) self.hotbar_tooltip_timer = 0;
    }
    try prepare_ui_batches(self, engine);
}

fn handle_fly_tap(self: *@This()) void {
    const event = self.player.consume_fly_tap_event() orelse return;

    switch (Session.mode) {
        .singleplayer => {
            if (event == .double) self.player.toggle_fly();
        },
        .multiplayer => {
            if (self.mp_fly_unlocked) {
                if (event == .double) self.player.toggle_fly();
                return;
            }

            switch (event) {
                .double => self.chat.receive(MpFlyWarning),
                .triple => {
                    self.mp_fly_unlocked = true;
                    self.player.set_fly(true);
                },
            }
        },
    }
}

fn player_in_shadow(player: *const Player) bool {
    const eye_y = player.pos_y + collision.EyeHeight;
    const fx = @floor(player.pos_x);
    const fy = @floor(eye_y);
    const fz = @floor(player.pos_z);
    const dims = World.data.dims;
    if (fx < 0.0 or fx >= @as(f32, @floatFromInt(dims.length))) return false;
    if (fy < 0.0 or fy >= @as(f32, @floatFromInt(dims.height))) return false;
    if (fz < 0.0 or fz >= @as(f32, @floatFromInt(dims.depth))) return false;
    const bx_i: i32 = @intFromFloat(fx);
    const by_i: i32 = @intFromFloat(fy);
    const bz_i: i32 = @intFromFloat(fz);
    return !World.is_sunlit(@intCast(bx_i), @intCast(by_i), @intCast(bz_i));
}

fn prepare_ui_batches(self: *@This(), engine: *Engine) !void {
    self.ui_batcher.clear();
    self.font_batcher.clear();
    self.iso_blocks.begin();

    var hud_list: UiDrawList = .{};

    if (!self.hud_hidden) {
        hud_list.add_text(&.{
            .str = "0.30",
            .pos_x = 2,
            .pos_y = 2,
            .color = Colors.white_fg,
            .shadow_color = Colors.menu_gray,
            .spacing = 0,
            .layer = 252,
            .reference = .top_left,
            .origin = .top_left,
        });
    }

    const tooltips_on = PromptStrip.enabled() and !self.hud_hidden;
    const show_glyphs = tooltips_on and !self.paused and !self.inventory_open;
    const hud_y_shift: i16 = if (tooltips_on) Buttons.strip_height() else 0;

    if (!self.hud_hidden) {
        self.player.draw_ui_into(&hud_list, ResourcePack.get_tex(.gui), self.inventory_open, hud_y_shift);
    }
    if (self.inventory_open) {
        var inv_list: UiDrawList = .{};
        var none: ui_input.UiInput = .{};
        var inv_ui = begin_game_ui(self, &inv_list, &self.inventory_ui_state, &none, InventoryUi.LayerBase);
        _ = InventoryUi.run(&inv_ui, self.inventory_blocks[0..], &self.inventory_slot);
        inv_ui.end();
        inv_list.flush_into(&self.ui_batcher, &self.font_batcher, &self.iso_blocks);
    }

    const show_playerlist = Session.mode == .multiplayer and !self.inventory_open and
        (self.social_mode or (self.player.playerlist_held and !self.chat.open));
    if (show_playerlist) {
        self.player_list.draw_into(&hud_list, Session.username());
    }
    self.chat.draw_into(&engine.input, &hud_list, &self.font_batcher, hud_y_shift);

    if (self.hotbar_tooltip_timer > 0 and !self.inventory_open and !self.hud_hidden) {
        const block = self.player.hotbar[self.player.selected_slot];
        const name = block.display_name();
        if (name.len > 0) {
            const alpha: u8 = if (self.hotbar_tooltip_timer >= 0.5)
                255
            else
                @intFromFloat(self.hotbar_tooltip_timer / 0.5 * 255.0);
            const shadow_alpha: u8 = if (self.hotbar_tooltip_timer >= 0.5)
                255
            else
                @intFromFloat(self.hotbar_tooltip_timer / 0.5 * 255.0);
            hud_list.add_text(&.{
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
        self.draw_hud_prompts(&hud_list);
    }

    hud_list.flush_into(&self.ui_batcher, &self.font_batcher, &self.iso_blocks);
    try self.ui_batcher.update();
    self.iso_blocks.update();
    try self.font_batcher.update();

    self.pause_batcher.clear();
    self.pause_font_batcher.clear();
    if (!self.paused) return;

    draw_pause_dim(self);
    var none: ui_input.UiInput = .{};
    switch (self.pause_screen) {
        .main => {
            var list: UiDrawList = .{};
            var ui = begin_pause_ui(self, &list, &self.pause_ui_state, &none, PauseMenu.LayerBase);
            _ = PauseMenu.run(&ui, Session.mode == .singleplayer);
            ui.end();
            list.flush_into(&self.pause_batcher, &self.pause_font_batcher, null);
        },
        .options => {
            var list: UiDrawList = .{};
            var ui = begin_pause_ui(self, &list, &self.pause_options_ui_state, &none, OptionsScreen.LayerBase);
            _ = OptionsScreen.run(&ui, &Options.current, &self.pause_options_rd_view, .{});
            ui.end();
            list.flush_into(&self.pause_batcher, &self.pause_font_batcher, null);
        },
        .controls => {
            var list: UiDrawList = .{};
            var ui = begin_pause_ui(self, &list, &self.pause_controls_ui_state, &none, OptionsScreen.LayerBase);
            _ = ControlsScreen.run(&ui, &Options.current, pause_controls_ctx(self));
            ui.end();
            list.flush_into(&self.pause_batcher, &self.pause_font_batcher, null);
        },
        .dump_world => {
            var path_buf: [World.DumpName.PathMax]u8 = undefined;
            var name_buf: [World.DumpName.NameMax]u8 = undefined;
            const can_save = blk: {
                _ = World.DumpName.build_path(self.dump_world_name_slice(), &path_buf, &name_buf) catch break :blk false;
                break :blk true;
            };
            var list: UiDrawList = .{};
            var ui = begin_pause_ui(self, &list, &self.pause_dump_ui_state, &none, DumpWorldScreen.LayerBase);
            var dump_ctx: DumpWorldScreen.Ctx = .{
                .name = &self.dump_world_name,
                .name_len = &self.dump_world_name_len,
                .save_enabled = can_save,
            };
            _ = DumpWorldScreen.run(&ui, &dump_ctx);
            ui.end();
            list.flush_into(&self.pause_batcher, &self.pause_font_batcher, null);
        },
    }
    try self.pause_batcher.update();
    try self.pause_font_batcher.update();
}

fn draw(ctx: *anyopaque, engine: *Engine, _: f32, _: *const Util.BudgetContext) anyerror!void {
    var self = Util.ctx_to_self(@This(), ctx);
    if (Session.mode == .singleplayer) {
        self.conn.drain_packets();
    } else if (!Session.mp_connected.load(.acquire)) {
        DisconnectState.transition_here(engine);
        return;
    }
    if (Session.mode == .singleplayer and self.conn.quit_requested) {
        DisconnectState.transition_here(engine);
        return;
    }
    self.player.camera.apply();
    self.world.draw_world_pass(&self.player.camera);

    // Rain depth-tests against terrain; the later fluid pass overlays it.
    self.world.draw_rain_pass(&self.player.camera);

    // Draw before fluids so water and lava occlude remote players.
    self.steve.draw(&self.player);
    self.steve.draw_nametags(&self.player, &self.font_batcher);

    // Pull the block-bounds outline toward the camera to avoid coplanar z-fighting.
    if (self.player.selected) |hit| blk: {
        const block_id = World.data.get_block(hit.x, hit.y, hit.z);
        if (block_id.is_air()) break :blk;
        const bounds = block_id.bounds();
        Rendering.gfx.api.bind_texture(Rendering.Texture.Default.handle);
        var t = Rendering.Transform.new();
        const cp = @cos(self.player.camera.pitch);
        const toward_camera = .{
            .x = @sin(self.player.camera.yaw) * cp,
            .y = @sin(self.player.camera.pitch),
            .z = @cos(self.player.camera.yaw) * cp,
        };
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

    // Fluids do not write depth, so render them after other world geometry.
    self.world.draw_fluid_pass();

    // The viewmodel leaves its projection active; the UI draw restores its own.
    if (!self.hud_hidden) {
        self.held.draw(ResourcePack.get_tex(.terrain), &self.player.camera);
    }

    Rendering.gfx.api.set_fog(false, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0);
    // Depth clears preserve the sprite, block-icon, then text ordering.
    Rendering.gfx.api.clear_depth();
    self.ui_batcher.draw();

    Rendering.gfx.api.clear_depth();
    self.iso_blocks.draw();

    Rendering.gfx.api.clear_depth();
    self.font_batcher.draw();

    if (self.paused) {
        Rendering.gfx.api.clear_depth();
        self.pause_batcher.draw();

        Rendering.gfx.api.clear_depth();
        self.pause_font_batcher.draw();
    }
}

fn draw_pause_dim(self: *@This()) void {
    const screen = Screen.logical_rect();

    self.pause_batcher.add_sprite(&.{
        .texture = &Rendering.Texture.Default,
        .pos_offset = .{ .x = 0, .y = 0 },
        .pos_extent = .{ .x = screen.x1, .y = screen.y1 },
        .tex_offset = .{ .x = 0, .y = 0 },
        .tex_extent = .{ .x = 1, .y = 1 },
        .color = Color.rgba(0, 0, 0, 160),
        .layer = PauseMenu.DimLayer,
        .reference = .top_left,
        .origin = .top_left,
    });
}

fn draw_hud_prompts(self: *@This(), list: *UiDrawList) void {
    const sprite_layer: u8 = 252;
    const text_layer: u8 = 252;
    const glyphs_tex = ResourcePack.get_tex(.glyphs);

    var buf: [3]PromptStrip.Prompt = undefined;
    var n: u8 = 0;

    if (self.social_mode and !self.chat.session_active) {
        buf[n] = Prompts.exit_list();
        n += 1;
        buf[n] = Prompts.chat();
        n += 1;
    } else if (self.chat.open) {
        buf[n] = Prompts.send();
        n += 1;
        buf[n] = Prompts.cancel();
        n += 1;
    } else {
        buf[n] = Prompts.inventory();
        n += 1;
        if (self.player.selected) |hit| {
            const block_id = World.data.get_block(hit.x, hit.y, hit.z);
            if (!block_id.is_air()) {
                if (hit.has_place) {
                    buf[n] = Prompts.place();
                    n += 1;
                }
                buf[n] = Prompts.break_();
                n += 1;
            }
        }
    }

    PromptStrip.draw_into(
        list,
        glyphs_tex,
        &self.font_batcher,
        buf[0..n],
        .bottom_left,
        PromptStrip.DefaultPosX,
        PromptStrip.DefaultPosY,
        sprite_layer,
        text_layer,
    );
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
