const std = @import("std");
const ae = @import("aether");
const Core = ae.Core;
const Util = ae.Util;
const Engine = ae.Engine;
const Rendering = ae.Rendering;
const State = Core.State;

const SpriteBatcher = @import("../ui/SpriteBatcher.zig");
const FontBatcher = @import("../ui/FontBatcher.zig");
const Scaling = @import("../ui/Scaling.zig");
const ResourcePack = @import("../ResourcePack.zig");
const Server = @import("game").Server;
const World = @import("game").World;
const GameState = @import("GameState.zig");
const DisconnectState = @import("DisconnectState.zig");
const Session = @import("Session.zig");
const proto = @import("common").protocol;
const common_time = @import("common").time;
const flate = std.compress.flate;

const pspsdk = if (ae.platform == .psp) @import("pspsdk") else void;

const log = std.log.scoped(.game);
const DIAG_ONE_DIRT_QUAD_3DS = false;

// Module-level: only one LoadState instance may exist at a time.
var server_ready: std.atomic.Value(bool) = .init(false);
var session_error: ?anyerror = null;
var mp_server_name: [64]u8 = @splat(' ');
var mp_server_motd: [64]u8 = @splat(' ');

/// Empty action set; exists only so push_context has a valid installed
/// set during the loading screen.
var loading_set: ?ae.Core.input.ActionSetHandle = null;

fn ensure_loading_set() !ae.Core.input.ActionSetHandle {
    if (loading_set) |h| return h;
    const set = try ae.Core.input.register_action_set("loading");
    try ae.Core.input.install_action_set(set);
    loading_set = set;
    return set;
}

fn serverTask(
    alloc: std.mem.Allocator,
    scratch: std.mem.Allocator,
    seed: u64,
    io: std.Io,
    data_dir: std.Io.Dir,
    save_location: []const u8,
) void {
    // TODO: user pool (8 MiB) may need expansion once multiplayer clients join
    const selected_save = if (save_location.len > 0) save_location else Server.default_save_location;
    const config: Server.GameConfig = .{
        .embedded = .{
            .world = .{ .seed = seed, .save_location = selected_save },
        },
    };
    Server.init(alloc, scratch, io, data_dir, config) catch |err| {
        log.err("server init failed: {}", .{err});
        session_error = err;
        return;
    };
    World.saver.autosave_enabled = false;
    server_ready.store(true, .release);
}

fn connectTask(alloc: std.mem.Allocator, seed: u64, io: std.Io, data_dir: std.Io.Dir) void {
    connect_inner(alloc, seed, io, data_dir) catch |err| {
        log.err("multiplayer connect failed: {}", .{err});
        session_error = err;
        cleanup_failed_multiplayer_connect(io);
    };
    server_ready.store(true, .release);
}

fn cleanup_failed_multiplayer_connect(io: std.Io) void {
    Session.mp_connected.store(false, .release);

    // Close any partially-opened socket so GameState never tries to use it.
    if (Session.mp_stream) |*s| {
        s.close(io);
        Session.mp_stream = null;
    }

    // On PSP, MenuState's net dialog initialises sceNet before LoadState runs.
    // Normal disconnects unwind it in GameState.deinit; early load-screen
    // failures never reach GameState, so release it here.
    if (ae.platform == .psp) {
        pspsdk.extra.net.disconnect();
        pspsdk.extra.net.deinit();
    }
}

fn connect_inner(alloc: std.mem.Allocator, seed: u64, io: std.Io, data_dir: std.Io.Dir) !void {
    mp_server_name = @splat(' ');
    mp_server_motd = @splat(' ');

    const ep = try Session.parse_server_endpoint();
    switch (ep) {
        .ip => |a| log.info("connecting to {f}", .{a}),
        .host => |h| log.info("resolving {s}:{d}", .{ h.name, h.port }),
    }

    const stream = try Session.connect_endpoint(ep, io);
    Session.mp_stream = stream;
    Session.mp_reader = std.Io.net.Stream.Reader.init(stream, io, &Session.mp_read_buf);
    Session.mp_writer = std.Io.net.Stream.Writer.init(stream, io, &Session.mp_write_buf);
    const reader = &Session.mp_reader.interface;

    // PSP: disable Nagle so per-tick packets hit the wire immediately.
    if (ae.platform == .psp) {
        pspsdk.extra.net.disableNagle(@intCast(stream.socket.handle)) catch |err|
            log.warn("TCP_NODELAY failed: {}", .{err});
    }

    proto.send_player_id_to_server(&Session.mp_writer.interface, Session.username()) catch |err| {
        capture_disconnect_after_write_failed(reader);
        return err;
    };
    Session.mp_writer.interface.flush() catch |err| {
        capture_disconnect_after_write_failed(reader);
        return err;
    };

    // Multiplayer never persists (owned_locally stays false), so the
    // save filename is unused; pass the convention for symmetry.
    try World.init_empty(alloc, io, data_dir, "world.dat", seed, World.default_format);
    var world_owned_by_load = true;
    errdefer if (world_owned_by_load) World.deinit();

    // Accumulate the gzipped LevelDataChunk payloads into a scratch buffer,
    // then decompress once on LevelFinalize. A 2 MiB bound is comfortable
    // for any reasonable 4 MiB Classic world (typical compression ratio is
    // 4-8x) and keeps the peak the same size as `raw_blocks` itself.
    const compressed_cap: usize = 2 * 1024 * 1024;
    const compressed = try alloc.alloc(u8, compressed_cap);
    defer alloc.free(compressed);
    var compressed_end: usize = 0;

    done: while (true) {
        const packet_id = try reader.peekByte();
        const len = proto.packet_length_to_client(packet_id) catch |err| {
            log.err("handshake got unknown packet 0x{x:0>2}: {}", .{ packet_id, err });
            return err;
        };
        const buf = try reader.peek(len);
        switch (packet_id) {
            0x00 => {
                @memcpy(&mp_server_name, buf[2..66]);
                @memcpy(&mp_server_motd, buf[66..130]);
            },
            0x02 => {},
            0x03 => {
                // LevelDataChunk: [id][u16 length BE][1024 bytes data][u8 percent]
                const length = std.mem.readInt(u16, buf[1..3], .big);
                if (length > 1024) return error.InvalidChunkLength;
                if (compressed_end + length > compressed.len) return error.LevelDataOverflow;
                @memcpy(compressed[compressed_end..][0..length], buf[3 .. 3 + @as(usize, length)]);
                compressed_end += length;
                const percent = buf[1027];
                World.load_status = .{ .downloading = percent };
            },
            0x04 => {
                reader.toss(len);
                break :done;
            },
            0x0E => {
                capture_disconnect_reason(buf);
                return error.ServerDisconnected;
            },
            else => log.warn("unexpected packet 0x{x:0>2} during handshake", .{packet_id}),
        }
        reader.toss(len);
    }

    // Decompress the accumulated gzip stream. The server uses `.gzip` in
    // game/client.zig:reset_compressor, so match here. Wire format is
    // contiguous YZX (Java Classic compatible); scatter into chunk-aware layout.
    var src = std.Io.Reader.fixed(compressed[0..compressed_end]);
    const window_buf = try alloc.alloc(u8, flate.max_window_len);
    defer alloc.free(window_buf);
    var decompress = flate.Decompress.init(&src, .gzip, window_buf);

    decompress.reader.readSliceAll(World.data.raw_blocks[0..4]) catch |err| {
        log.err("level decompress header failed: {}", .{err});
        return err;
    };
    World.data.read_blocks_yzx(&decompress.reader) catch |err| {
        log.err("level decompress failed: {}", .{err});
        return err;
    };

    World.finalize_loaded();
    world_owned_by_load = false;
}

fn capture_disconnect_after_write_failed(reader: *std.Io.Reader) void {
    const err = Session.mp_writer.err orelse return;
    switch (err) {
        error.ConnectionResetByPeer, error.SocketUnconnected => capture_disconnect_packet(reader) catch {},
        else => {},
    }
}

fn capture_disconnect_packet(reader: *std.Io.Reader) !void {
    const packet_id = try reader.peekByte();
    if (packet_id != 0x0E) return error.NotDisconnectPacket;
    const len = try proto.packet_length_to_client(packet_id);
    const buf = try reader.peek(len);
    capture_disconnect_reason(buf);
    reader.toss(len);
}

fn capture_disconnect_reason(packet: []const u8) void {
    const reason = std.mem.trimEnd(u8, packet[1..65], " ");
    log.info("server disconnected during handshake: {s}", .{reason});
    Session.set_disconnect_reason(reason);
}

batcher: SpriteBatcher,
font_batcher: FontBatcher,
time: f32,
server_future: std.Io.Future(void),
server_notified: bool,
render_alloc: std.mem.Allocator,
/// True once `init` ran to completion. Guards `deinit` so a partially
/// initialised state never frees undefined fields.
inited: bool,

var game_state: GameState = undefined;
var state_inst: State = undefined;

// Keep the LoadState instance itself out of MenuState so the root app state
// stays small on PSP and other memory-constrained targets. Both the
// singleplayer and multiplayer entry points call `transition_here` to land
// in this state.
var load_state: @This() = undefined;
var load_state_inst: State = undefined;

pub fn transition_here(engine: *Engine) !void {
    load_state_inst = load_state.state();
    try ae.Core.state_machine.transition(engine, &load_state_inst);
}

fn init(ctx: *anyopaque, engine: *Engine) anyerror!void {
    var self = Util.ctx_to_self(@This(), ctx);
    self.inited = false;

    const set = try ensure_loading_set();
    try ae.Core.input.push_context(.{
        .name = "loading",
        .cursor_mode = .visible,
        .actions = set,
        .consumes_text = false,
    });

    const render_alloc = engine.allocator(.render);
    self.render_alloc = render_alloc;
    try ResourcePack.apply_tex_set(&.{ .dirt, .font });

    self.batcher = try SpriteBatcher.init(render_alloc);
    self.font_batcher = try FontBatcher.init(render_alloc, ResourcePack.get_tex(.font));
    self.time = 0;
    self.server_notified = false;

    const io = engine.io;
    const random_seed: u64 = @bitCast(@as(i64, @truncate(std.Io.Clock.Timestamp.now(io, .boot).raw.nanoseconds)));
    const singleplayer_seed = Session.singleplayer_seed(random_seed);
    server_ready.store(false, .monotonic);
    session_error = null;
    Session.clear_disconnect_reason();
    const data_dir = engine.dirs.data;
    // TODO: allocator pool budget may need tuning for server + client coexistence
    self.server_future = switch (Session.mode) {
        .singleplayer => io.async(serverTask, .{
            engine.allocator(.user),
            engine.allocator(.user),
            singleplayer_seed,
            io,
            data_dir,
            Session.singleplayer_save(),
        }),
        .multiplayer => io.async(connectTask, .{ engine.allocator(.user), random_seed, io, data_dir }),
    };

    self.inited = true;
    engine.report();
}

fn deinit(ctx: *anyopaque, engine: *Engine) void {
    var self = Util.ctx_to_self(@This(), ctx);
    if (!self.inited) return;
    self.server_future.await(engine.io);
    self.font_batcher.deinit();
    self.batcher.deinit();

    _ = ae.Core.input.pop_context() catch {};

    self.inited = false;
}

fn tick(ctx: *anyopaque, engine: *Engine) anyerror!void {
    var self = Util.ctx_to_self(@This(), ctx);
    if (!self.server_notified and server_ready.load(.acquire)) {
        self.server_notified = true;
        if (session_error) |err| {
            log.err("session start failed: {}", .{err});
            const reason: []const u8 = switch (Session.mode) {
                .singleplayer => "Failed to start server",
                .multiplayer => "Failed to connect to server",
            };
            Session.set_disconnect_reason_if_empty(reason);
            try DisconnectState.transition_here(engine);
            return;
        }
        state_inst = game_state.state();
        try ae.Core.state_machine.transition(engine, &state_inst);
    }
}

fn update(ctx: *anyopaque, _: *Engine, dt: f32, _: *const Util.BudgetContext) anyerror!void {
    var self = Util.ctx_to_self(@This(), ctx);
    self.time += dt;
}

fn draw(ctx: *anyopaque, engine: *Engine, _: f32, _: *const Util.BudgetContext) anyerror!void {
    var self = Util.ctx_to_self(@This(), ctx);

    const screen_w = Rendering.gfx.surface.get_width();
    const screen_h = Rendering.gfx.surface.get_height();
    const scale = Scaling.compute(screen_w, screen_h);
    const extent_x: i16 = @intCast((screen_w + scale - 1) / scale);
    const extent_y: i16 = @intCast((screen_h + scale - 1) / scale);

    self.batcher.clear();
    var y: i16 = 0;
    const tile_size = 32;
    if (DIAG_ONE_DIRT_QUAD_3DS) {
        add_dirt_tile(self, ResourcePack.get_tex(.dirt), 0, 0, tile_size);
    } else {
        while (y < extent_y) : (y += tile_size) {
            var x: i16 = 0;
            while (x < extent_x) : (x += tile_size) {
                const dirt = ResourcePack.get_tex(.dirt);
                add_dirt_tile(self, dirt, x, y, tile_size);
            }
        }
    }

    // Loading bar
    const bar_width: i16 = 100;
    const bar_height: i16 = 2;
    const bar_y: i16 = 16;
    const progress: f32 = switch (World.load_status) {
        .loading => @min(self.time / 3.0, 1.0),
        .generating => |phase| @as(f32, @floatFromInt(@intFromEnum(phase))) / 10.0,
        .downloading => |pct| @as(f32, @floatFromInt(pct)) / 100.0,
        .complete => 1.0,
    };
    const default_tex = &Rendering.Texture.Default;

    self.batcher.add_sprite(&.{
        .texture = default_tex,
        .pos_offset = .{ .x = 0, .y = bar_y },
        .pos_extent = .{ .x = bar_width, .y = bar_height },
        .tex_offset = .{ .x = 0, .y = 0 },
        .tex_extent = .{ .x = @intCast(default_tex.width), .y = @intCast(default_tex.height) },
        .color = .progress_bg,
        .layer = 1,
        .reference = .middle_center,
        .origin = .middle_center,
    });

    const progress_w: i16 = @intFromFloat(@as(f32, @floatFromInt(bar_width)) * progress);
    if (progress_w > 0) {
        self.batcher.add_sprite(&.{
            .texture = default_tex,
            .pos_offset = .{ .x = -@divTrunc(bar_width, 2), .y = bar_y },
            .pos_extent = .{ .x = progress_w, .y = bar_height },
            .tex_offset = .{ .x = 0, .y = 0 },
            .tex_extent = .{ .x = @intCast(default_tex.width), .y = @intCast(default_tex.height) },
            .color = .progress_bar,
            .layer = 2,
            .reference = .middle_center,
            .origin = .middle_left,
        });
    }

    try self.batcher.flush();

    self.font_batcher.clear();

    const load_status = World.load_status;
    const loading: []const u8 = blk: {
        if (Session.mode == .multiplayer) {
            const trimmed = std.mem.trimEnd(u8, &mp_server_name, " ");
            if (trimmed.len > 0) break :blk trimmed;
            break :blk "Connecting to server";
        }
        break :blk switch (load_status) {
            .loading => "Loading level",
            .generating, .complete => "Generating level",
            .downloading => "Downloading level",
        };
    };
    self.font_batcher.add_text(&.{
        .str = loading,
        .pos_x = 0,
        .pos_y = -16,
        .color = .white_fg,
        .shadow_color = .menu_gray,
        .spacing = 0,
        .layer = 2,
        .reference = .middle_center,
        .origin = .middle_center,
    });

    const status: []const u8 = blk: {
        if (Session.mode == .multiplayer) {
            const trimmed = std.mem.trimEnd(u8, &mp_server_motd, " ");
            if (trimmed.len > 0) break :blk trimmed;
            break :blk "Handshaking...";
        }
        break :blk switch (load_status) {
            .loading => "Loading...",
            .generating => |phase| switch (phase) {
                .raising => "Raising...",
                .erosion => "Eroding...",
                .strata => "Layering...",
                .caves => "Carving...",
                .ores => "Placing ores...",
                .merge => "Merging...",
                .water => "Flooding water...",
                .lava => "Flooding lava...",
                .surface => "Surfacing...",
                .plants => "Planting...",
            },
            .downloading => "Receiving chunks...",
            .complete => "Done!",
        };
    };
    self.font_batcher.add_text(&.{
        .str = status,
        .pos_x = 0,
        .pos_y = 7,
        .color = .white_fg,
        .shadow_color = .menu_gray,
        .spacing = 0,
        .layer = 2,
        .reference = .middle_center,
        .origin = .middle_center,
    });

    try self.font_batcher.flush();
    // Throttle to ~20 FPS while server generates on background thread;
    // avoids burning CPU on draw calls that show a static progress bar.
    try std.Io.sleep(engine.io, common_time.ms(50), .real);
}

fn add_dirt_tile(self: *@This(), dirt: *const Rendering.Texture, x: i16, y: i16, tile_size: i16) void {
    self.batcher.add_sprite(&.{
        .texture = dirt,
        .pos_offset = .{ .x = x, .y = y },
        .pos_extent = .{ .x = tile_size, .y = tile_size },
        .tex_offset = .{ .x = 0, .y = 0 },
        .tex_extent = .{ .x = @intCast(dirt.width), .y = @intCast(dirt.height) },
        .color = .menu_tiles,
        .layer = 0,
    });
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
