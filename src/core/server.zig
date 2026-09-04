const std = @import("std");
const blocks = @import("blocks.zig");
const protocol = @import("protocol.zig");
pub const Client = @import("client.zig");
const OutboundQueue = @import("outbound_queue.zig").OutboundQueue;
const world = @import("world.zig");
const world_dims = @import("world_dims.zig");
const compress_worker = @import("compress_worker.zig");
const players_db = @import("players_db.zig");
const access_control = @import("access_control.zig");
const zb = @import("protocol");

const log = std.log.scoped(.server);

pub const MaxPlayers = 128;

/// Inputs needed to load or generate a world. The save location is relative
/// to the host's data directory and includes the file name.
pub const WorldConfig = struct {
    seed: u64,
    save_location: []const u8,
    save_format: world.SaveFormat = world.default_format,
    size: world_dims.WorldSize = .normal,
    height: world_dims.WorldHeight = .normal,

    pub fn dims(self: WorldConfig) world.WorldDims {
        return world_dims.from_presets(self.size, self.height);
    }
};

pub const default_save_location: []const u8 = "saves/world.cw";
pub const root_default_save_file_name: []const u8 = "world.cw";
pub const legacy_save_file_name: []const u8 = "world.dat";
pub const default_server_name = "CrossCraft Server";
pub const default_server_motd = "Welcome to CrossCraft!";
pub const default_login_timeout_ms: u32 = 15_000;
pub const default_max_pending_logins: u32 = 16;
pub const default_max_connections_per_ip: u32 = 8;
pub const default_max_players_saved: u32 = 1024;
pub const default_max_policy_records: u32 = 4096;

const BootConfig = struct {
    world: WorldConfig,
};

pub const StandaloneConfig = struct {
    world: WorldConfig,
    server_name: []const u8 = default_server_name,
    server_motd: []const u8 = default_server_motd,
    whitelist_enabled: bool = false,
    login_timeout_ms: u32 = default_login_timeout_ms,
    max_pending_logins: u32 = default_max_pending_logins,
    max_connections_per_ip: u32 = default_max_connections_per_ip,
    max_players_saved: u32 = default_max_players_saved,
    max_policy_records: u32 = default_max_policy_records,
};

pub const GameConfig = union(enum) {
    standalone: StandaloneConfig,
    embedded: BootConfig,
};

pub var io: std.Io = undefined;
pub var save_dir: std.Io.Dir = undefined;
var save_dir_owned: bool = false;

pub var server_name: [64]u8 = pad(default_server_name);
pub var server_motd: [64]u8 = pad(default_server_motd);

pub var whitelist_enabled: bool = false;

pub var login_timeout_ms: u32 = default_login_timeout_ms;
pub var max_pending_logins: u32 = default_max_pending_logins;
pub var max_connections_per_ip: u32 = default_max_connections_per_ip;
pub var max_players_saved: u32 = default_max_players_saved;
pub var max_policy_records: u32 = default_max_policy_records;

/// Optional host callback for mirroring broadcast chat.
pub var on_broadcast_chat: ?*const fn ([]const u8) void = null;

pub var players: PlayerSlots = .{};
var player_generations: [MaxPlayers]u32 = @splat(0);

/// Roster synchronization is separate from the Core-owned world lock.
var roster_lock: std.Io.RwLock = .init;

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

/// True when the server is hosted inside the client process for singleplayer.
/// Gates durable player data and join/leave chat for remote clients.
pub var internal_use: bool = false;

pub const block_change_sink: world.WorldSimulation.BlockChangeSink = .{ .emit_fn = emit_block_change };

fn emit_block_change(_: ?*anyopaque, change: world.WorldSimulation.BlockChange) void {
    broadcast_block_change(change.x, change.y, change.z, change.block);
}

fn pad(s: []const u8) [64]u8 {
    var buf: [64]u8 = @splat(' ');
    const len = @min(buf.len, s.len);
    @memcpy(buf[0..len], s[0..len]);
    return buf;
}

var save_file_name_buf: [256]u8 = undefined;
var save_file_name_len: u16 = 0;

pub fn init(
    alloc: std.mem.Allocator,
    scratch_alloc: std.mem.Allocator,
    _io: std.Io,
    data_dir: std.Io.Dir,
    config: GameConfig,
) !void {
    io = _io;
    roster_lock = .init;
    player_generations = @splat(0);

    server_name = pad(default_server_name);
    server_motd = pad(default_server_motd);
    whitelist_enabled = false;
    login_timeout_ms = default_login_timeout_ms;
    max_pending_logins = default_max_pending_logins;
    max_connections_per_ip = default_max_connections_per_ip;
    max_players_saved = default_max_players_saved;
    max_policy_records = default_max_policy_records;

    var wcfg: WorldConfig = undefined;
    switch (config) {
        .standalone => |standalone| {
            internal_use = false;
            wcfg = standalone.world;
            server_name = pad(standalone.server_name);
            server_motd = pad(standalone.server_motd);
            whitelist_enabled = standalone.whitelist_enabled;
            login_timeout_ms = standalone.login_timeout_ms;
            max_pending_logins = standalone.max_pending_logins;
            max_connections_per_ip = standalone.max_connections_per_ip;
            max_players_saved = standalone.max_players_saved;
            max_policy_records = standalone.max_policy_records;
        },
        .embedded => |embedded| {
            internal_use = true;
            wcfg = embedded.world;
        },
    }
    if (wcfg.save_location.len == 0) {
        log.err("WorldConfig.save_location must not be empty", .{});
        return error.InvalidSaveLocation;
    }
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

    // Existing saves restore their seed and dimensions. World storage must use
    // the raw allocator because it allocates and frees during initialization.
    try world.init(
        alloc,
        scratch.allocator(),
        io,
        save_dir,
        save_file_name,
        wcfg.dims(),
        wcfg.seed,
        wcfg.save_format,
    );
    log.info("World geometry: {}x{}x{}", .{ wcfg.dims().length, wcfg.dims().height, wcfg.dims().depth });
    errdefer world.deinit_after_init_error();

    if (!internal_use) {
        try access_control.init(alloc, io, save_dir, max_policy_records);
        errdefer access_control.deinit();
        try players_db.init(alloc, io, save_dir, max_players_saved);
        errdefer players_db.deinit();
        try access_control.finish_legacy_migration();
    }
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

/// Move old root saves into the default `saves/` layout without touching a
/// custom save location or replacing an existing destination.
fn migrate_legacy_save(data_dir: std.Io.Dir, wcfg: WorldConfig) void {
    if (!std.mem.eql(u8, wcfg.save_location, default_save_location)) return;

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

pub fn deinit() void {
    // world.deinit submits and waits for the final .cw save; the host-owned
    // compressor thread/storage must remain alive until this returns.
    world.deinit();
    if (!internal_use) {
        players_db.deinit();
        access_control.deinit();
    }

    if (save_dir_owned) {
        save_dir.close(io);
        save_dir_owned = false;
    }
    save_dir = undefined;

    // The module-static table survives re-init.
    players = .{};
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
    for (0..MaxPlayers) |i| {
        const existing = &(players.items[i] orelse continue);
        // `name_len` is zero only before a local client sends its own login.
        // Remote admissions install the name before releasing this lock.
        if (existing.name_len == name.len and std.mem.eql(u8, existing.name[0..existing.name_len], name.value[0..name.len])) {
            return .{ .rejected = "A player with that name is already connected!" };
        }
    }

    var client: Client = undefined;
    client.init_remote_admitted(reader, writer, transport, out, stream, ip, is_op, request);

    const id = players.add(client) orelse return .{ .rejected = "Server is full!" };
    const admitted = &(players.items[id].?);
    admitted.id = @intCast(id);
    player_generations[id] +%= 1;
    if (player_generations[id] == 0) player_generations[id] = 1;
    admitted.generation = player_generations[id];
    // `Protocol.init` captures the client address as its dispatch context, so
    // initialise only after the temporary `client` has been copied into the
    // stable player table.
    admitted.init();
    return .{ .accepted = admitted };
}

/// Join the embedded singleplayer server.
pub fn local_join(reader: *std.Io.Reader, writer: *std.Io.Writer, connected: *bool) ?*Client {
    var client: Client = undefined;
    client.connected = connected;
    client.transport = null;
    client.reader = reader;
    client.writer = writer;
    client.out = null;
    client.stream = null;
    client.initialized = false;
    client.phase = .init(.awaiting_login);
    client.local = true;
    client.is_op = .init(true);
    client.catchup_mode = .init(.none);
    client.ip = std.mem.zeroes([players_db.ip_str_len:0]u8);
    client.name_len = 0;
    client.id = -1;
    client.generation = 0;
    client.pose = .init(@bitCast(@as(u64, 0)));

    lock_roster();
    defer unlock_roster();
    const i = players.add(client) orelse {
        defer connected.* = false;
        client.send_disconnect("Server is full!") catch return null;
        return null;
    };
    const joined = &(players.items[i].?);
    joined.id = @intCast(i);
    player_generations[i] +%= 1;
    if (player_generations[i] == 0) player_generations[i] = 1;
    joined.generation = player_generations[i];
    joined.init();
    return joined;
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
    for (0..MaxPlayers) |i| {
        const client = &(players.items[i] orelse continue);
        if (!client.initialized) continue;
        if (std.mem.eql(u8, client.name[0..client.name_len], name)) return .{
            .handle = .{ .id = @intCast(i), .generation = client.generation },
            .ip = client.ip,
        };
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
    var console_line: ?protocol.Message = null;

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
        for (0..MaxPlayers) |i| {
            const recipient = &(players.items[i] orelse continue);
            if (!recipient.initialized) continue;
            recipient.send_despawn(id) catch {};
        }

        var msg: protocol.Message = @splat(' ');
        _ = std.fmt.bufPrint(&msg, "&e{s} left the game", .{name[0..name_len]}) catch unreachable;
        for (0..MaxPlayers) |i| {
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
    for (0..MaxPlayers) |i| {
        const client = &(players.items[i] orelse continue);
        if (!client.initialized or client.id == sender_id) continue;
        client.send_spawn(packet) catch continue;
    }
}

pub fn broadcast_chat_message(id: i8, message: []u8) void {
    lock_roster_shared();
    for (0..MaxPlayers) |i| {
        const client = &(players.items[i] orelse continue);
        if (!client.initialized) continue;
        client.send_message(id, message) catch continue;
    }
    unlock_roster_shared();
    if (on_broadcast_chat) |hook| hook(std.mem.trimEnd(u8, message, " \x00"));
}

pub fn broadcast_block_change(x: u16, y: u16, z: u16, block: blocks.Block) void {
    var catchup_packet: [8]u8 = undefined;
    var fixed = std.Io.Writer.fixed(&catchup_packet);
    protocol.send_block_change_to_client(&fixed, x, y, z, block) catch unreachable;

    lock_roster_shared();
    defer unlock_roster_shared();
    for (0..MaxPlayers) |i| {
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
    for (0..MaxPlayers) |i| {
        const recipient = &(players.items[i] orelse continue);
        if (!recipient.initialized) continue;

        for (0..MaxPlayers) |j| {
            if (i == j) continue;
            const player = &(players.items[j] orelse continue);
            if (!player.initialized) continue;
            const pose = player.load_pose();
            recipient.send_player_position(player.id, pose.x, pose.y, pose.z, pose.yaw, pose.pitch) catch continue;
        }
    }
}

/// Process all pending packets from local (singleplayer) clients.
/// Called each tick instead of running a blocking read_loop thread.
pub fn drain_local_packets() void {
    for (0..MaxPlayers) |i| {
        const client = &(players.items[i] orelse continue);
        if (client.local) client.drain_packets();
    }
}

var tick_counter: u32 = 0;

pub fn tick() void {
    world.lock_world();
    _ = world.tick(block_change_sink);
    world.unlock_world();

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
    for (0..MaxPlayers) |i| {
        const client = &(players.items[i] orelse continue);
        if (!client.initialized) continue;
        client.send_ping() catch continue;
    }
}

pub const PlayerSlots = struct {
    items: [MaxPlayers]?Client = @splat(null),

    fn add(self: *PlayerSlots, client: Client) ?usize {
        for (0..MaxPlayers) |i| {
            if (self.items[i] == null) {
                self.items[i] = client;
                return i;
            }
        }
        return null;
    }

    fn remove(self: *PlayerSlots, id: usize) void {
        std.debug.assert(self.items[id] != null);
        self.items[id] = null;
    }
};
