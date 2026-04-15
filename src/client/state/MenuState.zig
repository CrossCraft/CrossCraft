const std = @import("std");
const ae = @import("aether");
const Core = ae.Core;
const Util = ae.Util;
const Engine = ae.Engine;
const Rendering = ae.Rendering;
const State = Core.State;

const SpriteBatcher = @import("../ui/SpriteBatcher.zig");
const FontBatcher = @import("../ui/FontBatcher.zig");
const Vertex = @import("../graphics/Vertex.zig").Vertex;
const ResourcePack = @import("../ResourcePack.zig");
const SoundManager = @import("../SoundManager.zig");
const ui_input = @import("../ui/input.zig");
const Screen = @import("../ui/Screen.zig");
const MainMenuScreen = @import("../ui/MainMenuScreen.zig");
const DirectConnectScreen = @import("../ui/DirectConnectScreen.zig");
const TexturePackScreen = @import("../ui/TexturePackScreen.zig");
const LoadState = @import("LoadState.zig");
const Session = @import("Session.zig");

const build_options = @import("build_options");

const log = std.log.scoped(.menu);

// Embedded default pack bytes for Linux/Windows release builds (embed_pack=true).
// The @embedFile branch is dead and unevaluated when embed_pack=false, so the
// "default_pack" anonymous import need not exist in those builds.
const embedded_pack: []const u8 =
    if (build_options.embed_pack) @embedFile("default_pack") else &.{};

// Module-level singleton so DisconnectState can transition back here without
// needing access to the original stack-allocated instance from main().
var menu_state: @This() = undefined;
var menu_state_inst: State = undefined;

pub fn transition_here(engine: *Engine) !void {
    menu_state_inst = menu_state.state();
    try ae.Core.state_machine.transition(engine, &menu_state_inst);
}

batcher: SpriteBatcher,
font_batcher: FontBatcher,
splash_mesh: FontBatcher.BatchMesh,
time: f32,
screen: Screen,
ui_repeat: ui_input.Repeat,
main_menu_ctx: MainMenuScreen.Context,
direct_connect_ctx: DirectConnectScreen.Context,
texture_pack_ctx: TexturePackScreen.Context,
render_alloc: std.mem.Allocator,
/// True once `init` has run to completion. Guards `deinit` so a partially
/// initialised state -- e.g. `init` errored on OOM after enough world reload
/// cycles -- does not crash on undefined sub-allocations from a previous
/// session that have already been freed.
inited: bool,

var pipeline: Rendering.Pipeline.Handle = undefined;

fn init(ctx: *anyopaque, engine: *Engine) anyerror!void {
    var self = Util.ctx_to_self(@This(), ctx);
    self.inited = false;
    // Restore the startup pool layout. GameState shrinks user/game/etc. to
    // their runtime sizes; without this reset, the next LoadState connect
    // path (which needs ~6 MiB in user for the MP scratch + world buffer)
    // OOMs against the leftover rt_user budget.
    @import("../config.zig").apply_init_budgets(engine);
    const vert align(@alignOf(u32)) = @embedFile("basic_vert").*;
    const frag align(@alignOf(u32)) = @embedFile("basic_frag").*;
    pipeline = try Rendering.Pipeline.new(Vertex.Layout, &vert, &frag);

    const render_alloc = engine.allocator(.render);
    self.render_alloc = render_alloc;

    // Ensure the user texturepacks folder exists so players can drop packs
    // in without having to create the directory themselves. Under the
    // data dir (which resolves to ~/Library/Application Support/<app>/ on
    // mac, %APPDATA%\<app>\ on Windows, $XDG_DATA_HOME/<app>/ on Linux).
    engine.dirs.data.access(engine.io, "texturepacks", .{}) catch {
        engine.dirs.data.createDir(engine.io, "texturepacks", .default_dir) catch |err| {
            log.warn("failed to create texturepacks/: {}", .{err});
        };
    };

    // On Linux/Windows release builds, extract the embedded pack.zip to the
    // data dir on first run, then load from there every run.
    if (build_options.embed_pack) {
        engine.dirs.data.access(engine.io, "pack.zip", .{}) catch {
            var atomic = try engine.dirs.data.createFileAtomic(
                engine.io,
                "pack.zip",
                .{ .replace = true },
            );
            defer atomic.deinit(engine.io);
            atomic.file.writeStreamingAll(engine.io, embedded_pack) catch |err| {
                log.err("failed to extract pack.zip to data dir: {}", .{err});
                return err;
            };
            try atomic.replace(engine.io);
        };
    }

    const pack_dir = if (build_options.embed_pack) engine.dirs.data else engine.dirs.resources;
    try ResourcePack.init(render_alloc, engine.allocator(.game), engine.io, pack_dir, "pack.zip");
    errdefer ResourcePack.deinit();
    try ResourcePack.apply_tex_set(&.{ .dirt, .logo, .font, .gui });

    self.batcher = try SpriteBatcher.init(render_alloc, pipeline);
    self.font_batcher = try FontBatcher.init(render_alloc, pipeline, ResourcePack.get_tex(.font));
    self.splash_mesh = try self.font_batcher.build_mesh("Classic!", .splash_front, .splash_back, 0, 1);
    self.time = 0;
    self.ui_repeat = .{};

    try ui_input.ensure_registered();
    ui_input.set_profile(ui_input.default_profile());
    self.main_menu_ctx = .{
        .dirt = ResourcePack.get_tex(.dirt),
        .logo = ResourcePack.get_tex(.logo),
    };
    self.direct_connect_ctx = .{
        .dirt = ResourcePack.get_tex(.dirt),
    };
    self.texture_pack_ctx = .{
        .dirt = ResourcePack.get_tex(.dirt),
    };
    self.screen = MainMenuScreen.build(&self.main_menu_ctx);
    self.screen.open(!ui_input.profile_uses_pointer());

    self.inited = true;
    engine.report();
}

fn deinit(ctx: *anyopaque, _: *Engine) void {
    var self = Util.ctx_to_self(@This(), ctx);
    if (!self.inited) return;
    self.splash_mesh.deinit(self.render_alloc);
    self.font_batcher.deinit();
    self.batcher.deinit();

    Rendering.Pipeline.deinit(pipeline);
    self.inited = false;
}

fn tick(ctx: *anyopaque, _: *Engine) anyerror!void {
    _ = ctx;
}

fn update(ctx: *anyopaque, engine: *Engine, dt: f32, _: *const Util.BudgetContext) anyerror!void {
    var self = Util.ctx_to_self(@This(), ctx);
    self.time += dt;
    SoundManager.update(dt, 0, 0, 0, 0, 0);

    // PSP: service deferred OSK at the top of update - the previous
    // frame's end_frame has completed so the GE is idle.
    if (ae.platform == .psp) {
        if (self.screen.osk_request) |idx| {
            self.screen.osk_request = null;
            self.screen.open_psp_osk(idx);
        }
    }

    const in = ui_input.build_frame(dt, &self.ui_repeat);
    self.screen.update(&in);

    // Screen-switch signals set by button callbacks.
    if (MainMenuScreen.pending_direct_connect) {
        MainMenuScreen.pending_direct_connect = false;
        self.screen = DirectConnectScreen.build(&self.direct_connect_ctx);
        self.screen.open(!ui_input.profile_uses_pointer());
        return;
    }

    if (MainMenuScreen.pending_singleplayer) {
        MainMenuScreen.pending_singleplayer = false;
        Session.mode = .singleplayer;
        Session.set_username("Player");
        LoadState.transition_here(engine) catch |err| {
            log.err("transition to LoadState failed: {}", .{err});
        };
        return;
    }

    if (MainMenuScreen.pending_texture_packs) {
        MainMenuScreen.pending_texture_packs = false;
        TexturePackScreen.refresh(engine.io, engine.dirs.resources, engine.dirs.data);
        self.screen = TexturePackScreen.build(&self.texture_pack_ctx);
        self.screen.open(!ui_input.profile_uses_pointer());
        return;
    }

    const on_direct_connect = @intFromPtr(self.screen.ctx) == @intFromPtr(&self.direct_connect_ctx);
    if (on_direct_connect and (DirectConnectScreen.pending_back or self.screen.cancel_pressed)) {
        DirectConnectScreen.pending_back = false;
        self.screen = MainMenuScreen.build(&self.main_menu_ctx);
        self.screen.open(!ui_input.profile_uses_pointer());
    }

    const on_texture_pack = @intFromPtr(self.screen.ctx) == @intFromPtr(&self.texture_pack_ctx);
    if (on_texture_pack) {
        if (TexturePackScreen.pending_select) |sel| {
            TexturePackScreen.pending_select = null;
            self.apply_pack(sel.dir, sel.path);
        }
        if (TexturePackScreen.pending_back or self.screen.cancel_pressed) {
            TexturePackScreen.pending_back = false;
            self.screen = MainMenuScreen.build(&self.main_menu_ctx);
            self.screen.open(!ui_input.profile_uses_pointer());
        }
    }

    if (DirectConnectScreen.pending_join) {
        DirectConnectScreen.pending_join = false;

        // PSP: service the system network config dialog before we try to
        // connect, so the socket stack is brought up on first use.
        const net_ready = if (ae.platform == .psp) ae.Psp.showNetDialog() else true;
        if (!net_ready) return;

        Session.mode = .multiplayer;
        LoadState.transition_here(engine) catch |err| {
            log.err("transition to LoadState failed: {}", .{err});
        };
    }
}

fn draw(ctx: *anyopaque, _: *Engine, _: f32, _: *const Util.BudgetContext) anyerror!void {
    var self = Util.ctx_to_self(@This(), ctx);

    self.batcher.clear();
    self.font_batcher.clear();
    self.screen.draw(&self.batcher, &self.font_batcher, ResourcePack.get_tex(.gui));

    try self.batcher.flush();
    try self.font_batcher.flush();

    // Draw "Classic!" splash text only on the main menu.
    const on_main = @intFromPtr(self.screen.ctx) == @intFromPtr(&self.main_menu_ctx);
    if (on_main) {
        const pulse = @sin(self.time * 15.0) * 0.05 + 2.0;
        const model = self.font_batcher.mesh_matrix("Classic!", 0, 1, 112, 72, .top_center, .top_center, 22, pulse, 2);

        Rendering.Pipeline.bind(pipeline);
        ResourcePack.get_tex(.font).bind();
        self.splash_mesh.draw(&model);
    }
}

/// Swap to a new resource pack and reseat every dependent system. The
/// underlying texture slots are addressed by stable pointers, so the menu
/// screens, sprite batcher, and font batcher all keep working without
/// rebuilding -- only the glyph metric cache and the splash mesh need to
/// be regenerated to match the new font art.
fn apply_pack(self: *@This(), dir: std.Io.Dir, path: []const u8) void {
    ResourcePack.switch_pack(dir, path) catch |err| {
        log.err("switch_pack('{s}') failed: {}", .{ path, err });
        return;
    };

    // The font texture pointer is stable but its pixel data changed.
    self.font_batcher.refresh();

    // Splash mesh was built from the previous font's glyph widths.
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
