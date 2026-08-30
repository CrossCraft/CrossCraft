const std = @import("std");
const consts = @import("consts.zig");
const protocol = @import("protocol.zig");
pub const Client = @import("client.zig");
const OutboundQueue = @import("outbound_queue.zig").OutboundQueue;
const StaticAllocator = @import("static_allocator.zig");
const world = @import("world.zig");
const compress_worker = @import("compress_worker.zig");
const players_db = @import("players_db.zig");
const access_control = @import("access_control.zig");
const zb = @import("protocol");

const log = std.log.scoped(.server);

// --- Boot configuration ---

/// Inputs the world needs to materialise. `save_location` is a relative
/// path (under the engine data dir) to the world save *file*, including
/// its filename -- e.g. "saves/world.cw" or "saves/foo.dat". The world spec
/// saves the file at exactly this path. An empty string is rejected at init.
///
/// `save_format` picks which on-disk format to use. classic_cw is the
/// gzip-NBT ClassicWorld format and the default; classic_dat is the
/// legacy CrossCraft custom binary, retained for backward compatibility
/// and selectable via server.properties `save-format:` in standalone mode.
pub const WorldConfig = struct {
    seed: u64,
    save_location: []const u8,
    save_format: world.SaveFormat = world.default_format,
};

/// The default save path. Used by both standalone and embedded
/// hosts when no override is supplied; also the gate condition for the
/// root-save migrations in `Server.init` -- a custom
/// `save-location` in server.properties skips the migration entirely.
pub const default_save_location: []const u8 = "saves/world.cw";

/// Previous default layout: a ClassicWorld save file at the data dir root.
pub const root_default_save_file_name: []const u8 = "world.cw";

/// v1.0 layout: a single classic_dat save file at the data dir root.
pub const legacy_save_file_name: []const u8 = "world.dat";

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
/// Directory containing the active save. Resolved at `init` from the parent of
/// `WorldConfig.save_location`; the directory is created if it does not
/// already exist. Standalone `server.properties` stays at the data-dir root.
pub var save_dir: std.Io.Dir = undefined;
var save_dir_owned: bool = false;

const default_server_name = "CrossCraft Server";
const default_server_motd = "Welcome to CrossCraft!";

pub var server_name: [64]u8 = pad(default_server_name);
pub var server_motd: [64]u8 = pad(default_server_motd);

/// When true, accept_loop refuses any inbound connection whose IP isn't
/// in the durable access-control whitelist.
pub var whitelist_enabled: bool = false;

/// Capacity of the players_db record table. Read from server.properties
/// `max-players-saved` at init; clamped to platform-appropriate limits.
pub var max_players_saved: u32 = 1024;

/// Capacity of the durable access-control table. It is configured at startup
/// and never evicts bans, ops, or whitelist entries.
pub var max_policy_records: u32 = 4096;

/// Absolute deadline from TCP accept until the full PlayerIDToServer frame is
/// received. It deliberately does not reset when a peer trickles bytes.
pub const default_login_timeout_ms: u32 = 15_000;
pub const default_max_pending_logins: u32 = 16;
pub const default_max_connections_per_ip: u32 = 8;

pub var login_timeout_ms: u32 = default_login_timeout_ms;
pub var max_pending_logins: u32 = default_max_pending_logins;
pub var max_connections_per_ip: u32 = default_max_connections_per_ip;

/// Optional sink the host (ServerState) installs to mirror chat broadcasts
/// to its admin console. Server-core has no business knowing about stdout
/// directly, so it goes through this hook instead.
pub var on_broadcast_chat: ?*const fn ([]const u8) void = null;

pub var players: FirstAvailableBuffer(Client, consts.MAX_PLAYERS) = .init();
var player_generations: [consts.MAX_PLAYERS]u32 = @splat(0);

/// Synchronization domains for the standalone server. They are intentionally
/// separate: world simulation never contends with chat or position traffic,
/// and roster readers may proceed concurrently while membership is stable.
var roster_lock: std.Io.RwLock = .init;
var world_lock: std.Io.RwLock = .init;

pub const PlayerHandle = struct {
    id: u8,
    generation: u32,
};

pub fn lock_roster() void {
    roster_lock.lockUncancelable(io);
}

pub fn unlock_roster() void {
    roster_lock.unlock(io);
}

pub fn lock_roster_shared() void {
    roster_lock.lockSharedUncancelable(io);
}

pub fn unlock_roster_shared() void {
    roster_lock.unlockShared(io);
}

pub fn lock_world() void {
    world_lock.lockUncancelable(io);
}

pub fn unlock_world() void {
    world_lock.unlock(io);
}

pub fn lock_world_shared() void {
    world_lock.lockSharedUncancelable(io);
}

pub fn unlock_world_shared() void {
    world_lock.unlockShared(io);
}

/// True when the server is hosted inside the client process for singleplayer.
/// Gates behaviors that only make sense for a standalone server reachable by
/// real network clients (server.properties I/O, join/leave chat spam, etc.).
pub var internal_use: bool = false;

/// Used for scheduler-driven changes: queue protocol packets into each
/// client's existing writer buffer, then flush once at the end of Server.tick.
const tick_change_sink: world.BlockChangeSink = .{ .emit_fn = emit_tick_block_change };

/// Used by direct gameplay actions such as sponge absorption, where the
/// caller preserves the pre-existing immediate-broadcast behavior.
pub const immediate_block_change_sink: world.BlockChangeSink = .{ .emit_fn = emit_immediate_block_change };

fn emit_tick_block_change(_: ?*anyopaque, change: world.BlockChange) void {
    broadcast_block_change_buffered(change.x, change.y, change.z, change.block);
}

fn emit_immediate_block_change(_: ?*anyopaque, change: world.BlockChange) void {
    broadcast_block_change(change.x, change.y, change.z, change.block);
}

fn pad(comptime s: []const u8) [64]u8 {
    var buf: [64]u8 = @splat(' ');
    @memcpy(buf[0..s.len], s);
    return buf;
}

/// Buffer holding a save_location override read from server.properties.
/// Sized for the longest path we expect to see in a config file.
var save_location_buf: [256]u8 = undefined;
var save_file_name_buf: [256]u8 = undefined;
var save_file_name_len: u16 = 0;

pub fn init(
    alloc: std.mem.Allocator,
    scratch_alloc: std.mem.Allocator,
    _io: std.Io,
    data_dir: std.Io.Dir,
    config: GameConfig,
) !void {
    allocator = .init(alloc);
    errdefer allocator.deinit();
    io = _io;
    roster_lock = .init;
    world_lock = .init;
    player_generations = @splat(0);

    // Server globals survive an embedded-server teardown in the same
    // process. Reset connection-admission values before optionally loading a
    // fresh standalone configuration.
    login_timeout_ms = default_login_timeout_ms;
    max_pending_logins = default_max_pending_logins;
    max_connections_per_ip = default_max_connections_per_ip;

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
    normalize_default_save_location(&wcfg);

    // Promote old root saves into the default location before the saver opens
    // it. Format sniffing handles classic_dat content copied from world.dat;
    // the post-load upgrade save (world.zig) rewrites it as classic_cw.
    migrate_legacy_save(data_dir, wcfg);

    const split = split_save_location(wcfg.save_location);
    save_dir = try resolve_save_dir(data_dir, split.parent);
    save_dir_owned = split.parent.len > 0;
    errdefer if (save_dir_owned) {
        save_dir.close(io);
        save_dir_owned = false;
        save_dir = undefined;
    };
    const save_file_name = copy_save_file_name(split.file_name) catch |err| {
        log.err("WorldConfig.save_location file name is invalid: {}", .{err});
        return err;
    };
    log.info("Using save location '{s}'", .{wcfg.save_location});

    var scratch = std.heap.ArenaAllocator.init(scratch_alloc);
    defer scratch.deinit();

    // Initialise the shared compression worker BEFORE world.init: a
    // fresh classic_cw world fires its first save during generation,
    // which submits a job to compress_worker's queue. Reordering
    // compress_worker.init after world.init would reset the queue
    // head and silently drop that initial save. The host frees compressor
    // storage after joining the worker thread, so do not back it with the
    // server StaticAllocator that Server.deinit clears first.
    try compress_worker.init(alloc, io);
    errdefer compress_worker.deinit();

    // wcfg.seed is used only on first generation; the saver restores
    // the saved seed when an existing save file is found. Format choice
    // comes from server.properties via wcfg; embedded mode uses default.
    // World storage (and worldgen output) allocates and frees during init,
    // so it uses raw `alloc` -- the StaticAllocator state machine forbids
    // frees until teardown. Same rationale as the stores below.
    try world.init(
        alloc,
        scratch.allocator(),
        io,
        save_dir,
        save_file_name,
        wcfg.seed,
        wcfg.save_format,
    );
    errdefer world.deinit_after_init_error();

    // Both persistent stores allocate from raw `alloc`, not the static
    // wrapper. Their capacities are fixed at init before the allocator is
    // frozen for the server's gameplay hot path.
    if (!internal_use) {
        try access_control.init(alloc, io, save_dir, max_policy_records);
        errdefer access_control.deinit();
        try players_db.init(alloc, io, save_dir, max_players_saved);
        errdefer players_db.deinit();
        try access_control.finish_legacy_migration();
    }

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

fn copy_save_file_name(file_name: []const u8) ![]const u8 {
    if (file_name.len == 0 or file_name.len > save_file_name_buf.len) return error.InvalidSaveLocation;
    @memcpy(save_file_name_buf[0..file_name.len], file_name);
    save_file_name_len = @intCast(file_name.len);
    return save_file_name_buf[0..save_file_name_len];
}

fn normalize_default_save_location(wcfg: *WorldConfig) void {
    if (std.mem.eql(u8, wcfg.save_location, root_default_save_file_name)) {
        wcfg.save_location = default_save_location;
    }
}

/// Move old root saves into the default `saves/` layout. Gated on the
/// configured save_location matching the default, so an operator who set a
/// custom `save-location:` in server.properties is left alone. No-op when the
/// new file already exists. Logs and skips on failures -- the saver then falls
/// through to worldgen, which is the same outcome as having no save at all.
fn migrate_legacy_save(data_dir: std.Io.Dir, wcfg: WorldConfig) void {
    if (!std.mem.eql(u8, wcfg.save_location, default_save_location)) return;

    // Skip if the new-path file already exists -- never clobber.
    if (file_exists(data_dir, wcfg.save_location)) return;

    const split = split_save_location(wcfg.save_location);
    if (split.parent.len > 0) {
        var new_dir = data_dir.createDirPathOpen(io, split.parent, .{}) catch |err| {
            log.warn("legacy save migration: failed to create '{s}': {}", .{ split.parent, err });
            return;
        };
        new_dir.close(io);
    }

    if (file_exists(data_dir, root_default_save_file_name)) {
        data_dir.rename(root_default_save_file_name, data_dir, wcfg.save_location, io) catch |err| {
            log.warn("default save migration failed: {}", .{err});
            return;
        };
        log.info("Migrated default save '{s}' -> '{s}'", .{
            root_default_save_file_name, wcfg.save_location,
        });
        return;
    }

    if (!file_exists(data_dir, legacy_save_file_name)) return;

    var backup_name_buf: [32]u8 = undefined;
    const backup_name = choose_legacy_backup_name(data_dir, &backup_name_buf) orelse {
        log.warn("legacy save migration: no available world.bak name", .{});
        return;
    };

    copy_file_direct(data_dir, legacy_save_file_name, wcfg.save_location) catch |err| {
        log.warn("legacy save migration failed: {}", .{err});
        return;
    };

    data_dir.rename(legacy_save_file_name, data_dir, backup_name, io) catch |err| {
        log.warn("legacy save migration: failed to rename {s} to {s}: {}", .{
            legacy_save_file_name, backup_name, err,
        });
        return;
    };
    log.info("Migrated legacy save '{s}' -> '{s}'; backup '{s}'", .{
        legacy_save_file_name, wcfg.save_location, backup_name,
    });
}

fn choose_legacy_backup_name(data_dir: std.Io.Dir, out: *[32]u8) ?[]const u8 {
    if (!file_exists(data_dir, "world.bak")) return "world.bak";

    var i: u16 = 2;
    while (i < 1000) : (i += 1) {
        const name = std.fmt.bufPrint(out, "world.{d}.bak", .{i}) catch return null;
        if (!file_exists(data_dir, name)) return name;
    }
    return null;
}

fn copy_file_direct(dir: std.Io.Dir, src_path: []const u8, dst_path: []const u8) !void {
    const src = try dir.openFile(io, src_path, .{});
    defer src.close(io);

    const dst = try dir.createFile(io, dst_path, .{ .exclusive = true });
    var dst_closed = false;
    errdefer dir.deleteFile(io, dst_path) catch {};
    defer if (!dst_closed) dst.close(io);

    var buf: [8192]u8 = undefined;
    var offset: u64 = 0;
    while (true) {
        const n = try src.readPositionalAll(io, &buf, offset);
        if (n == 0) break;
        try dst.writeStreamingAll(io, buf[0..n]);
        offset += n;
    }

    dst.close(io);
    dst_closed = true;
}

fn file_exists(dir: std.Io.Dir, path: []const u8) bool {
    const file = dir.openFile(io, path, .{}) catch return false;
    file.close(io);
    return true;
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
            } else if (std.mem.eql(u8, key, "save-format")) {
                if (world.SaveFormat.parse(value)) |fmt| {
                    wcfg.save_format = fmt;
                } else {
                    log.warn("server.properties save-format '{s}' unknown; using default", .{value});
                }
            } else if (std.mem.eql(u8, key, "login-timeout-ms")) {
                if (std.fmt.parseInt(u32, value, 10)) |parsed| {
                    login_timeout_ms = std.math.clamp(parsed, 1_000, 60_000);
                } else |_| {
                    log.warn("server.properties login-timeout-ms value '{s}' is not a u32; ignoring", .{value});
                }
            } else if (std.mem.eql(u8, key, "max-pending-logins")) {
                if (std.fmt.parseInt(u32, value, 10)) |parsed| {
                    max_pending_logins = std.math.clamp(parsed, 1, @as(u32, consts.MAX_PLAYERS));
                } else |_| {
                    log.warn("server.properties max-pending-logins value '{s}' is not a u32; ignoring", .{value});
                }
            } else if (std.mem.eql(u8, key, "max-connections-per-ip")) {
                if (std.fmt.parseInt(u32, value, 10)) |parsed| {
                    max_connections_per_ip = std.math.clamp(parsed, 1, @as(u32, consts.MAX_PLAYERS));
                } else |_| {
                    log.warn("server.properties max-connections-per-ip value '{s}' is not a u32; ignoring", .{value});
                }
            } else if (std.mem.eql(u8, key, "whitelist")) {
                whitelist_enabled = std.mem.eql(u8, value, "true");
            } else if (std.mem.eql(u8, key, "max-players-saved")) {
                if (std.fmt.parseInt(u32, value, 10)) |parsed| {
                    max_players_saved = std.math.clamp(parsed, 1, players_db.max_capacity);
                } else |_| {
                    log.warn("server.properties max-players-saved value '{s}' is not a u32; ignoring", .{value});
                }
            } else if (std.mem.eql(u8, key, "max-policy-records")) {
                if (std.fmt.parseInt(u32, value, 10)) |parsed| {
                    max_policy_records = std.math.clamp(parsed, 1, access_control.max_capacity);
                } else |_| {
                    log.warn("server.properties max-policy-records value '{s}' is not a u32; ignoring", .{value});
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
    const contents = std.fmt.bufPrint(
        &buf,
        "server-name:{s}\nmotd:{s}\nseed:{d}\nsave-location:{s}\nsave-format:classic_cw\nlogin-timeout-ms:{d}\nmax-pending-logins:{d}\nmax-connections-per-ip:{d}\nwhitelist:false\nmax-players-saved:{d}\nmax-policy-records:{d}\nheartbeat-url:\n",
        .{
            default_server_name,
            default_server_motd,
            wcfg.seed,
            wcfg.save_location,
            login_timeout_ms,
            max_pending_logins,
            max_connections_per_ip,
            max_players_saved,
            max_policy_records,
        },
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

    // world.deinit submits and waits for the final .cw save; the host-owned
    // compressor thread/storage must remain alive until this returns.
    world.deinit();
    if (!internal_use) {
        players_db.deinit();
        access_control.deinit();
    }

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

/// A decoded, structurally valid Classic login frame. It contains only the
/// identity data the server needs before a Client has been assigned a player
/// table entry.
pub const LoginRequest = Client.LoginRequest;

pub const LoginAdmission = union(enum) {
    accepted: *Client,
    rejected: []const u8,
};

/// Parse and validate the one fixed-size frame that must arrive before a
/// remote peer is allowed to consume a game-player slot.
pub fn parse_login_frame(frame: []const u8) !LoginRequest {
    if (frame.len == 0 or frame[0] != 0x00) return error.InvalidLoginPacket;
    const expected = protocol.packet_length_to_server(frame[0]) catch return error.InvalidLoginPacket;
    if (frame.len != expected) return error.InvalidLoginPacket;

    var reader = std.Io.Reader.fixed(frame[1..]);
    const packet = try zb.PlayerIDToServer.read(&reader);
    if (packet.protocol_version != 0x07) return error.UnsupportedProtocolVersion;

    return .{
        .protocol_version = packet.protocol_version,
        .username = packet.username,
    };
}

/// Reserve a real player only after `parse_login_frame` has completed. This
/// keeps pre-auth TCP sockets out of `players` and reserves names while their
/// world transfer is still in progress.
pub fn admit_login(
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,
    transport: *std.atomic.Value(Client.TransportState),
    out: *OutboundQueue,
    stream: *std.Io.net.Stream,
    ip: []const u8,
    is_op: bool,
    request: LoginRequest,
) LoginAdmission {
    if (request.protocol_version != 0x07) return .{ .rejected = "Unsupported protocol version!" };

    lock_roster();
    defer unlock_roster();

    const name = Client.login_name(request);
    for (players.items) |maybe_client| {
        if (maybe_client) |client| {
            // `name_len` is zero only before a local client sends its own
            // login. A staged remote login always has its name installed
            // before this check can be observed by another admission.
            if (client.name_len == name.len and std.mem.eql(u8, client.name[0..client.name_len], name.value[0..name.len])) {
                return .{ .rejected = "A player with that name is already connected!" };
            }
        }
    }

    var client: Client = undefined;
    client.init_remote_admitted(reader, writer, transport, out, stream, ip, is_op, request);

    const id = players.add(client) orelse return .{ .rejected = "Server is full!" };
    players.items[id].?.id = @intCast(id);
    player_generations[id] +%= 1;
    if (player_generations[id] == 0) player_generations[id] = 1;
    players.items[id].?.generation = player_generations[id];
    // `Protocol.init` captures the client address as its dispatch context, so
    // initialise only after the temporary `client` has been copied into the
    // stable player table.
    players.items[id].?.init();
    return .{ .accepted = &(players.items[id].?) };
}

pub fn client_join(reader: *std.Io.Reader, writer: *std.Io.Writer, connected: *bool, ip: []const u8, is_op: bool) ?*Client {
    var client: Client = undefined;
    client.connected = connected;
    client.transport = null;
    client.reader = reader;
    client.writer = writer;
    client.out = null;
    client.stream = null;
    client.initialized = false;
    client.phase = .init(.awaiting_login);
    client.local = false;
    client.is_op = .init(is_op);
    client.catchup_mode = .init(.none);
    client.ip = std.mem.zeroes([players_db.ip_str_len:0]u8);
    const ip_n = @min(ip.len, players_db.ip_str_len);
    @memcpy(client.ip[0..ip_n], ip[0..ip_n]);
    client.name_len = 0;
    client.id = -1;
    client.generation = 0;
    client.pose = .init(@bitCast(@as(u64, 0)));

    lock_roster();
    defer unlock_roster();
    const id = players.add(client);

    if (id) |i| {
        players.items[i].?.id = @intCast(i);
        player_generations[i] +%= 1;
        if (player_generations[i] == 0) player_generations[i] = 1;
        players.items[i].?.generation = player_generations[i];
        players.items[i].?.init();
        return &(players.items[i].?);
    } else {
        defer connected.* = false;
        client.send_disconnect("Server is full!") catch return null;
        return null;
    }
}

test "pending login frame must be complete and use the Classic protocol version" {
    var frame: [131]u8 = @splat(' ');
    frame[0] = 0x00;
    frame[1] = 0x07;
    @memcpy(frame[2..7], "Alice");
    frame[130] = 0;

    const request = try parse_login_frame(&frame);
    try std.testing.expectEqual(@as(u8, 0x07), request.protocol_version);
    try std.testing.expectEqualStrings("Alice", request.username[0..5]);

    try std.testing.expectError(error.InvalidLoginPacket, parse_login_frame(frame[0..130]));

    frame[0] = 0x05;
    try std.testing.expectError(error.InvalidLoginPacket, parse_login_frame(&frame));

    frame[0] = 0x00;
    frame[1] = 0x06;
    try std.testing.expectError(error.UnsupportedProtocolVersion, parse_login_frame(&frame));
}

/// Join the server as the local singleplayer client. Same as client_join
/// but marks the client as local (so world compression is skipped) and
/// implicitly op (so /commands work without ban-list bookkeeping).
pub fn local_join(reader: *std.Io.Reader, writer: *std.Io.Writer, connected: *bool) ?*Client {
    const client = client_join(reader, writer, connected, "", true) orelse return null;
    client.local = true;
    return client;
}

pub const ClientSnapshot = struct {
    handle: PlayerHandle,
    ip: [players_db.ip_str_len:0]u8,

    pub fn ip_slice(self: *const ClientSnapshot) []const u8 {
        return std.mem.sliceTo(self.ip[0..], 0);
    }
};

/// Resolve a command target without returning a pointer whose roster slot can
/// be reused after the lock is released.
pub fn find_client_by_name(name: []const u8) ?ClientSnapshot {
    lock_roster_shared();
    defer unlock_roster_shared();
    for (0..consts.MAX_PLAYERS) |i| {
        if (players.items[i]) |p| {
            if (!p.initialized) continue;
            if (std.mem.eql(u8, p.name[0..p.name_len], name)) return .{
                .handle = .{ .id = @intCast(i), .generation = p.generation },
                .ip = p.ip,
            };
        }
    }
    return null;
}

fn client_from_handle_locked(handle: PlayerHandle) ?*Client {
    const client = &(players.items[handle.id] orelse return null);
    if (client.generation != handle.generation) return null;
    return client;
}

pub fn disconnect_handle(handle: PlayerHandle, reason: []const u8) bool {
    lock_roster();
    defer unlock_roster();
    const client = client_from_handle_locked(handle) orelse return false;
    client.send_disconnect(reason) catch {};
    return true;
}

pub fn grant_op_handle(handle: PlayerHandle) bool {
    lock_roster();
    defer unlock_roster();
    const client = client_from_handle_locked(handle) orelse return false;
    client.is_op.store(true, .release);
    client.send_update_player_type(true) catch {};
    return true;
}

/// Detach a finished transport from the inline player table. The generation
/// check prevents a late worker completion from removing a newer occupant of
/// the same player id.
pub fn remove_client(handle: PlayerHandle) void {
    var console_line: ?consts.Message = null;

    lock_roster();
    const client = client_from_handle_locked(handle) orelse {
        unlock_roster();
        return;
    };
    const id = client.id;
    const initialized = client.initialized;
    const name = client.name;
    const name_len = client.name_len;
    players.remove(handle.id);

    if (initialized) {
        for (0..consts.MAX_PLAYERS) |i| {
            const recipient = &(players.items[i] orelse continue);
            if (!recipient.initialized) continue;
            recipient.send_despawn(id) catch {};
        }

        var msg: consts.Message = @splat(' ');
        _ = std.fmt.bufPrint(&msg, "&e{s} left the game", .{name[0..name_len]}) catch unreachable;
        for (0..consts.MAX_PLAYERS) |i| {
            const recipient = &(players.items[i] orelse continue);
            if (!recipient.initialized) continue;
            recipient.send_message(id, &msg) catch {};
        }
        console_line = msg;
    }
    unlock_roster();

    if (console_line) |*line| {
        if (on_broadcast_chat) |hook| hook(std.mem.trimEnd(u8, line, " \x00"));
    }
}

pub fn broadcast_spawn_player(sender_id: i8, packet: *zb.SpawnPlayer) void {
    lock_roster_shared();
    defer unlock_roster_shared();
    for (0..consts.MAX_PLAYERS) |i| {
        if (players.items[i] != null and players.items[i].?.initialized and players.items[i].?.id != sender_id) {
            players.items[i].?.send_spawn(packet) catch continue;
        }
    }
}

pub fn broadcast_despawn_player(id: i8) void {
    lock_roster_shared();
    defer unlock_roster_shared();
    for (0..consts.MAX_PLAYERS) |i| {
        if (players.items[i] != null and players.items[i].?.initialized) {
            players.items[i].?.send_despawn(id) catch continue;
        }
    }
}

pub fn broadcast_chat_message(id: i8, message: []u8) void {
    lock_roster_shared();
    for (0..consts.MAX_PLAYERS) |i| {
        if (players.items[i] != null and players.items[i].?.initialized) {
            players.items[i].?.send_message(id, message) catch continue;
        }
    }
    unlock_roster_shared();
    // Mirror to the host's admin console (stdout in standalone). Hook is
    // null in singleplayer / on PSP, so this is free in those builds.
    if (on_broadcast_chat) |hook| hook(std.mem.trimEnd(u8, message, " \x00"));
}

pub fn broadcast_block_change(x: u16, y: u16, z: u16, block: consts.Block) void {
    broadcast_block_change_impl(x, y, z, block);
}

fn broadcast_block_change_buffered(x: u16, y: u16, z: u16, block: consts.Block) void {
    broadcast_block_change_impl(x, y, z, block);
}

// Sends only enqueue into each client's outbound queue (pure CPU work), so
// the buffered/immediate split above no longer differs in flush behavior;
// both wrappers are kept so call sites stay put.
fn broadcast_block_change_impl(x: u16, y: u16, z: u16, block: consts.Block) void {
    var catchup_packet: [8]u8 = undefined;
    var fixed = std.Io.Writer.fixed(&catchup_packet);
    protocol.send_block_change_to_client(&fixed, x, y, z, block) catch unreachable;

    lock_roster_shared();
    defer unlock_roster_shared();
    for (0..consts.MAX_PLAYERS) |i| {
        const client = &(players.items[i] orelse continue);
        if (client.initialized or client.catchup_mode.load(.acquire) == .direct) {
            client.send_block_change(x, y, z, block) catch continue;
        } else if (client.catchup_mode.load(.acquire) == .capturing) {
            const out = client.out orelse continue;
            out.appendCatchup(io, &catchup_packet) catch client.kick_slow();
        }
    }
}

pub fn broadcast_player_positions() void {
    lock_roster_shared();
    defer unlock_roster_shared();
    for (0..consts.MAX_PLAYERS) |i| {
        if (players.items[i] == null or !players.items[i].?.initialized)
            continue;

        for (0..consts.MAX_PLAYERS) |j| {
            if (i == j)
                continue;

            if (players.items[j] != null and players.items[j].?.initialized) {
                const p = players.items[j].?;
                const pose = p.load_pose();
                players.items[i].?.send_player_position(p.id, pose.x, pose.y, pose.z, pose.yaw, pose.pitch) catch continue;
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
    lock_world();
    _ = world.tick(tick_change_sink);
    unlock_world();

    broadcast_player_positions();

    tick_counter += 1;
    if (tick_counter >= 30) {
        tick_counter = 0;
        broadcast_ping();
    }
}

fn broadcast_ping() void {
    lock_roster_shared();
    defer unlock_roster_shared();
    for (0..consts.MAX_PLAYERS) |i| {
        if (players.items[i] != null and players.items[i].?.initialized) {
            players.items[i].?.send_ping() catch continue;
        }
    }
}

pub fn FirstAvailableBuffer(comptime T: type, comptime U: usize) type {
    return struct {
        items: [U]?T,

        const Self = @This();

        pub fn init() Self {
            return .{
                .items = @splat(null),
            };
        }

        pub fn add(self: *Self, data: T) ?usize {
            for (0..U) |i| {
                if (self.items[i] == null) {
                    self.items[i] = data;
                    return i;
                }
            } else return null;
        }

        pub fn remove(self: *Self, id: usize) void {
            self.items[id].? = undefined;
            self.items[id] = null;
        }
    };
}
