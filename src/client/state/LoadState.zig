const std = @import("std");
const assert = std.debug.assert;
const ae = @import("aether");
const Core = ae.Core;
const Util = ae.Util;
const Engine = ae.Engine;
const Rendering = ae.Rendering;
const State = Core.State;

const SpriteBatcher = ae.Ui.SpriteBatcher;
const FontBatcher = ae.Ui.FontBatcher;
const Colors = @import("../graphics/Color.zig");
const ResourcePack = @import("../ResourcePack.zig");
const Screen = @import("../ui/Screen.zig");
const core = @import("core");
const Server = core.Server;
const World = core.World;
const GameState = @import("GameState.zig");
const DisconnectState = @import("DisconnectState.zig");
const Session = @import("Session.zig");
const proto = core.protocol;
const flate = std.compress.flate;

const caps = @import("capabilities").ClientType(ae);

const log = std.log.scoped(.game);

// Level dimensions arrive after the compressed stream, so the client must
// buffer it whole. PSP and 3DS cannot hold the maximum level beside the world.
const max_compressed_bytes: usize = core.world_dims.max_length *
    core.world_dims.max_height * core.world_dims.max_depth + 64 * 1024;

var server_ready: std.atomic.Value(bool) = .init(false);
var session_error: ?anyerror = null;
var mp_server_name: [64]u8 = @splat(' ');
var mp_server_motd: [64]u8 = @splat(' ');

var loading_set: ?ae.Core.input.ActionSetHandle = null;

// Embedded in the static load state: both the job and its inputs stay at a
// stable address until deinit joins the executor, even when server_ready is
// observed before Aether has published the job's own completion.
const LoadTask = struct {
    allocator: std.mem.Allocator,
    scratch: std.mem.Allocator,
    io: std.Io,
    seed: u64,
    data_dir: std.Io.Dir,
    save_location: []const u8,
    executor: ?*ae.Jobs.Executor = null,
    job: ae.Jobs.Job = .{ .context = undefined, .run = undefined },

    fn start(self: *LoadTask, callback: *const fn (*anyopaque) anyerror!void, options: ae.Jobs.Options) !void {
        assert(self.executor == null);
        self.job = .{ .context = self, .run = callback };
        self.executor = try ae.Jobs.Executor.init(self.allocator, self.io, options);
        errdefer self.join();

        try self.executor.?.submit(&self.job);
    }

    fn join(self: *LoadTask) void {
        if (self.executor) |executor| executor.deinit();
        self.executor = null;
    }

    fn run_server(context: *anyopaque) !void {
        const self: *LoadTask = @ptrCast(@alignCast(context));
        run_server_task(self.allocator, self.scratch, self.io, self.seed, self.data_dir, self.save_location);
    }

    fn run_connect(context: *anyopaque) !void {
        const self: *LoadTask = @ptrCast(@alignCast(context));
        connect_task(self.allocator, self.io, self.seed, self.data_dir);
    }
};

fn start_server_task(task: *LoadTask) void {
    // Auto runs synchronously on browser targets without background workers.
    task.start(LoadTask.run_server, .{ .capacity = 1, .thread = .{
        .name = "load_server",
        .stack_size = 1024 * 1024,
        .priority = .normal,
    } }) catch |err| {
        log.err("server task unavailable: {}", .{err});
        session_error = err;
        server_ready.store(true, .release);
    };
}

fn start_connect_task(task: *LoadTask) void {
    if (comptime !caps.networking.multiplayer) {
        session_error = error.UnsupportedPlatform;
        server_ready.store(true, .release);
        return;
    }

    task.start(LoadTask.run_connect, .{ .capacity = 1, .thread = .{
        .name = "mp_connect",
        .stack_size = 512 * 1024,
        .priority = .normal,
    } }) catch |err| {
        log.err("connect task unavailable: {}", .{err});
        session_error = err;
        server_ready.store(true, .release);
    };
}

fn ensure_loading_set(engine: *Engine) !ae.Core.input.ActionSetHandle {
    if (loading_set) |h| return h;
    const set = try engine.input.register_action_set("loading");
    try engine.input.install_action_set(set);
    loading_set = set;
    return set;
}

fn run_server_task(
    alloc: std.mem.Allocator,
    scratch: std.mem.Allocator,
    io: std.Io,
    seed: u64,
    data_dir: std.Io.Dir,
    save_location: []const u8,
) void {
    // The embedded server allocates the world and worldgen scratch from the
    // user pool under the init_user budget (sized in config.zig).
    // TODO(world-streaming): PSP & 3DS hold that budget at 12 MiB, so
    // geometries needing more fail here with OutOfMemory.
    const selected_save = if (save_location.len > 0) save_location else Server.default_save_location;
    const config: Server.GameConfig = .{
        .embedded = .{
            .world = .{
                .seed = seed,
                .save_location = selected_save,
                .size = Session.singleplayer_size orelse .normal,
                .height = Session.singleplayer_height orelse .normal,
            },
        },
    };
    Server.init(alloc, scratch, io, data_dir, config) catch |err| {
        log.err("server init failed: {}", .{err});
        session_error = err;
        server_ready.store(true, .release);
        return;
    };
    server_ready.store(true, .release);
}

fn connect_task(alloc: std.mem.Allocator, io: std.Io, seed: u64, data_dir: std.Io.Dir) void {
    connect_inner(alloc, seed, io, data_dir) catch |err| {
        log.err("multiplayer connect failed: {}", .{err});
        session_error = err;
        cleanup_failed_multiplayer_connect(io);
    };
    server_ready.store(true, .release);
}

fn cleanup_failed_multiplayer_connect(io: std.Io) void {
    Session.mp_connected.store(false, .release);

    if (Session.mp_stream) |*s| {
        s.close(io);
        Session.mp_stream = null;
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
    caps.networking.configure_stream(stream);

    proto.send_player_id_to_server(&Session.mp_writer.interface, Session.username()) catch |err| {
        capture_disconnect_after_write_failed(reader);
        return err;
    };
    Session.mp_writer.interface.flush() catch |err| {
        capture_disconnect_after_write_failed(reader);
        return err;
    };

    var compressed: std.ArrayList(u8) = .empty;
    defer compressed.deinit(alloc);

    var announced: ?World.WorldDims = null;

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
                if (compressed.items.len + length > max_compressed_bytes) return error.LevelDataOverflow;
                try compressed.appendSlice(alloc, buf[3 .. 3 + @as(usize, length)]);
                const percent = buf[1027];
                World.set_load_status(.{ .downloading = percent });
            },
            0x04 => {
                // LevelFinalize: [id][x][y][z], each u16 big-endian.
                announced = World.WorldDims.from_array(.{
                    std.mem.readInt(u16, buf[1..3], .big),
                    std.mem.readInt(u16, buf[3..5], .big),
                    std.mem.readInt(u16, buf[5..7], .big),
                }) orelse {
                    log.err("server offers a world size this build cannot represent", .{});
                    return error.UnsupportedServerWorldSize;
                };
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

    const dims = announced orelse return error.MissingLevelFinalize;

    // The server sends gzip-compressed, Java Classic-compatible YZX data.
    var src = std.Io.Reader.fixed(compressed.items);
    const window_buf = try alloc.alloc(u8, flate.max_window_len);
    defer alloc.free(window_buf);

    var decompress = flate.Decompress.init(&src, .gzip, window_buf);

    // The stream opens with the raw level size. Trusting it only as a check:
    // the announced geometry is what the world is sized from, and a mismatch
    // means the level would not fit.
    var wire_header: [4]u8 = undefined;
    decompress.reader.readSliceAll(&wire_header) catch |err| {
        log.err("level decompress header failed: {}", .{err});
        return err;
    };
    const raw_volume: usize = std.mem.readInt(u32, &wire_header, .big);
    if (raw_volume != dims.volume()) {
        log.err("server level is {d} blocks, which is not {}x{}x{}", .{
            raw_volume, dims.length, dims.height, dims.depth,
        });
        return error.UnsupportedServerWorldSize;
    }

    // Multiplayer never persists (owned_locally stays false), so the
    // save filename is unused; pass the convention for symmetry.
    try World.init_empty(alloc, io, data_dir, "world.dat", dims, seed, World.default_format);
    var world_owned_by_load = true;
    errdefer if (world_owned_by_load) World.deinit();

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
server_task: LoadTask,
server_notified: bool,
render_alloc: std.mem.Allocator,
inited: bool,

var game_state: GameState = undefined;
var state_inst: State = undefined;

// Keep the large state outside MenuState for memory-constrained targets.
var load_state: @This() = undefined;
var load_state_inst: State = undefined;

pub fn transition_here(engine: *Engine) void {
    load_state_inst = load_state.state();
    engine.transition(&load_state_inst);
}

fn init(ctx: *anyopaque, engine: *Engine) anyerror!void {
    var self = Util.ctx_to_self(@This(), ctx);
    self.inited = false;

    const set = try ensure_loading_set(engine);
    try engine.input.push_context(&.{
        .name = "loading",
        .cursor_mode = .visible,
        .actions = set,
        .consumes_text = false,
    });

    const render_alloc = engine.allocator(.render);
    self.render_alloc = render_alloc;
    try ResourcePack.apply_tex_set(&.{ .dirt, .font });

    self.batcher = try SpriteBatcher.init(render_alloc);
    self.font_batcher = try @import("../ui/TextFormat.zig").init_font(render_alloc, ResourcePack.get_tex(.font));
    self.time = 0;
    self.server_notified = false;

    const io = engine.io;
    const random_seed: u64 = @bitCast(@as(i64, @truncate(std.Io.Clock.Timestamp.now(io, .boot).raw.nanoseconds)));
    const singleplayer_seed = Session.singleplayer_seed_override orelse random_seed;
    server_ready.store(false, .monotonic);
    session_error = null;
    Session.clear_disconnect_reason();
    const data_dir = engine.dirs.data;
    const server_scratch = if (comptime caps.memory.separate_worldgen_scratch)
        std.heap.wasm_allocator
    else
        engine.allocator(.user);
    self.server_task = .{
        .allocator = engine.allocator(.user),
        .scratch = server_scratch,
        .io = io,
        .seed = if (Session.mode == .singleplayer) singleplayer_seed else random_seed,
        .data_dir = data_dir,
        .save_location = Session.singleplayer_save(),
    };
    switch (Session.mode) {
        .singleplayer => start_server_task(&self.server_task),
        .multiplayer => start_connect_task(&self.server_task),
    }

    self.inited = true;
    engine.report();
}

fn deinit(ctx: *anyopaque, engine: *Engine) void {
    var self = Util.ctx_to_self(@This(), ctx);
    if (!self.inited) return;
    self.server_task.join();
    if (Session.mode == .multiplayer and session_error != null) caps.networking.release();
    self.font_batcher.deinit();
    self.batcher.deinit();

    _ = engine.input.pop_context() catch {};

    self.inited = false;
}

fn tick(ctx: *anyopaque, engine: *Engine) anyerror!void {
    var self = Util.ctx_to_self(@This(), ctx);
    if (!self.server_notified and server_ready.load(.acquire)) {
        self.server_notified = true;
        if (session_error) |err| {
            log.err("session start failed: {}", .{err});
            var reason_buf: [64]u8 = undefined;
            const reason: []const u8 = switch (Session.mode) {
                .singleplayer => std.fmt.bufPrint(&reason_buf, "Failed to start server: {s}", .{@errorName(err)}) catch "Failed to start server",
                .multiplayer => std.fmt.bufPrint(&reason_buf, "Failed to connect: {s}", .{@errorName(err)}) catch "Failed to connect to server",
            };
            Session.set_disconnect_reason_if_empty(reason);
            DisconnectState.transition_here(engine);
            return;
        }
        state_inst = game_state.state();
        engine.transition(&state_inst);
    }
}

fn update(ctx: *anyopaque, _: *Engine, dt: f32, _: *const Util.BudgetContext) anyerror!void {
    var self = Util.ctx_to_self(@This(), ctx);
    self.time += dt;
    try prepare_batches(self);
}

fn prepare_batches(self: *@This()) !void {
    self.batcher.clear();
    Screen.add_dirt_background(&self.batcher, ResourcePack.get_tex(.dirt));

    const bar_width: i16 = 100;
    const bar_height: i16 = 2;
    const bar_y: i16 = 16;
    const load_status = World.get_load_status();
    const progress: f32 = switch (load_status) {
        .loading => @min(self.time / 3.0, 1.0),
        .generating => @min(self.time / 3.0, 1.0),
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
        .color = Colors.progress_bg,
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
            .color = Colors.progress_bar,
            .layer = 2,
            .reference = .middle_center,
            .origin = .middle_left,
        });
    }

    try self.batcher.update();

    self.font_batcher.clear();

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
        .color = Colors.white_fg,
        .shadow_color = Colors.menu_gray,
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
            .generating => "Generating level...",
            .downloading => "Receiving chunks...",
            .complete => "Done!",
        };
    };
    self.font_batcher.add_text(&.{
        .str = status,
        .pos_x = 0,
        .pos_y = 7,
        .color = Colors.white_fg,
        .shadow_color = Colors.menu_gray,
        .spacing = 0,
        .layer = 2,
        .reference = .middle_center,
        .origin = .middle_center,
    });

    try self.font_batcher.update();
}

fn draw(ctx: *anyopaque, engine: *Engine, _: f32, _: *const Util.BudgetContext) anyerror!void {
    var self = Util.ctx_to_self(@This(), ctx);

    self.batcher.draw();
    self.font_batcher.draw();

    // Throttle to ~20 FPS while server generates on background thread;
    // avoids burning CPU on draw calls that show a static progress bar.
    // 3DS already blocks on vblank after draw; sleeping here delays the
    // present itself and can let the worker finish before any phase frame
    // reaches the screen.
    if (!caps.render.present_paces_loading) {
        try std.Io.sleep(engine.io, .fromMilliseconds(50), .real);
    }
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

test "load job runs inline and releases allocations on admission failure" {
    const Probe = struct {
        fn run(context: *anyopaque) !void {
            const task: *LoadTask = @ptrCast(@alignCast(context));
            task.seed += 1;
        }

        fn check(allocator: std.mem.Allocator) !void {
            var task: LoadTask = .{
                .allocator = allocator,
                .scratch = allocator,
                .io = std.testing.io,
                .seed = 7,
                .data_dir = .cwd(),
                .save_location = "",
            };
            defer task.join();

            try task.start(run, .{ .capacity = 1, .mode = .inline_execution });
            try task.job.result();
            try std.testing.expectEqual(@as(u64, 8), task.seed);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Probe.check, .{});
}

test "load job joins after session readiness before releasing task context" {
    if (!ae.System.info().background_workers) return error.SkipZigTest;
    const Probe = struct {
        task: LoadTask,
        gate: std.Io.Mutex = .init,

        fn run(context: *anyopaque) !void {
            const task: *LoadTask = @ptrCast(@alignCast(context));
            const self: *@This() = @fieldParentPtr("task", task);
            session_error = error.ForcedFailure;
            server_ready.store(true, .release);
            // The state can see readiness while Aether still borrows the job.
            self.gate.lockUncancelable(task.io);
            defer self.gate.unlock(task.io);

            task.seed = 42;
        }
    };
    var probe: Probe = .{ .task = .{
        .allocator = std.testing.allocator,
        .scratch = std.testing.allocator,
        .io = std.testing.io,
        .seed = 7,
        .data_dir = .cwd(),
        .save_location = "",
    } };
    server_ready.store(false, .monotonic);
    session_error = null;
    defer {
        server_ready.store(false, .monotonic);
        session_error = null;
    }

    probe.gate.lockUncancelable(std.testing.io);
    var gate_locked = true;
    defer {
        if (gate_locked) probe.gate.unlock(std.testing.io);
        probe.task.join();
    }

    try probe.task.start(Probe.run, .{ .capacity = 1, .mode = .threaded });
    while (!server_ready.load(.acquire)) try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .real);
    try std.testing.expectEqual(error.ForcedFailure, session_error.?);
    try std.testing.expect(!probe.task.job.is_done());
    probe.gate.unlock(std.testing.io);
    gate_locked = false;
    probe.task.join();
    try probe.task.job.result();
    try std.testing.expectEqual(@as(u64, 42), probe.task.seed);
}
