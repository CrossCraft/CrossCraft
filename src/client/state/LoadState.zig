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
const Vertex = @import("../graphics/Vertex.zig").Vertex;
const ResourcePack = @import("../ResourcePack.zig");
const Server = @import("game").Server;
const World = @import("game").World;
const GameState = @import("GameState.zig");
const DisconnectState = @import("DisconnectState.zig");
const Session = @import("Session.zig");
const proto = @import("common").protocol;
const flate = std.compress.flate;

const pspsdk = if (ae.platform == .psp) @import("pspsdk") else void;

const log = std.log.scoped(.game);

// Module-level: only one LoadState instance may exist at a time.
var server_ready: std.atomic.Value(bool) = .init(false);
var session_error: ?anyerror = null;
var mp_server_name: [64]u8 = @splat(' ');
var mp_server_motd: [64]u8 = @splat(' ');

fn serverTask(alloc: std.mem.Allocator, scratch: std.mem.Allocator, seed: u64, io: std.Io, data_dir: std.Io.Dir) void {
    // TODO: user pool (8 MiB) may need expansion once multiplayer clients join
    Server.init(alloc, scratch, seed, io, data_dir) catch |err| {
        log.err("server init failed: {}", .{err});
        session_error = err;
        return;
    };
    server_ready.store(true, .release);
}

fn connectTask(alloc: std.mem.Allocator, seed: u64, io: std.Io, data_dir: std.Io.Dir) void {
    connect_inner(alloc, seed, io, data_dir) catch |err| {
        log.err("multiplayer connect failed: {}", .{err});
        session_error = err;
        // Close any partially-opened socket so GameState never tries to use it.
        if (Session.mp_stream) |*s| {
            s.close(io);
            Session.mp_stream = null;
        }
    };
    server_ready.store(true, .release);
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

    // PSP: disable Nagle so per-tick packets hit the wire immediately.
    if (ae.platform == .psp) {
        pspsdk.extra.net.disableNagle(@intCast(stream.socket.handle)) catch |err|
            log.warn("TCP_NODELAY failed: {}", .{err});
    }

    try World.init_empty(alloc, io, data_dir, seed);

    try proto.send_player_id_to_server(&Session.mp_writer.interface, Session.username());
    try Session.mp_writer.interface.flush();

    // Accumulate the gzipped LevelDataChunk payloads into a scratch buffer,
    // then decompress once on LevelFinalize. A 2 MiB bound is comfortable
    // for any reasonable 4 MiB Classic world (typical compression ratio is
    // 4-8x) and keeps the peak the same size as `raw_blocks` itself.
    const compressed_cap: usize = 2 * 1024 * 1024;
    const compressed = try alloc.alloc(u8, compressed_cap);
    defer alloc.free(compressed);
    var compressed_end: usize = 0;

    const reader = &Session.mp_reader.interface;

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
            else => log.warn("unexpected packet 0x{x:0>2} during handshake", .{packet_id}),
        }
        reader.toss(len);
    }

    // Decompress the accumulated gzip stream. The server uses `.gzip` in
    // game/client.zig:reset_compressor, so match here. Wire format is
    // contiguous YZX (Java Classic compatible); scatter into chunk-aware layout.
    var src = std.Io.Reader.fixed(compressed[0..compressed_end]);
    var window_buf: [flate.max_window_len]u8 = undefined;
    var decompress = flate.Decompress.init(&src, .gzip, &window_buf);

    decompress.reader.readSliceAll(World.raw_blocks[0..4]) catch |err| {
        log.err("level decompress header failed: {}", .{err});
        return err;
    };
    World.read_blocks_yzx(&decompress.reader) catch |err| {
        log.err("level decompress failed: {}", .{err});
        return err;
    };

    World.finalize_loaded();
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

var pipeline: Rendering.Pipeline.Handle = undefined;
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
    const vert align(@alignOf(u32)) = @embedFile("basic_vert").*;
    const frag align(@alignOf(u32)) = @embedFile("basic_frag").*;
    pipeline = try Rendering.Pipeline.new(Vertex.Layout, &vert, &frag);

    const render_alloc = engine.allocator(.render);
    self.render_alloc = render_alloc;
    try ResourcePack.apply_tex_set(&.{ .dirt, .font });

    self.batcher = try SpriteBatcher.init(render_alloc, pipeline);
    self.font_batcher = try FontBatcher.init(render_alloc, pipeline, ResourcePack.get_tex(.font));
    self.time = 0;
    self.server_notified = false;

    const io = engine.io;
    const seed: u64 = @bitCast(@as(i64, @truncate(std.Io.Clock.Timestamp.now(io, .boot).raw.nanoseconds)));
    server_ready.store(false, .monotonic);
    session_error = null;
    // TODO: allocator pool budget may need tuning for server + client coexistence
    self.server_future = switch (Session.mode) {
        .singleplayer => io.async(serverTask, .{ engine.allocator(.user), engine.allocator(.user), seed, io, engine.dirs.data }),
        .multiplayer => io.async(connectTask, .{ engine.allocator(.user), seed, io, engine.dirs.data }),
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

    Rendering.Pipeline.deinit(pipeline);
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
            Session.set_disconnect_reason(reason);
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
    while (y < extent_y) : (y += tile_size) {
        var x: i16 = 0;
        while (x < extent_x) : (x += tile_size) {
            const dirt = ResourcePack.get_tex(.dirt);
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
    try std.Io.sleep(engine.io, std.Io.Duration.fromMilliseconds(50), .real);
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
