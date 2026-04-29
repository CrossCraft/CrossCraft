const std = @import("std");
const consts = @import("common").consts;
const FAB = @import("common").fa_buffer.FirstAvailableBuffer;
pub const Client = @import("client.zig");
const StaticAllocator = @import("common").static_allocator;
const world = @import("world.zig");
const zb = @import("protocol");

const log = std.log.scoped(.server);

// --- Boot configuration ---

/// Inputs the world needs to materialise. `save_location` is a relative
/// path (under the engine data dir) to the world save *file*, including
/// its filename -- e.g. "world.dat" or "saves/foo.dat". The world spec
/// saves the file at exactly this path, and in standalone mode
/// server.properties is rooted in the same directory so a save dir is
/// self-contained. An empty string is rejected at init.
pub const WorldConfig = struct {
    seed: u64,
    save_location: []const u8,
};

pub const StandaloneBoot = struct {
    world: WorldConfig,
};

pub const EmbeddedBoot = struct {
    world: WorldConfig,
};

/// The host's chosen launch shape, captured once at boot.
pub const GameConfig = union(enum) {
    standalone: StandaloneBoot,
    embedded: EmbeddedBoot,

    pub fn world(self: GameConfig) WorldConfig {
        return switch (self) {
            .standalone => |s| s.world,
            .embedded => |e| e.world,
        };
    }
};

var allocator: StaticAllocator = undefined;
pub var io: std.Io = undefined;
/// Directory containing the active save. The world save file and
/// (standalone only) server.properties live here. Resolved at `init`
/// from the parent of `WorldConfig.save_location`; the directory is
/// created if it does not already exist.
pub var save_dir: std.Io.Dir = undefined;
var save_dir_owned: bool = false;

const default_server_name = "CrossCraft Server";
const default_server_motd = "Welcome to CrossCraft!";

pub var server_name: [64]u8 = pad(default_server_name);
pub var server_motd: [64]u8 = pad(default_server_motd);

pub var players: FAB(Client, consts.MAX_PLAYERS) = .init();

/// True when the server is hosted inside the client process for singleplayer.
/// Gates behaviors that only make sense for a standalone server reachable by
/// real network clients (server.properties I/O, join/leave chat spam, etc.).
pub var internal_use: bool = false;

fn pad(comptime s: []const u8) [64]u8 {
    var buf: [64]u8 = @splat(' ');
    @memcpy(buf[0..s.len], s);
    return buf;
}

/// Buffer holding a save_location override read from server.properties.
/// Sized for the longest path we expect to see in a config file.
var save_location_buf: [256]u8 = undefined;

pub fn init(
    alloc: std.mem.Allocator,
    scratch_alloc: std.mem.Allocator,
    _io: std.Io,
    data_dir: std.Io.Dir,
    config: GameConfig,
) !void {
    allocator = .init(alloc);
    io = _io;

    var wcfg = config.world();
    if (wcfg.save_location.len == 0) {
        log.err("WorldConfig.save_location must not be empty", .{});
        return error.InvalidSaveLocation;
    }
    internal_use = config == .embedded;

    // Standalone reads server.properties from the data_dir root (a stable
    // location independent of save_location), so an operator can edit
    // seed and save-location before the world has ever been generated.
    // Embedded mode never touches server.properties (NoServerPropertiesIO).
    if (!internal_use) load_config(data_dir, &wcfg);

    const split = split_save_location(wcfg.save_location);
    save_dir = try resolve_save_dir(data_dir, split.parent);
    save_dir_owned = split.parent.len > 0;

    var scratch = std.heap.ArenaAllocator.init(scratch_alloc);
    defer scratch.deinit();

    // wcfg.seed is used only on first generation; world.load() restores
    // the saved seed when an existing world.dat is found.
    try world.init(
        allocator.allocator(),
        scratch.allocator(),
        io,
        save_dir,
        split.file_name,
        wcfg.seed,
    );
    try Client.init_compressor(allocator.allocator());

    allocator.transition_from_init_to_static();
}

const SplitPath = struct {
    parent: []const u8,
    file_name: []const u8,
};

/// Split a save_location like "saves/foo.dat" into ("saves", "foo.dat").
/// "world.dat" -> ("", "world.dat"). Forward slash only -- the engine
/// data dir API takes POSIX-style sub-paths on every platform.
fn split_save_location(path: []const u8) SplitPath {
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |sep| {
        return .{ .parent = path[0..sep], .file_name = path[sep + 1 ..] };
    }
    return .{ .parent = "", .file_name = path };
}

/// Open `data_dir/sub_path`, creating it (and parents) if missing. An
/// empty `sub_path` returns `data_dir` unchanged.
fn resolve_save_dir(data_dir: std.Io.Dir, sub_path: []const u8) !std.Io.Dir {
    if (sub_path.len == 0) return data_dir;
    return data_dir.createDirPathOpen(io, sub_path, .{}) catch |err| {
        log.err("Failed to open/create save dir '{s}': {}", .{ sub_path, err });
        return err;
    };
}

fn load_config(data_dir: std.Io.Dir, wcfg: *WorldConfig) void {
    const file = data_dir.openFile(io, "server.properties", .{}) catch {
        write_default_config(data_dir, wcfg.*);
        return;
    };
    defer file.close(io);

    var buf: [512]u8 = undefined;
    const len = file.readPositionalAll(io, &buf, 0) catch {
        log.info("Failed to read server.properties, using defaults", .{});
        return;
    };

    const data = buf[0..len];
    var start: u32 = 0;

    for (0..32) |_| {
        if (start >= data.len) break;

        const end = std.mem.indexOfScalarPos(u8, data, start, '\n') orelse data.len;
        const line = data[start..end];
        start = @intCast(end + 1);

        if (std.mem.indexOfScalar(u8, line, ':')) |sep| {
            const key = line[0..sep];
            const value = line[sep + 1 ..];

            if (std.mem.eql(u8, key, "server-name")) {
                server_name = @splat(' ');
                const vlen = @min(value.len, 64);
                @memcpy(server_name[0..vlen], value[0..vlen]);
            } else if (std.mem.eql(u8, key, "motd")) {
                server_motd = @splat(' ');
                const vlen = @min(value.len, 64);
                @memcpy(server_motd[0..vlen], value[0..vlen]);
            } else if (std.mem.eql(u8, key, "seed")) {
                // seed: applies on first generation only. world.load()
                // restores the saved seed when world.dat already exists
                // and silently ignores this value.
                if (std.fmt.parseInt(u64, value, 10)) |parsed| {
                    wcfg.seed = parsed;
                } else |_| {
                    log.warn("server.properties seed value '{s}' is not a u64; ignoring", .{value});
                }
            } else if (std.mem.eql(u8, key, "save-location")) {
                if (value.len == 0) {
                    log.warn("server.properties save-location is empty; ignoring", .{});
                } else if (value.len > save_location_buf.len) {
                    log.warn("server.properties save-location too long ({d} bytes); ignoring", .{value.len});
                } else {
                    @memcpy(save_location_buf[0..value.len], value);
                    wcfg.save_location = save_location_buf[0..value.len];
                }
            }
        }
    }

    log.info("Loaded server.properties", .{});
}

fn write_default_config(data_dir: std.Io.Dir, wcfg: WorldConfig) void {
    const file = data_dir.createFile(io, "server.properties", .{}) catch |err| {
        log.info("No server.properties, failed to create ({}), using defaults", .{err});
        return;
    };
    defer file.close(io);

    var buf: [512]u8 = undefined;
    const contents = std.fmt.bufPrint(&buf,
        "server-name:{s}\nmotd:{s}\nseed:{d}\nsave-location:{s}\n",
        .{ default_server_name, default_server_motd, wcfg.seed, wcfg.save_location },
    ) catch |err| {
        log.info("Failed to format default server.properties ({}), using defaults", .{err});
        return;
    };

    file.writeStreamingAll(io, contents) catch |err| {
        log.info("Failed to write default server.properties ({}), using defaults", .{err});
        return;
    };

    log.info("Generated default server.properties", .{});
}

pub fn deinit() void {
    allocator.transition_from_static_to_deinit();

    Client.deinit_compressor();
    world.deinit();

    allocator.deinit();

    if (save_dir_owned) {
        save_dir.close(io);
        save_dir_owned = false;
    }
    save_dir = undefined;

    // Reset the player table so a subsequent Server.init() starts with no
    // stale slots (the FAB is module-static and survives re-init).
    players = .init();
}

pub fn client_join(reader: *std.Io.Reader, writer: *std.Io.Writer, connected: *bool) ?*Client {
    var client: Client = undefined;
    client.connected = connected;
    client.reader = reader;
    client.writer = writer;
    client.initialized = false;
    client.local = false;
    client.name_len = 0;
    client.id = -1;
    client.x = 0;
    client.y = 0;
    client.z = 0;
    client.yaw = 0;
    client.pitch = 0;

    const id = players.add(client);

    if (id) |i| {
        players.items[i].?.id = @intCast(i);
        players.items[i].?.init();
        return &(players.items[i].?);
    } else {
        defer connected.* = false;
        client.send_disconnect("Server is full!") catch return null;
        return null;
    }
}

/// Join the server as the local singleplayer client. Same as client_join
/// but marks the client as local so world compression is skipped.
pub fn local_join(reader: *std.Io.Reader, writer: *std.Io.Writer, connected: *bool) ?*Client {
    const client = client_join(reader, writer, connected) orelse return null;
    client.local = true;
    return client;
}

pub fn broadcast_spawn_player(sender_id: i8, packet: *zb.SpawnPlayer) void {
    for (0..consts.MAX_PLAYERS) |i| {
        if (players.items[i] != null and players.items[i].?.initialized and players.items[i].?.id != sender_id) {
            players.items[i].?.send_spawn(packet) catch continue;
            players.items[i].?.writer.flush() catch continue;
        }
    }
}

pub fn broadcast_despawn_player(id: i8) void {
    for (0..consts.MAX_PLAYERS) |i| {
        if (players.items[i] != null and players.items[i].?.initialized) {
            players.items[i].?.send_despawn(id) catch continue;
            players.items[i].?.writer.flush() catch continue;
        }
    }
}

pub fn broadcast_chat_message(id: i8, message: []u8) void {
    for (0..consts.MAX_PLAYERS) |i| {
        if (players.items[i] != null and players.items[i].?.initialized) {
            players.items[i].?.send_message(id, message) catch continue;
            players.items[i].?.writer.flush() catch continue;
        }
    }
}

pub fn broadcast_block_change(x: u16, y: u16, z: u16, block: consts.Block) void {
    for (0..consts.MAX_PLAYERS) |i| {
        if (players.items[i] != null and players.items[i].?.initialized) {
            players.items[i].?.send_block_change(x, y, z, block) catch continue;
            players.items[i].?.writer.flush() catch continue;
        }
    }
}

pub fn broadcast_player_positions() void {
    for (0..consts.MAX_PLAYERS) |i| {
        if (players.items[i] == null or !players.items[i].?.initialized)
            continue;

        for (0..consts.MAX_PLAYERS) |j| {
            if (i == j)
                continue;

            if (players.items[j] != null and players.items[j].?.initialized) {
                const p = players.items[j].?;
                players.items[i].?.send_player_position(p.id, p.x, p.y, p.z, p.yaw, p.pitch) catch continue;
                players.items[i].?.writer.flush() catch continue;
            }
        }
    }
}

/// Process all pending packets from local (singleplayer) clients.
/// Called each tick instead of running a blocking read_loop thread.
pub fn drain_local_packets() void {
    for (0..consts.MAX_PLAYERS) |i| {
        if (players.items[i] != null and players.items[i].?.local) {
            players.items[i].?.drain_packets();
        }
    }
}

var tick_counter: u32 = 0;

pub fn tick() void {
    for (0..consts.MAX_PLAYERS) |i| {
        if (players.items[i]) |client| {
            if (!client.connected.*) {
                const id = client.id;
                players.remove(@intCast(id));

                if (!client.initialized) continue;

                const name = client.name;
                const name_len = client.name_len;

                broadcast_despawn_player(id);

                var msg_buf: consts.Message = @splat(' ');
                _ = std.fmt.bufPrint(&msg_buf, "&e{s} left the game", .{name[0..name_len]}) catch unreachable;
                broadcast_chat_message(id, &msg_buf);
            }
        }
    }

    world.tick();

    for (0..world.pending_count) |i| {
        const change = world.pending_changes[i];
        broadcast_block_change(change.x, change.y, change.z, change.block);
    }
    world.pending_count = 0;

    broadcast_player_positions();

    tick_counter += 1;
    if (tick_counter >= 30) {
        tick_counter = 0;
        broadcast_ping();
    }
}

fn broadcast_ping() void {
    for (0..consts.MAX_PLAYERS) |i| {
        if (players.items[i] != null and players.items[i].?.initialized) {
            players.items[i].?.writer.writeByte(0x01) catch continue;
            players.items[i].?.writer.flush() catch continue;
        }
    }
}
