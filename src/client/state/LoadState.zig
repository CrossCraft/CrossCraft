const std = @import("std");
const ae = @import("aether");
const Core = ae.Core;
const Util = ae.Util;
const Rendering = ae.Rendering;
const State = Core.State;

const SpriteBatcher = @import("../ui/SpriteBatcher.zig");
const FontBatcher = @import("../ui/FontBatcher.zig");
const Scaling = @import("../ui/Scaling.zig");
const Vertex = @import("../graphics/Vertex.zig").Vertex;
const Zip = @import("../util/Zip.zig");
const Server = @import("game").Server;
const World = @import("game").World;
const GameState = @import("GameState.zig");
const Session = @import("Session.zig");
const proto = @import("common").protocol;
const flate = std.compress.flate;

const pspsdk = if (ae.platform == .psp) @import("pspsdk") else void;

const log = std.log.scoped(.game);

// Module-level: only one LoadState instance may exist at a time.
var server_ready: std.atomic.Value(bool) = .init(false);
var session_error: ?anyerror = null;

fn serverTask(alloc: std.mem.Allocator, scratch: std.mem.Allocator, seed: u64, io: std.Io) void {
    // TODO: user pool (8 MiB) may need expansion once multiplayer clients join
    Server.init(alloc, scratch, seed, io) catch |err| {
        log.err("server init failed: {}", .{err});
        session_error = err;
        return;
    };
    server_ready.store(true, .release);
}

fn connectTask(alloc: std.mem.Allocator, seed: u64, io: std.Io) void {
    connect_inner(alloc, seed, io) catch |err| {
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

fn connect_inner(alloc: std.mem.Allocator, seed: u64, io: std.Io) !void {
    const addr = try Session.parse_server_address();
    log.info("connecting to {f}", .{addr});

    const stream = try addr.connect(io, .{ .mode = .stream });
    Session.mp_stream = stream;
    Session.mp_reader = std.Io.net.Stream.Reader.init(stream, io, &Session.mp_read_buf);
    Session.mp_writer = std.Io.net.Stream.Writer.init(stream, io, &Session.mp_write_buf);

    // PSP: disable Nagle so per-tick packets hit the wire immediately.
    // Safe because GameState.init drops main thread priority below
    // sceNet's callout (42), so the callout actually drains segments.
    if (ae.platform == .psp) {
        const TCP_NODELAY: i32 = 1;
        const one: c_int = 1;
        pspsdk.net.inet_setsockopt(
            @intCast(stream.socket.handle),
            pspsdk.extra.net.IPPROTO_TCP,
            TCP_NODELAY,
            &one,
            @sizeOf(c_int),
        ) catch |err| log.warn("TCP_NODELAY setsockopt failed: {}", .{err});
    }

    try World.init_empty(alloc, io, seed);

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
            0x00 => {},
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

    // Decompress the accumulated gzip stream into raw_blocks. The server
    // uses `.gzip` in game/client.zig:reset_compressor, so match here.
    var src = std.Io.Reader.fixed(compressed[0..compressed_end]);
    var window_buf: [flate.max_window_len]u8 = undefined;
    var decompress = flate.Decompress.init(&src, .gzip, &window_buf);

    var dst = std.Io.Writer.fixed(World.raw_blocks);
    _ = decompress.reader.streamRemaining(&dst) catch |err| {
        log.err("level decompress failed: {}", .{err});
        return err;
    };
    if (dst.end != World.raw_blocks.len) {
        log.err("level data truncated: got {d}, expected {d}", .{ dst.end, World.raw_blocks.len });
        return error.TruncatedLevelData;
    }

    World.finalize_loaded();
}

const LoadTextures = struct {
    dirt: Rendering.Texture,
    font: Rendering.Texture,

    /// Valid between LoadTextures.init() and LoadTextures.deinit().
    var inst: LoadTextures = undefined;

    fn load_from_pack(pack: *Zip, file: []const u8) !Rendering.Texture {
        var buf: [256]u8 = undefined;
        const path = try std.fmt.bufPrint(&buf, "assets/{s}.png", .{file});

        var stream = try pack.open(path);
        defer pack.closeStream(&stream);

        return try Rendering.Texture.load_from_reader(stream.reader);
    }

    pub fn init(pack: *Zip) !void {
        inst.dirt = try load_from_pack(pack, "minecraft/textures/dirt");
        inst.font = try load_from_pack(pack, "minecraft/textures/default");
    }

    pub fn deinit() void {
        inst.font.deinit();
        inst.dirt.deinit();
    }
};

pack: *Zip,
batcher: SpriteBatcher,
font_batcher: FontBatcher,
time: f32,
server_future: std.Io.Future(void),
server_notified: bool,

var pipeline: Rendering.Pipeline.Handle = undefined;
var game_state: GameState = undefined;
var state_inst: State = undefined;

// Keep the LoadState instance itself out of MenuState so the root app state
// stays small on PSP and other memory-constrained targets. Both the
// singleplayer and multiplayer entry points call `transition_here` to land
// in this state.
var load_state: @This() = undefined;
var load_state_inst: State = undefined;

pub fn transition_here() !void {
    load_state_inst = load_state.state();
    try ae.Core.state_machine.transition(&load_state_inst);
}

fn init(ctx: *anyopaque) anyerror!void {
    var self = Util.ctx_to_self(@This(), ctx);
    const vert align(@alignOf(u32)) = @embedFile("basic_vert").*;
    const frag align(@alignOf(u32)) = @embedFile("basic_frag").*;
    pipeline = try Rendering.Pipeline.new(Vertex.Layout, &vert, &frag);

    self.pack = try Zip.init(Util.allocator(.game), Util.io(), "pack.zip");
    try LoadTextures.init(self.pack);

    self.batcher = try SpriteBatcher.init(pipeline);
    self.font_batcher = try FontBatcher.init(pipeline, &LoadTextures.inst.font);
    self.time = 0;
    self.server_notified = false;

    const io = Util.io();
    const seed: u64 = @bitCast(@as(i64, @truncate(std.Io.Clock.Timestamp.now(io, .boot).raw.nanoseconds)));
    server_ready.store(false, .monotonic);
    session_error = null;
    // TODO: allocator pool budget may need tuning for server + client coexistence
    self.server_future = switch (Session.mode) {
        .singleplayer => io.async(serverTask, .{ Util.allocator(.user), Util.allocator(.user), seed, io }),
        .multiplayer => io.async(connectTask, .{ Util.allocator(.user), seed, io }),
    };

    Util.report();
}

fn deinit(ctx: *anyopaque) void {
    var self = Util.ctx_to_self(@This(), ctx);
    self.server_future.await(Util.io());
    self.font_batcher.deinit();
    self.batcher.deinit();

    LoadTextures.deinit();
    self.pack.deinit();
    Rendering.Pipeline.deinit(pipeline);
}

fn tick(ctx: *anyopaque) anyerror!void {
    var self = Util.ctx_to_self(@This(), ctx);
    if (!self.server_notified and server_ready.load(.acquire)) {
        self.server_notified = true;
        if (session_error) |err| {
            // Treat load-phase failure the same as a disconnect: log and
            // quit the process. We don't have a dedicated error screen yet.
            log.err("session start failed: {}, quitting", .{err});
            return err;
        }
        state_inst = game_state.state();
        try ae.Core.state_machine.transition(&state_inst);
    }
}

fn update(ctx: *anyopaque, dt: f32, _: *const Util.BudgetContext) anyerror!void {
    var self = Util.ctx_to_self(@This(), ctx);
    self.time += dt;
}

fn draw(ctx: *anyopaque, _: f32, _: *const Util.BudgetContext) anyerror!void {
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
            const dirt = &LoadTextures.inst.dirt;
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
    const loading: []const u8 = switch (load_status) {
        .loading => if (Session.mode == .multiplayer) "Connecting to server" else "Loading level",
        .generating, .complete => "Generating level",
        .downloading => "Downloading level",
    };
    self.font_batcher.add_text(&.{
        .str = loading,
        .pos_x = 0,
        .pos_y = -16,
        .color = .white,
        .shadow_color = .menu_gray,
        .spacing = 0,
        .layer = 2,
        .reference = .middle_center,
        .origin = .middle_center,
    });

    const status: []const u8 = switch (load_status) {
        .loading => if (Session.mode == .multiplayer) "Handshaking..." else "Loading...",
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
    self.font_batcher.add_text(&.{
        .str = status,
        .pos_x = 0,
        .pos_y = 7,
        .color = .white,
        .shadow_color = .menu_gray,
        .spacing = 0,
        .layer = 2,
        .reference = .middle_center,
        .origin = .middle_center,
    });

    try self.font_batcher.flush();
    // Throttle to ~20 FPS while server generates on background thread;
    // avoids burning CPU on draw calls that show a static progress bar.
    try std.Io.sleep(Util.io(), std.Io.Duration.fromMilliseconds(50), .real);
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
