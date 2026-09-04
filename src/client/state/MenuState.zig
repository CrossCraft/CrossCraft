const std = @import("std");
const ae = @import("aether");
const Core = ae.Core;
const Util = ae.Util;
const Engine = ae.Engine;
const Rendering = ae.Rendering;
const State = Core.State;

const SpriteBatcher = ae.UI.SpriteBatcher;
const FontBatcher = ae.UI.FontBatcher;
const UiDrawList = @import("../ui/UiDrawList.zig");
const Ui = @import("../ui/Ui.zig");
const UiState = @import("../ui/UiState.zig");
const Screen = @import("../ui/Screen.zig");
const Colors = @import("../graphics/Color.zig");
const Options = @import("../Options.zig");
const ResourcePack = @import("../ResourcePack.zig");
const SoundManager = @import("../SoundManager.zig");
const ui_input = @import("../ui/input.zig");
const MainMenu = @import("../ui/screens/MainMenu.zig");
const DirectConnect = @import("../ui/screens/DirectConnect.zig");
const TexturePacks = @import("../ui/screens/TexturePacks.zig");
const SelectWorld = @import("../ui/screens/SelectWorld.zig");
const CreateWorld = @import("../ui/screens/CreateWorld.zig");
const BundledSave = @import("BundledSave.zig");
const OptionsScreen = @import("../ui/screens/Options.zig");
const ControlsScreen = @import("../ui/screens/Controls.zig");
const GameplayBindings = @import("../player/bindings.zig");
const LoadState = @import("LoadState.zig");
const Session = @import("Session.zig");
const core = @import("core");
const Server = core.Server;
const World = core.World;
const wd = core.world_dims;
const CompressWorker = core.CompressWorker;
const CompressorThread = @import("CompressorThread.zig");

const build_options = @import("build_options");

const log = std.log.scoped(.menu);
const default_create_world_name = "world";

const embedded_pack: []const u8 =
    if (build_options.embed_pack) @embedFile("default_pack") else &.{};

var menu_state: @This() = undefined;
var menu_state_inst: State = undefined;

pub fn transition_here(engine: *Engine) void {
    menu_state_inst = menu_state.state();
    engine.transition(&menu_state_inst);
}

pub const ScreenId = enum { main, direct_connect, texture_packs, select_world, create_world, options, controls };

batcher: SpriteBatcher,
font_batcher: FontBatcher,
splash_mesh: FontBatcher.TextMesh,
time: f32,
active_screen: ScreenId,

main_ui_state: UiState,
dc_ui_state: UiState,
options_ui_state: UiState,
controls_ui_state: UiState,
tp_ui_state: UiState,
sw_ui_state: UiState,
cw_ui_state: UiState,
ui_repeat: ui_input.Repeat,

dc_ip: [DirectConnect.IP_MAX]u8,
dc_ip_len: u8,
dc_name: [DirectConnect.NAME_MAX]u8,
dc_name_len: u8,

options_rd_view: f32,
controls_capture: ?Options.PcControl,
controls_status: ControlsScreen.Status,

tp_entries: [TexturePacks.max_packs + 1]TexturePacks.Entry,
tp_entry_count: u8,
tp_selected_index: ?u8,

sw_entries: [SelectWorld.max_worlds]SelectWorld.Entry,
sw_entry_count: u8,
sw_delete_mode: bool,

cw_name: [CreateWorld.NAME_MAX]u8,
cw_name_len: u8,
cw_seed: [CreateWorld.SEED_MAX]u8,
cw_seed_len: u8,
cw_size: wd.WorldSize,
cw_height: wd.WorldHeight,
cw_create_enabled: bool,

dirt: *const Rendering.Texture,
logo: *const Rendering.Texture,
render_alloc: std.mem.Allocator,
inited: bool,

fn init(ctx: *anyopaque, engine: *Engine) anyerror!void {
    var self = Util.ctx_to_self(@This(), ctx);
    self.inited = false;
    @import("../config.zig").apply_init_budgets(engine);

    const render_alloc = engine.allocator(.render);
    self.render_alloc = render_alloc;

    engine.dirs.data.createDir(engine.io, "texturepacks", .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => log.warn("failed to create texturepacks/: {}", .{err}),
    };
    engine.dirs.data.createDir(engine.io, "saves", .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => log.warn("failed to create saves/: {}", .{err}),
    };
    migrate_default_saves(engine.allocator(.user), engine.io, engine.dirs.data);
    _ = BundledSave.import_if_missing(engine.io, engine.dirs.resources, engine.dirs.data) catch |err| {
        log.warn("bundled save import failed; continuing without archival world: {}", .{err});
    };
    if (build_options.embed_pack) {
        engine.dirs.data.access(engine.io, "pack.zip", .{}) catch {
            const file = engine.dirs.data.createFile(engine.io, "pack.zip", .{}) catch |err|
                return menu_init_error(.extract_pack_create, err);
            defer file.close(engine.io);

            file.writeStreamingAll(engine.io, embedded_pack) catch |err| {
                log.err("failed to extract pack.zip to data dir: {}", .{err});
                return menu_init_error(.extract_pack_write, err);
            };
        };
    }

    Options.load(engine.io, engine.dirs.data);
    Options.save(engine.io, engine.dirs.data);
    engine.set_vsync(Options.current.vsync);

    const default_pack_dir = if (ae.platform == .nintendo_3ds or ae.platform == .nintendo_switch or build_options.embed_pack)
        engine.dirs.data
    else
        engine.dirs.resources;
    ResourcePack.init(render_alloc, engine.allocator(.game), engine.io, default_pack_dir, "pack.zip") catch |err|
        return menu_init_error(.default_pack_open, err);
    errdefer ResourcePack.deinit();
    ResourcePack.apply_tex_set(&.{ .dirt, .logo, .font, .gui, .glyphs }) catch |err|
        return menu_init_error(.default_textures, err);

    self.batcher = SpriteBatcher.init(render_alloc) catch |err|
        return menu_init_error(.sprite_batcher, err);
    self.font_batcher = FontBatcher.init(render_alloc, ResourcePack.get_tex(.font)) catch |err|
        return menu_init_error(.font_batcher, err);
    self.splash_mesh = self.font_batcher.build_mesh("Classic!", Colors.splash_front, Colors.splash_back, 0, 1) catch |err|
        return menu_init_error(.splash_mesh, err);
    self.time = 0;
    self.ui_repeat = .{};
    self.main_ui_state = .{};
    self.dc_ui_state = .{};
    self.options_ui_state = .{};
    self.controls_ui_state = .{};
    self.tp_ui_state = .{};
    self.sw_ui_state = .{};
    self.cw_ui_state = .{};
    self.dc_ip_len = 0;
    self.dc_name_len = 0;
    self.options_rd_view = @floatFromInt(Options.capped_render_distance());
    self.controls_capture = null;
    self.controls_status = .none;
    self.tp_entry_count = 0;
    self.tp_selected_index = null;
    self.sw_entry_count = 0;
    self.sw_delete_mode = false;
    self.cw_name_len = 0;
    self.cw_seed_len = 0;
    self.cw_size = .normal;
    self.cw_height = .normal;
    self.cw_create_enabled = false;

    ui_input.ensure_registered(&engine.input) catch |err|
        return menu_init_error(.input_register, err);
    ui_input.set_profile(ui_input.default_profile());
    engine.input.push_context(&.{
        .name = "menu",
        .cursor_mode = .visible,
        .actions = ui_input.menu_set(),
        .consumes_text = true,
    }) catch |err| return menu_init_error(.input_context, err);

    self.dirt = ResourcePack.get_tex(.dirt);
    self.logo = ResourcePack.get_tex(.logo);
    self.active_screen = .main;
    self.main_ui_state.open(ui_input.seed_focus_on_open());

    const saved_pack = Options.current.active_texturepack();
    if (saved_pack.len > 0) self.apply_pack(engine.dirs.data, saved_pack);

    self.inited = true;
    engine.report();
}

const MenuInitStage = enum {
    extract_pack_create,
    extract_pack_write,
    default_pack_open,
    default_textures,
    sprite_batcher,
    font_batcher,
    splash_mesh,
    input_register,
    input_context,
};

fn menu_init_error(comptime stage: MenuInitStage, err: anyerror) anyerror {
    switch (err) {
        error.Unexpected => {},
        else => return err,
    }

    return switch (stage) {
        .extract_pack_create => error.MenuInitExtractPackCreateUnexpected,
        .extract_pack_write => error.MenuInitExtractPackWriteUnexpected,
        .default_pack_open => error.MenuInitDefaultPackOpenUnexpected,
        .default_textures => error.MenuInitDefaultTexturesUnexpected,
        .sprite_batcher => error.MenuInitSpriteBatcherUnexpected,
        .font_batcher => error.MenuInitFontBatcherUnexpected,
        .splash_mesh => error.MenuInitSplashMeshUnexpected,
        .input_register => error.MenuInitInputRegisterUnexpected,
        .input_context => error.MenuInitInputContextUnexpected,
    };
}

fn migrate_default_saves(alloc: std.mem.Allocator, io: std.Io, data_dir: std.Io.Dir) void {
    var saves_dir = data_dir.createDirPathOpen(io, "saves", .{}) catch |err| {
        log.warn("legacy save migration: failed to open saves/: {}", .{err});
        return;
    };
    defer saves_dir.close(io);

    migrate_root_default_save(io, data_dir, saves_dir);
    migrate_legacy_world_dat(alloc, io, data_dir, saves_dir);
}

fn migrate_root_default_save(io: std.Io, data_dir: std.Io.Dir, saves_dir: std.Io.Dir) void {
    if (!file_exists(io, data_dir, Server.root_default_save_file_name)) return;

    var dest_name_buf: [SelectWorld.max_file_name_len]u8 = undefined;
    const dest_name = choose_legacy_dest_name(io, saves_dir, &dest_name_buf) orelse {
        log.warn("default save migration: no available saves/world_N.cw name", .{});
        return;
    };

    var dest_path_buf: [SelectWorld.max_path_len]u8 = undefined;
    const dest_path = std.fmt.bufPrint(&dest_path_buf, "saves/{s}", .{dest_name}) catch {
        log.warn("default save migration: destination path too long", .{});
        return;
    };

    data_dir.rename(Server.root_default_save_file_name, data_dir, dest_path, io) catch |err| {
        log.warn("default save migration: failed to rename {s} to {s}: {}", .{
            Server.root_default_save_file_name, dest_path, err,
        });
        return;
    };
    log.info("Migrated default save {s} -> {s}", .{ Server.root_default_save_file_name, dest_path });
}

fn migrate_legacy_world_dat(alloc: std.mem.Allocator, io: std.Io, data_dir: std.Io.Dir, saves_dir: std.Io.Dir) void {
    if (!file_exists(io, data_dir, Server.legacy_save_file_name)) return;

    var dest_name_buf: [SelectWorld.max_file_name_len]u8 = undefined;
    var backup_name_buf: [32]u8 = undefined;

    const dest_name = choose_legacy_dest_name(io, saves_dir, &dest_name_buf) orelse {
        log.warn("legacy save migration: no available saves/world_N.cw name", .{});
        return;
    };
    const backup_name = choose_legacy_backup_name(io, data_dir, &backup_name_buf) orelse {
        log.warn("legacy save migration: no available world.bak name", .{});
        return;
    };

    const data = alloc.create(World.WorldData) catch |err| {
        log.warn("legacy save migration: failed to allocate world data object: {}", .{err});
        return;
    };
    defer alloc.destroy(data);

    data.init_in_place(alloc, legacy_dims, 0) catch |err| {
        log.warn("legacy save migration: failed to allocate world data: {}", .{err});
        return;
    };
    defer data.deinit();

    if (!load_legacy_world_dat(io, data_dir, data)) return;
    if (!write_converted_legacy_save(alloc, io, saves_dir, dest_name, data)) return;

    data_dir.rename(Server.legacy_save_file_name, data_dir, backup_name, io) catch |err| {
        log.warn("legacy save migration: failed to rename {s} to {s}: {}", .{
            Server.legacy_save_file_name, backup_name, err,
        });
        return;
    };
    log.info("Migrated legacy save {s} -> saves/{s}; backup {s}", .{
        Server.legacy_save_file_name, dest_name, backup_name,
    });
}

/// Legacy `world.dat` files predate the size setting entirely, so they are
/// always the shipped default geometry. Read from `world_dims` rather than
/// `World.data`: the menu runs before any world exists.
const legacy_dims = core.world_dims.default;

fn load_legacy_world_dat(io: std.Io, data_dir: std.Io.Dir, data: *World.WorldData) bool {
    const file = data_dir.openFile(io, Server.legacy_save_file_name, .{}) catch return false;
    defer file.close(io);

    var read_buf: [32768]u8 = undefined;
    var reader = file.reader(io, &read_buf);
    const load_format: World.SaveFormat = .{ .classic_dat = .{} };
    const outcome = load_format.load_world(data.backing_allocator, data.dims, data.blocks, &reader.interface) catch |err| {
        log.warn("legacy save migration: failed to load {s}: {}", .{ Server.legacy_save_file_name, err });
        return false;
    };

    data.seed = outcome.seed;
    data.tick_count = outcome.tick_count;
    if (outcome.name_len > 0) {
        data.name = outcome.name;
        data.name_len = outcome.name_len;
    }
    data.uuid = outcome.uuid;
    data.time_created = outcome.time_created;
    return true;
}

fn write_converted_legacy_save(
    alloc: std.mem.Allocator,
    io: std.Io,
    saves_dir: std.Io.Dir,
    dest_name: []const u8,
    data: *World.WorldData,
) bool {
    if (comptime ae.platform == .wasm) {
        log.warn("legacy save migration unavailable on wasm", .{});
        return false;
    }

    CompressWorker.init(alloc, io) catch |err| {
        log.warn("legacy save migration: failed to init compressor: {}", .{err});
        return false;
    };
    var thread = CompressorThread.spawn_named("legacy_save_convert", alloc) catch |err| {
        CompressWorker.deinit();
        log.warn("legacy save migration: failed to start compressor: {}", .{err});
        return false;
    };
    defer {
        CompressWorker.signal_exit();
        thread.join();
        CompressWorker.deinit();
    }

    var saver = World.WorldSaver.init(io, saves_dir, dest_name, World.default_format);
    defer saver.deinit();

    saver.owned_locally = true;
    saver.save(data);
    saver.wait_for_save();

    const file = saves_dir.openFile(io, dest_name, .{}) catch |err| {
        log.warn("legacy save migration: converted save missing: {}", .{err});
        return false;
    };
    defer file.close(io);

    const st = file.stat(io) catch |err| {
        log.warn("legacy save migration: converted save stat failed: {}", .{err});
        return false;
    };
    return st.size > 0;
}

fn choose_legacy_dest_name(io: std.Io, saves_dir: std.Io.Dir, out: *[SelectWorld.max_file_name_len]u8) ?[]const u8 {
    if (!file_exists(io, saves_dir, "world.cw")) return "world.cw";

    var i: u16 = 2;
    while (i < 1000) : (i += 1) {
        const name = std.fmt.bufPrint(out, "world_{d}.cw", .{i}) catch return null;
        if (!file_exists(io, saves_dir, name)) return name;
    }
    return null;
}

fn choose_legacy_backup_name(io: std.Io, data_dir: std.Io.Dir, out: *[32]u8) ?[]const u8 {
    if (!file_exists(io, data_dir, "world.bak")) return "world.bak";

    var i: u16 = 2;
    while (i < 1000) : (i += 1) {
        const name = std.fmt.bufPrint(out, "world.{d}.bak", .{i}) catch return null;
        if (!file_exists(io, data_dir, name)) return name;
    }
    return null;
}

fn file_exists(io: std.Io, dir: std.Io.Dir, path: []const u8) bool {
    const file = dir.openFile(io, path, .{}) catch return false;
    file.close(io);
    return true;
}

fn deinit(ctx: *anyopaque, engine: *Engine) void {
    var self = Util.ctx_to_self(@This(), ctx);
    if (!self.inited) return;
    ControlsScreen.cancel_capture(&engine.input, controls_ctx(self));
    self.splash_mesh.deinit(self.render_alloc);
    self.font_batcher.deinit();
    self.batcher.deinit();
    _ = engine.input.pop_context() catch {};
    self.inited = false;
}

fn tick(_: *anyopaque, _: *Engine) anyerror!void {}

fn update(ctx: *anyopaque, engine: *Engine, dt: f32, _: *const Util.BudgetContext) anyerror!void {
    var self = Util.ctx_to_self(@This(), ctx);
    self.time += dt;
    SoundManager.update(dt, 0, 0, 0, 0, 0);
    const in = ui_input.build_frame(&engine.input, dt, &self.ui_repeat);

    switch (self.active_screen) {
        .main => try update_main(self, engine, &in),
        .direct_connect => try update_direct_connect(self, engine, &in),
        .texture_packs => try update_texture_packs(self, engine, &in),
        .select_world => try update_select_world(self, engine, &in),
        .create_world => try update_create_world(self, engine, &in),
        .options => try update_options(self, engine, &in),
        .controls => try update_controls(self, engine, &in),
    }
    if (!self.inited) return;
    try prepare_batches(self, engine);
}

fn prepare_batches(self: *@This(), _: *Engine) !void {
    self.batcher.clear();
    self.font_batcher.clear();
    Screen.add_dirt_background(&self.batcher, self.dirt);

    switch (self.active_screen) {
        .main => {
            draw_logo(self);
            draw_corner_labels(self);
        },
        else => {},
    }

    var list: UiDrawList = .{};
    var none = Screen.empty_input();
    switch (self.active_screen) {
        .main => {
            var ui = self.begin_ui(&list, &self.main_ui_state, &none, 0);
            _ = MainMenu.run(&ui, main_menu_options());
            ui.end();
        },
        .direct_connect => {
            var ui = self.begin_ui(&list, &self.dc_ui_state, &none, 0);
            var dc: DirectConnect.Ctx = .{
                .ip = &self.dc_ip,
                .ip_len = &self.dc_ip_len,
                .name = &self.dc_name,
                .name_len = &self.dc_name_len,
            };
            _ = DirectConnect.run(&ui, &dc);
            ui.end();
        },
        .texture_packs => {
            var ui = self.begin_ui(&list, &self.tp_ui_state, &none, 0);
            _ = TexturePacks.run(&ui, self.tp_entries[0..self.tp_entry_count], self.tp_selected_index);
            ui.end();
        },
        .select_world => {
            var ui = self.begin_ui(&list, &self.sw_ui_state, &none, 0);
            _ = SelectWorld.run(&ui, self.sw_entries[0..self.sw_entry_count], self.sw_delete_mode);
            ui.end();
        },
        .create_world => {
            var ui = self.begin_ui(&list, &self.cw_ui_state, &none, 0);
            var cw: CreateWorld.Ctx = .{
                .name = &self.cw_name,
                .name_len = &self.cw_name_len,
                .seed = &self.cw_seed,
                .seed_len = &self.cw_seed_len,
                .size = &self.cw_size,
                .height = &self.cw_height,
                .create_enabled = self.cw_create_enabled,
            };
            _ = CreateWorld.run(&ui, &cw);
            ui.end();
        },
        .options => {
            var ui = self.begin_ui(&list, &self.options_ui_state, &none, 0);
            _ = OptionsScreen.run(&ui, &Options.current, &self.options_rd_view, .{});
            ui.end();
        },
        .controls => {
            var ui = self.begin_ui(&list, &self.controls_ui_state, &none, 0);
            _ = ControlsScreen.run(&ui, &Options.current, controls_ctx(self));
            ui.end();
        },
    }
    list.flush_into(&self.batcher, &self.font_batcher, null);

    try self.batcher.update();
    try self.font_batcher.update();
}

fn update_main(self: *@This(), engine: *Engine, in: *const ui_input.UiInput) !void {
    if (in.title_exit_edge) {
        engine.quit();
        return;
    }

    var list: UiDrawList = .{};
    var ui = self.begin_ui(&list, &self.main_ui_state, in, 0);
    const action = MainMenu.run(&ui, main_menu_options());
    ui.end();
    switch (action) {
        .none => {},
        .singleplayer => enter_select_world(self, engine),
        .multiplayer => enter_direct_connect(self),
        .texture_packs => enter_texture_packs(self, engine),
        .options => enter_options(self),
    }
}

fn update_direct_connect(self: *@This(), engine: *Engine, in: *const ui_input.UiInput) !void {
    var list: UiDrawList = .{};
    var ui = self.begin_ui(&list, &self.dc_ui_state, in, 0);
    var dc: DirectConnect.Ctx = .{
        .ip = &self.dc_ip,
        .ip_len = &self.dc_ip_len,
        .name = &self.dc_name,
        .name_len = &self.dc_name_len,
    };
    const action = DirectConnect.run(&ui, &dc);
    ui.end();
    switch (action) {
        .none => {},
        .join => try dc_join(self, engine),
        .back => enter_main(self),
    }
}

fn dc_join(self: *@This(), engine: *Engine) !void {
    Session.set_server(self.dc_ip[0..self.dc_ip_len]);
    if (self.dc_name_len > 0) {
        Session.set_username(self.dc_name[0..self.dc_name_len]);
    } else {
        Session.set_username("Player");
    }
    const net_ready = if (ae.platform == .psp) ae.Psp.showNetDialog() else true;
    if (!net_ready) return;
    Session.mode = .multiplayer;
    LoadState.transition_here(engine);
}

fn update_texture_packs(self: *@This(), engine: *Engine, in: *const ui_input.UiInput) !void {
    var list: UiDrawList = .{};
    var ui = self.begin_ui(&list, &self.tp_ui_state, in, 0);
    const result = TexturePacks.run(&ui, self.tp_entries[0..self.tp_entry_count], self.tp_selected_index);
    ui.end();
    switch (result) {
        .none => {},
        .done => enter_main(self),
        .select => |row| tp_select_row(self, engine, row),
    }
}

fn update_select_world(self: *@This(), engine: *Engine, in: *const ui_input.UiInput) !void {
    var list: UiDrawList = .{};
    var ui = self.begin_ui(&list, &self.sw_ui_state, in, 0);
    const result = SelectWorld.run(&ui, self.sw_entries[0..self.sw_entry_count], self.sw_delete_mode);
    ui.end();
    switch (result) {
        .none => {},
        .cancel => enter_main(self),
        .toggle_delete => self.sw_delete_mode = !self.sw_delete_mode,
        .create => enter_create_world(self, engine),
        .select => |row| sw_select_row(self, engine, row),
    }
}

fn update_create_world(self: *@This(), engine: *Engine, in: *const ui_input.UiInput) !void {
    var list: UiDrawList = .{};
    var ui = self.begin_ui(&list, &self.cw_ui_state, in, 0);
    const old_name_len = self.cw_name_len;
    const old_name = self.cw_name;
    var cw: CreateWorld.Ctx = .{
        .name = &self.cw_name,
        .name_len = &self.cw_name_len,
        .seed = &self.cw_seed,
        .seed_len = &self.cw_seed_len,
        .size = &self.cw_size,
        .height = &self.cw_height,
        .create_enabled = self.cw_create_enabled,
    };
    const action = CreateWorld.run(&ui, &cw);
    ui.end();
    if (old_name_len != self.cw_name_len or !std.mem.eql(u8, old_name[0..old_name_len], self.cw_name[0..self.cw_name_len])) {
        self.refresh_create_world_available(engine);
    }
    switch (action) {
        .none => {},
        .create => create_world(self, engine),
        .back => enter_select_world(self, engine),
    }
}

fn sw_select_row(self: *@This(), engine: *Engine, row: u8) void {
    if (row >= self.sw_entry_count) return;
    const entry = &self.sw_entries[row];
    if (self.sw_delete_mode) {
        if (SelectWorld.delete_entry(engine.io, engine.dirs.data, entry)) {
            self.sw_entry_count = SelectWorld.scan(engine.io, engine.dirs.data, &self.sw_entries);
            self.sw_delete_mode = false;
        }
        return;
    }

    Session.mode = .singleplayer;
    Session.set_username("Player");
    Session.set_singleplayer_save(entry.path());
    Session.clear_singleplayer_seed_override();
    Session.clear_singleplayer_size_height();
    LoadState.transition_here(engine);
}

fn create_world_available(self: *const @This(), engine: *Engine) bool {
    return create_world_name_available(engine, self.create_world_name_slice());
}

fn refresh_create_world_available(self: *@This(), engine: *Engine) void {
    self.cw_create_enabled = self.create_world_available(engine);
}

fn create_world_name_available(engine: *Engine, name: []const u8) bool {
    var path_buf: [World.CreateName.PATH_MAX]u8 = undefined;
    var name_buf: [World.CreateName.NAME_MAX]u8 = undefined;
    const result = World.CreateName.build_path(name, &path_buf, &name_buf) catch return false;
    return !file_exists(engine.io, engine.dirs.data, result.path);
}

fn create_world(self: *@This(), engine: *Engine) void {
    var path_buf: [World.CreateName.PATH_MAX]u8 = undefined;
    var name_buf: [World.CreateName.NAME_MAX]u8 = undefined;
    const result = World.CreateName.build_path(self.create_world_name_slice(), &path_buf, &name_buf) catch |err| {
        log.warn("invalid create-world name: {}", .{err});
        return;
    };
    if (file_exists(engine.io, engine.dirs.data, result.path)) {
        log.warn("create-world save already exists: {s}", .{result.path});
        return;
    }

    Session.mode = .singleplayer;
    Session.set_username("Player");
    Session.set_singleplayer_save(result.path);
    Session.set_singleplayer_seed_override(Session.seed_from_text(self.create_world_seed_slice()));
    Session.set_singleplayer_size(self.cw_size);
    Session.set_singleplayer_height(self.cw_height);
    LoadState.transition_here(engine);
}

fn create_world_name_slice(self: *const @This()) []const u8 {
    return self.cw_name[0..self.cw_name_len];
}

fn create_world_seed_slice(self: *const @This()) []const u8 {
    return self.cw_seed[0..self.cw_seed_len];
}

fn tp_select_row(self: *@This(), engine: *Engine, row: u8) void {
    if (row >= self.tp_entry_count) return;
    if (self.tp_selected_index) |si| if (si == row) return;
    const entry = &self.tp_entries[row];
    self.apply_pack(entry.dir, entry.path());
    const is_default = std.mem.eql(u8, entry.path(), TexturePacks.default_path);
    Options.current.set_active_texturepack(if (is_default) "" else entry.path());
    Options.save(engine.io, engine.dirs.data);
    self.tp_selected_index = row;
}

fn update_options(self: *@This(), engine: *Engine, in: *const ui_input.UiInput) !void {
    var list: UiDrawList = .{};
    var ui = self.begin_ui(&list, &self.options_ui_state, in, 0);
    const action = OptionsScreen.run(&ui, &Options.current, &self.options_rd_view, .{});
    ui.end();
    switch (action) {
        .none => {},
        .controls => if (Options.controls_rebinding_supported()) enter_controls(self, engine),
        .close => {
            Options.save(engine.io, engine.dirs.data);
            engine.set_vsync(Options.current.vsync);
            enter_main(self);
        },
    }
}

fn update_controls(self: *@This(), engine: *Engine, in: *const ui_input.UiInput) !void {
    var list: UiDrawList = .{};
    var ui = self.begin_ui(&list, &self.controls_ui_state, in, 0);
    const result = ControlsScreen.run(&ui, &Options.current, controls_ctx(self));
    ui.end();
    if (result.changed) apply_control_options(engine);
    if (result.back) {
        Options.save(engine.io, engine.dirs.data);
        enter_options(self);
    }
}

fn enter_main(self: *@This()) void {
    self.active_screen = .main;
    self.main_ui_state.open(ui_input.seed_focus_on_open());
}

fn main_menu_options() MainMenu.Options {
    return .{
        .multiplayer_enabled = ae.platform != .wasm,
        .texture_packs_enabled = ae.platform != .wasm,
    };
}

fn enter_direct_connect(self: *@This()) void {
    self.active_screen = .direct_connect;
    self.dc_ui_state.open(ui_input.seed_focus_on_open());
}

fn enter_texture_packs(self: *@This(), engine: *Engine) void {
    const default_pack_dir = if (ae.platform == .nintendo_3ds or ae.platform == .nintendo_switch) engine.dirs.data else engine.dirs.resources;
    self.tp_entry_count = TexturePacks.scan(engine.io, default_pack_dir, engine.dirs.data, &self.tp_entries);
    self.tp_selected_index = TexturePacks.find_active_index(self.tp_entries[0..self.tp_entry_count]);
    self.active_screen = .texture_packs;
    self.tp_ui_state.open(ui_input.seed_focus_on_open());
}

fn enter_select_world(self: *@This(), engine: *Engine) void {
    self.sw_entry_count = SelectWorld.scan(engine.io, engine.dirs.data, &self.sw_entries);
    self.sw_delete_mode = false;
    Session.clear_singleplayer_seed_override();
    Session.clear_singleplayer_size_height();
    self.active_screen = .select_world;
    self.sw_ui_state.open(ui_input.seed_focus_on_open());
}

fn enter_create_world(self: *@This(), engine: *Engine) void {
    seed_create_world_name(self, engine);
    self.cw_seed_len = 0;
    self.sw_delete_mode = false;
    self.refresh_create_world_available(engine);
    self.active_screen = .create_world;
    self.cw_ui_state.open(ui_input.seed_focus_on_open());
}

fn seed_create_world_name(self: *@This(), engine: *Engine) void {
    if (create_world_name_available(engine, default_create_world_name)) {
        set_create_world_name(self, default_create_world_name);
        return;
    }

    var candidate_buf: [World.CreateName.NAME_MAX]u8 = undefined;
    var i: u16 = 1;
    while (i < 1000) : (i += 1) {
        const candidate = std.fmt.bufPrint(&candidate_buf, "world_{d}", .{i}) catch break;
        if (create_world_name_available(engine, candidate)) {
            set_create_world_name(self, candidate);
            return;
        }
    }

    self.cw_name_len = 0;
}

fn set_create_world_name(self: *@This(), name: []const u8) void {
    @memset(&self.cw_name, 0);
    const len = @min(name.len, self.cw_name.len);
    @memcpy(self.cw_name[0..len], name[0..len]);
    self.cw_name_len = @intCast(len);
}

fn enter_options(self: *@This()) void {
    self.options_rd_view = @floatFromInt(Options.capped_render_distance());
    self.active_screen = .options;
    self.options_ui_state.open(ui_input.seed_focus_on_open());
}

fn enter_controls(self: *@This(), engine: *Engine) void {
    ControlsScreen.cancel_capture(&engine.input, controls_ctx(self));
    self.controls_status = .none;
    self.active_screen = .controls;
    self.controls_ui_state.open(ui_input.seed_focus_on_open());
}

fn controls_ctx(self: *@This()) ControlsScreen.Ctx {
    return .{
        .capture = &self.controls_capture,
        .status = &self.controls_status,
    };
}

fn apply_control_options(engine: *Engine) void {
    ui_input.apply_options(&engine.input) catch |err| log.warn("failed to apply UI control bindings: {}", .{err});
    GameplayBindings.apply_options(&engine.input) catch |err| log.warn("failed to apply gameplay control bindings: {}", .{err});
}

fn draw(ctx: *anyopaque, engine: *Engine, _: f32, _: *const Util.BudgetContext) anyerror!void {
    var self = Util.ctx_to_self(@This(), ctx);
    _ = engine;
    self.batcher.draw();
    self.font_batcher.draw();

    if (self.active_screen == .main) {
        const pulse = @sin(self.time * 15.0) * 0.05 + 2.0;
        const model = self.font_batcher.mesh_matrix("Classic!", 0, 1, 112, 72, .top_center, .top_center, 22, pulse, 2);
        Rendering.set_state(&.{ .texture = ResourcePack.get_tex(.font).handle });
        self.splash_mesh.draw(&model);
    }
}

fn begin_ui(self: *@This(), list: *UiDrawList, ui_state: *UiState, in: *const ui_input.UiInput, layer_base: u8) Ui {
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

fn draw_corner_labels(self: *@This()) void {
    self.font_batcher.add_text(&.{
        .str = "CrossCraft Classic v1.1",
        .pos_x = 2,
        .pos_y = 2,
        .color = Colors.gray_fg,
        .shadow_color = Colors.menu_version,
        .spacing = 0,
        .layer = 2,
        .reference = .top_left,
        .origin = .top_left,
    });
    self.font_batcher.add_text(&.{
        .str = "Copyleft CrossCraft Team. Distribute!",
        .pos_x = -2,
        .pos_y = -2,
        .color = Colors.white_fg,
        .shadow_color = Colors.menu_copyright,
        .spacing = 0,
        .layer = 2,
        .reference = .bottom_right,
        .origin = .bottom_right,
    });
}

fn draw_logo(self: *@This()) void {
    self.batcher.add_sprite(&.{
        .texture = self.logo,
        .pos_offset = .{ .x = 0, .y = 24 },
        .pos_extent = .{ .x = 512, .y = 64 },
        .tex_offset = .{ .x = 0, .y = 0 },
        .tex_extent = .{ .x = @intCast(self.logo.width), .y = @intCast(self.logo.height) },
        .color = Colors.white_fg,
        .layer = 1,
        .reference = .top_center,
        .origin = .top_center,
    });
}

fn apply_pack(self: *@This(), dir: std.Io.Dir, path: []const u8) void {
    ResourcePack.switch_pack(dir, path) catch |err| {
        log.err("switch_pack('{s}') failed: {}", .{ path, err });
        return;
    };
    self.font_batcher.refresh();
    self.splash_mesh.deinit(self.render_alloc);
    self.splash_mesh = self.font_batcher.build_mesh("Classic!", Colors.splash_front, Colors.splash_back, 0, 1) catch |err| {
        log.err("rebuild splash mesh failed: {}", .{err});
        return;
    };
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
