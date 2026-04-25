const std = @import("std");
const builtin = @import("builtin");
const ae = @import("aether");
const game = @import("game");
const common = @import("common");

const Util = ae.Util;
const Engine = ae.Engine;
const State = ae.Core.State;

const Server = game.Server;
const Consts = common.consts;

const log = std.log.scoped(.server);
const sdk = if (ae.platform == .psp) @import("pspsdk") else void;

const ConnectionData = struct {
    stream: std.Io.net.Stream,
    reader: std.Io.net.Stream.Reader,
    writer: std.Io.net.Stream.Writer,
    read_buffer: [4096]u8,
    write_buffer: [4096]u8,
    connected: bool,
};

// Signal handlers run with C calling conventions and cannot carry
// context, so the engine and listener pointers live at module scope.
// `init` populates them; `deinit` clears them.
var global_engine: ?*Engine = null;
var global_listener: ?*std.Io.net.Server = null;

const Self = @This();

conn_handles: []?ConnectionData,
tasks: std.Io.Group,
listener: std.Io.net.Server,

pub fn state(self: *Self) State {
    return .{ .ptr = self, .tab = &.{
        .init = init,
        .deinit = deinit,
        .tick = tick,
        .update = update,
        .draw = draw,
    } };
}

fn init(ctx: *anyopaque, engine: *Engine) anyerror!void {
    var self = Util.ctx_to_self(Self, ctx);

    const alloc = engine.allocator(.game);

    self.conn_handles = try alloc.alloc(?ConnectionData, Consts.MAX_PLAYERS);
    @memset(self.conn_handles, null);

    self.tasks = .init;

    const seed: u64 = @bitCast(@as(i64, @truncate(std.Io.Clock.Timestamp.now(engine.io, .boot).raw.nanoseconds)));
    try Server.init(alloc, alloc, seed, engine.io, engine.dirs.data, false);

    engine.report();

    global_engine = engine;
    install_signal_handlers();

    log.info("Starting server on port 25565", .{});

    const server_ip = try std.Io.net.IpAddress.parseIp4("0.0.0.0", 25565);
    // SO_REUSEADDR so a fresh server can rebind immediately after a client
    // disconnects - otherwise the listening socket sits in TIME_WAIT for
    // up to a minute and the next `zig build run-server` hits AddressInUse.
    self.listener = try server_ip.listen(engine.io, .{ .reuse_address = true });
    global_listener = &self.listener;

    self.tasks.concurrent(engine.io, accept_loop, .{ self, engine }) catch unreachable;
}

fn tick(ctx: *anyopaque, engine: *Engine) anyerror!void {
    var self = Util.ctx_to_self(Self, ctx);

    Server.tick();

    for (0..Consts.MAX_PLAYERS) |i| {
        if (self.conn_handles[i]) |*data| {
            if (!data.connected) {
                log.info("Connection in slot {d} disconnected", .{i});
                data.stream.close(engine.io);
                self.conn_handles[i] = null;
            }
        }
    }
}

fn update(_: *anyopaque, _: *Engine, _: f32, _: *const Util.BudgetContext) anyerror!void {}
fn draw(_: *anyopaque, _: *Engine, _: f32, _: *const Util.BudgetContext) anyerror!void {}

fn deinit(ctx: *anyopaque, engine: *Engine) void {
    var self = Util.ctx_to_self(Self, ctx);

    self.tasks.cancel(engine.io);
    log.info("Shutting down server...", .{});

    global_listener = null;
    self.listener.deinit(engine.io);

    Server.deinit();

    engine.allocator(.game).free(self.conn_handles);

    global_engine = null;
}

fn client_read_loop(client: *Server.Client) std.Io.Cancelable!void {
    client.read_loop();
}

fn accept_loop(self: *Self, engine: *Engine) std.Io.Cancelable!void {
    while (engine.running) {
        var conn = self.listener.accept(engine.io) catch |err| {
            if (!engine.running) return;
            log.err("Error accepting connection: {}", .{err});
            continue;
        };
        if (!engine.running) {
            conn.close(engine.io);
            return;
        }
        log.info("Client connected: {}", .{conn.socket.address});

        if (builtin.os.tag == .psp) {
            sdk.extra.net.disableNagle(@intCast(conn.socket.handle)) catch |err|
                log.warn("TCP_NODELAY failed: {}", .{err});
        }

        var assigned = false;
        for (0..Consts.MAX_PLAYERS) |i| {
            if (self.conn_handles[i] != null) continue;

            log.info("Assigning connection to slot {d}", .{i});
            self.conn_handles[i] = .{
                .stream = conn,
                .reader = undefined,
                .writer = undefined,
                .read_buffer = @splat(0),
                .write_buffer = @splat(0),
                .connected = true,
            };

            self.conn_handles[i].?.reader = std.Io.net.Stream.Reader.init(conn, engine.io, &self.conn_handles[i].?.read_buffer);
            self.conn_handles[i].?.writer = std.Io.net.Stream.Writer.init(conn, engine.io, &self.conn_handles[i].?.write_buffer);

            if (Server.client_join(&self.conn_handles[i].?.reader.interface, &self.conn_handles[i].?.writer.interface, &self.conn_handles[i].?.connected)) |client| {
                self.tasks.concurrent(engine.io, client_read_loop, .{client}) catch {
                    log.err("Failed to spawn read task for slot {d}", .{i});
                    self.conn_handles[i].?.connected = false;
                };
            }
            assigned = true;
            break;
        }

        if (!assigned) {
            log.info("Server full, rejecting connection", .{});
            conn.close(engine.io);
        }
    }
}

fn install_signal_handlers() void {
    if (comptime builtin.os.tag == .psp) {
        const kernel = sdk.kernel;

        const exit_cb = struct {
            fn cb(_: c_int, _: c_int, _: ?*anyopaque) callconv(.c) c_int {
                if (global_engine) |e| e.quit();
                return 0;
            }
        }.cb;

        const cb_thread = struct {
            fn entry(_: usize, _: ?*anyopaque) callconv(.c) c_int {
                const cbid = kernel.create_callback("server_exit_cb", exit_cb, null) catch
                    @panic("Could not create exit callback!");
                kernel.register_exit_callback(cbid) catch
                    @panic("Could not register exit callback!");
                kernel.sleep_thread_cb() catch {};
                return 0;
            }
        }.entry;

        const tid = kernel.create_thread("server_exit_thread", cb_thread, 0x11, 0xFA0, .{ .user = true }, null) catch
            @panic("Could not create exit callback thread!");
        kernel.start_thread(tid, 0, null) catch {};
    } else if (comptime builtin.os.tag == .windows) {
        const windows = std.os.windows;
        const ws2_shutdown = struct {
            extern "ws2_32" fn shutdown(s: *anyopaque, how: c_int) callconv(.winapi) c_int;
        }.shutdown;
        const SetConsoleCtrlHandler = struct {
            extern "kernel32" fn SetConsoleCtrlHandler(
                HandlerRoutine: ?*const fn (windows.DWORD) callconv(.winapi) windows.BOOL,
                Add: windows.BOOL,
            ) callconv(.winapi) windows.BOOL;
        }.SetConsoleCtrlHandler;
        const handler = struct {
            fn handler(_: std.os.windows.DWORD) callconv(.winapi) std.os.windows.BOOL {
                if (global_engine) |e| e.quit();
                if (global_listener) |l| {
                    _ = ws2_shutdown(l.socket.handle, 2);
                }
                return std.os.windows.BOOL.TRUE;
            }
        }.handler;
        _ = SetConsoleCtrlHandler(handler, std.os.windows.BOOL.TRUE);
    } else {
        const handler = struct {
            fn handler(_: std.posix.SIG) callconv(.c) void {
                if (global_engine) |e| e.quit();
                // Shutdown the listener socket to unblock accept().
                if (global_listener) |l| {
                    _ = std.os.linux.shutdown(l.socket.handle, 2);
                }
            }
        }.handler;

        const act: std.posix.Sigaction = .{
            .handler = .{ .handler = handler },
            .mask = std.mem.zeroes(std.posix.sigset_t),
            .flags = 0,
        };
        std.posix.sigaction(std.posix.SIG.INT, &act, null);
        std.posix.sigaction(std.posix.SIG.TERM, &act, null);
    }
}
