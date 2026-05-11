const std = @import("std");
const ae = @import("aether");
const Core = ae.Core;
const Util = ae.Util;
const Engine = ae.Engine;
const Rendering = ae.Rendering;
const State = Core.State;

const SpriteBatcher = @import("../ui/SpriteBatcher.zig");
const FontBatcher = @import("../ui/FontBatcher.zig");
const UiDrawList = @import("../ui/UiDrawList.zig");
const Ui = @import("../ui/Ui.zig");
const UiState = @import("../ui/UiState.zig");
const Scaling = @import("../ui/Scaling.zig");
const Vertex = @import("../graphics/Vertex.zig").Vertex;
const Options = @import("../Options.zig");
const ResourcePack = @import("../ResourcePack.zig");
const SoundManager = @import("../SoundManager.zig");
const ui_input = @import("../ui/input.zig");
const MainMenu = @import("../ui/screens/MainMenu.zig");
const DirectConnect = @import("../ui/screens/DirectConnect.zig");
const TexturePacks = @import("../ui/screens/TexturePacks.zig");
const OptionsScreen = @import("../ui/screens/Options.zig");
const LoadState = @import("LoadState.zig");
const Session = @import("Session.zig");

const build_options = @import("build_options");

const log = std.log.scoped(.menu);

const embedded_pack: []const u8 =
    if (build_options.embed_pack) @embedFile("default_pack") else &.{};

var menu_state: @This() = undefined;
var menu_state_inst: State = undefined;

pub fn transition_here(engine: *Engine) !void {
    menu_state_inst = menu_state.state();
    try ae.Core.state_machine.transition(engine, &menu_state_inst);
}

pub const ScreenId = enum { main, direct_connect, texture_packs, options };

batcher: SpriteBatcher,
font_batcher: FontBatcher,
splash_mesh: FontBatcher.BatchMesh,
time: f32,
active_screen: ScreenId,

main_ui_state: UiState,
dc_ui_state: UiState,
options_ui_state: UiState,
tp_ui_state: UiState,
ui_repeat: ui_input.Repeat,

dc_ip: [DirectConnect.IP_MAX]u8,
dc_ip_len: u8,
dc_name: [DirectConnect.NAME_MAX]u8,
dc_name_len: u8,

options_rd_view: f32,

tp_entries: [TexturePacks.max_packs + 1]TexturePacks.Entry,
tp_entry_count: u8,
tp_selected_index: ?u8,

dirt: *const Rendering.Texture,
logo: *const Rendering.Texture,
render_alloc: std.mem.Allocator,
inited: bool,

var pipeline: Rendering.Pipeline.Handle = undefined;

fn init(ctx: *anyopaque, engine: *Engine) anyerror!void {
    var self = Util.ctx_to_self(@This(), ctx);
    self.inited = false;
    @import("../config.zig").apply_init_budgets(engine);

    const vert align(@alignOf(u32)) = @embedFile("basic_vert").*;
    const frag align(@alignOf(u32)) = @embedFile("basic_frag").*;
    pipeline = try Rendering.Pipeline.new(Vertex.Layout, &vert, &frag);

    const render_alloc = engine.allocator(.render);
    self.render_alloc = render_alloc;

    engine.dirs.data.access(engine.io, "texturepacks", .{}) catch {
        engine.dirs.data.createDir(engine.io, "texturepacks", .default_dir) catch |err| {
            log.warn("failed to create texturepacks/: {}", .{err});
        };
    };
    engine.dirs.data.access(engine.io, "saves", .{}) catch {
        engine.dirs.data.createDir(engine.io, "saves", .default_dir) catch |err| {
            log.warn("failed to create saves/: {}", .{err});
        };
    };
    if (build_options.embed_pack) {
        engine.dirs.data.access(engine.io, "pack.zip", .{}) catch {
            const file = try engine.dirs.data.createFile(engine.io, "pack.zip", .{});
            defer file.close(engine.io);
            file.writeStreamingAll(engine.io, embedded_pack) catch |err| {
                log.err("failed to extract pack.zip to data dir: {}", .{err});
                return err;
            };
        };
    }

    Options.load(engine.io, engine.dirs.data);
    Options.save(engine.io, engine.dirs.data);
    engine.set_vsync(Options.current.vsync);

    const pack_dir = if (build_options.embed_pack) engine.dirs.data else engine.dirs.resources;
    try ResourcePack.init(render_alloc, engine.allocator(.game), engine.io, pack_dir, "pack.zip");
    errdefer ResourcePack.deinit();
    try ResourcePack.apply_tex_set(&.{ .dirt, .logo, .font, .gui, .glyphs });

    self.batcher = try SpriteBatcher.init(render_alloc, pipeline);
    self.font_batcher = try FontBatcher.init(render_alloc, pipeline, ResourcePack.get_tex(.font));
    self.splash_mesh = try self.font_batcher.build_mesh("Classic!", .splash_front, .splash_back, 0, 1);
    self.time = 0;
    self.ui_repeat = .{};
    self.main_ui_state = .{};
    self.dc_ui_state = .{};
    self.options_ui_state = .{};
    self.tp_ui_state = .{};
    self.dc_ip_len = 0;
    self.dc_name_len = 0;
    self.options_rd_view = @floatFromInt(Options.capped_render_distance());
    self.tp_entry_count = 0;
    self.tp_selected_index = null;

    try ui_input.ensure_registered();
    ui_input.set_profile(ui_input.default_profile());
    try ae.Core.input.push_context(.{
        .name = "menu",
        .cursor_mode = .visible,
        .actions = ui_input.menu_set(),
        .consumes_text = true,
    });

    self.dirt = ResourcePack.get_tex(.dirt);
    self.logo = ResourcePack.get_tex(.logo);
    self.active_screen = .main;
    self.main_ui_state.open(!ui_input.profile_uses_pointer());

    const saved_pack = Options.current.active_texturepack();
    if (saved_pack.len > 0) self.apply_pack(engine.dirs.data, saved_pack);

    self.inited = true;
    engine.report();
}

fn deinit(ctx: *anyopaque, _: *Engine) void {
    var self = Util.ctx_to_self(@This(), ctx);
    if (!self.inited) return;
    self.splash_mesh.deinit(self.render_alloc);
    self.font_batcher.deinit();
    self.batcher.deinit();
    _ = ae.Core.input.pop_context() catch {};
    Rendering.Pipeline.deinit(pipeline);
    self.inited = false;
}

fn tick(_: *anyopaque, _: *Engine) anyerror!void {}

fn update(ctx: *anyopaque, engine: *Engine, dt: f32, _: *const Util.BudgetContext) anyerror!void {
    var self = Util.ctx_to_self(@This(), ctx);
    self.time += dt;
    SoundManager.update(dt, 0, 0, 0, 0, 0);
    const in = ui_input.build_frame(dt, &self.ui_repeat);

    switch (self.active_screen) {
        .main => try update_main(self, engine, &in),
        .direct_connect => try update_direct_connect(self, engine, &in),
        .texture_packs => try update_texture_packs(self, engine, &in),
        .options => try update_options(self, engine, &in),
    }
}

fn update_main(self: *@This(), engine: *Engine, in: *const ui_input.UiInput) !void {
    var list: UiDrawList = .{};
    var ui = self.begin_ui(&list, &self.main_ui_state, in, 0);
    const action = MainMenu.run(&ui);
    ui.end();
    switch (action) {
        .none => {},
        .singleplayer => {
            Session.mode = .singleplayer;
            Session.set_username("Player");
            LoadState.transition_here(engine) catch |err| log.err("transition to LoadState failed: {}", .{err});
        },
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
    LoadState.transition_here(engine) catch |err| log.err("transition to LoadState failed: {}", .{err});
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
    const leave = OptionsScreen.run(&ui, &Options.current, &self.options_rd_view, .{});
    ui.end();
    if (leave) {
        Options.save(engine.io, engine.dirs.data);
        engine.set_vsync(Options.current.vsync);
        enter_main(self);
    }
}

fn enter_main(self: *@This()) void {
    self.active_screen = .main;
    self.main_ui_state.open(!ui_input.profile_uses_pointer());
}

fn enter_direct_connect(self: *@This()) void {
    self.active_screen = .direct_connect;
    self.dc_ui_state.open(!ui_input.profile_uses_pointer());
}

fn enter_texture_packs(self: *@This(), engine: *Engine) void {
    self.tp_entry_count = TexturePacks.scan(engine.io, engine.dirs.resources, engine.dirs.data, &self.tp_entries);
    self.tp_selected_index = TexturePacks.find_active_index(self.tp_entries[0..self.tp_entry_count]);
    self.active_screen = .texture_packs;
    self.tp_ui_state.open(!ui_input.profile_uses_pointer());
}

fn enter_options(self: *@This()) void {
    self.options_rd_view = @floatFromInt(Options.capped_render_distance());
    self.active_screen = .options;
    self.options_ui_state.open(!ui_input.profile_uses_pointer());
}

fn draw(ctx: *anyopaque, _: *Engine, _: f32, _: *const Util.BudgetContext) anyerror!void {
    var self = Util.ctx_to_self(@This(), ctx);
    self.batcher.clear();
    self.font_batcher.clear();
    draw_dirt_tiles(self);

    switch (self.active_screen) {
        .main => {
            draw_logo(self);
            draw_corner_labels(self);
        },
        else => {},
    }

    var list: UiDrawList = .{};
    var none = empty_input();
    switch (self.active_screen) {
        .main => {
            var ui = self.begin_ui(&list, &self.main_ui_state, &none, 0);
            _ = MainMenu.run(&ui);
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
        .options => {
            var ui = self.begin_ui(&list, &self.options_ui_state, &none, 0);
            _ = OptionsScreen.run(&ui, &Options.current, &self.options_rd_view, .{});
            ui.end();
        },
    }
    list.flush_into(&self.batcher, &self.font_batcher, null);

    try self.batcher.flush();
    try self.font_batcher.flush();

    if (self.active_screen == .main) {
        const pulse = @sin(self.time * 15.0) * 0.05 + 2.0;
        const model = self.font_batcher.mesh_matrix("Classic!", 0, 1, 112, 72, .top_center, .top_center, 22, pulse, 2);
        Rendering.Pipeline.bind(pipeline);
        ResourcePack.get_tex(.font).bind();
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
        .screen = current_screen_rect(),
        .layer_base = layer_base,
    });
}

fn current_screen_rect() Ui.LogicalRect {
    const screen_w = Rendering.gfx.surface.get_width();
    const screen_h = Rendering.gfx.surface.get_height();
    const scale = Scaling.compute(screen_w, screen_h);
    return .{
        .x0 = 0,
        .y0 = 0,
        .x1 = @intCast((screen_w + scale - 1) / scale),
        .y1 = @intCast((screen_h + scale - 1) / scale),
    };
}

fn empty_input() ui_input.UiInput {
    return .{
        .cursor_x = 0,
        .cursor_y = 0,
        .cursor_available = false,
        .cursor_moved = false,
        .click_edge = false,
        .click_held = false,
        .nav = .none,
        .confirm_edge = false,
        .cancel_edge = false,
        .pause_edge = false,
        .inventory_edge = false,
        .wheel_dy = 0,
        .text_events = false,
    };
}

fn draw_corner_labels(self: *@This()) void {
    self.font_batcher.add_text(&.{
        .str = "CrossCraft Classic v1.1-dev",
        .pos_x = 2,
        .pos_y = 2,
        .color = .gray_fg,
        .shadow_color = .menu_version,
        .spacing = 0,
        .layer = 2,
        .reference = .top_left,
        .origin = .top_left,
    });
    self.font_batcher.add_text(&.{
        .str = "Copyleft CrossCraft Team. Distribute!",
        .pos_x = -2,
        .pos_y = -2,
        .color = .white_fg,
        .shadow_color = .menu_copyright,
        .spacing = 0,
        .layer = 2,
        .reference = .bottom_right,
        .origin = .bottom_right,
    });
}

fn draw_dirt_tiles(self: *@This()) void {
    const rect = current_screen_rect();
    var y: i16 = 0;
    const tile_size: i16 = 32;
    while (y < rect.y1) : (y += tile_size) {
        var x: i16 = 0;
        while (x < rect.x1) : (x += tile_size) {
            self.batcher.add_sprite(&.{
                .texture = self.dirt,
                .pos_offset = .{ .x = x, .y = y },
                .pos_extent = .{ .x = tile_size, .y = tile_size },
                .tex_offset = .{ .x = 0, .y = 0 },
                .tex_extent = .{ .x = @intCast(self.dirt.width), .y = @intCast(self.dirt.height) },
                .color = .menu_tiles,
                .layer = 0,
            });
        }
    }
}

fn draw_logo(self: *@This()) void {
    self.batcher.add_sprite(&.{
        .texture = self.logo,
        .pos_offset = .{ .x = 0, .y = 24 },
        .pos_extent = .{ .x = 512, .y = 64 },
        .tex_offset = .{ .x = 0, .y = 0 },
        .tex_extent = .{ .x = @intCast(self.logo.width), .y = @intCast(self.logo.height) },
        .color = .white_fg,
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
    self.splash_mesh = self.font_batcher.build_mesh("Classic!", .splash_front, .splash_back, 0, 1) catch |err| {
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
