const std = @import("std");
const core = @import("core");

const Server = core.Server;
const log = std.log.scoped(.server_config);

const properties_file_name = "server.properties";
const max_config_len = 4096;
const max_text_len = 64;
const max_save_location_len = 256;

pub const autosave_default_seconds: u32 = 300;
pub const autosave_min_seconds: u32 = 60;
pub const autosave_max_seconds: u32 = 900;

pub const max_heartbeat_urls: usize = 8;
pub const max_heartbeat_url_len: usize = 512;

pub const Heartbeat = struct {
    urls: [max_heartbeat_urls][max_heartbeat_url_len]u8 = undefined,
    lens: [max_heartbeat_urls]u16 = @splat(0),
    count: usize = 0,

    pub fn url(self: *const Heartbeat, index: usize) []const u8 {
        return self.urls[index][0..self.lens[index]];
    }
};

const Config = @This();

server_name: [max_text_len]u8 = undefined,
server_name_len: u16 = 0,
motd: [max_text_len]u8 = undefined,
motd_len: u16 = 0,
seed: u64,
save_location: [max_save_location_len]u8 = undefined,
save_location_len: u16 = 0,
world_size: core.world_dims.WorldSize = .normal,
world_height: core.world_dims.WorldHeight = .normal,
save_format: core.World.SaveFormat = core.World.default_format,
login_timeout_ms: u32 = Server.default_login_timeout_ms,
max_pending_logins: u32 = Server.default_max_pending_logins,
max_connections_per_ip: u32 = Server.default_max_connections_per_ip,
whitelist_enabled: bool = false,
max_players_saved: u32 = Server.default_max_players_saved,
max_policy_records: u32 = Server.default_max_policy_records,
autosave_seconds: u32 = autosave_default_seconds,
heartbeat: Heartbeat = .{},

pub fn load(io: std.Io, data_dir: std.Io.Dir, seed: u64) Config {
    const file = data_dir.openFile(io, properties_file_name, .{}) catch {
        const config = defaults(seed);
        write_default(io, data_dir, &config);
        return config;
    };
    defer file.close(io);

    var buf: [max_config_len]u8 = undefined;
    const len = file.readPositionalAll(io, &buf, 0) catch |err| {
        log.warn("Failed to read {s}: {}; using defaults", .{ properties_file_name, err });
        return defaults(seed);
    };
    if (len == buf.len) log.warn("{s} may exceed {d} bytes; ignoring the remainder", .{ properties_file_name, max_config_len });

    log.info("Loaded {s}", .{properties_file_name});
    return parse(buf[0..len], seed);
}

pub fn parse(content: []const u8, seed: u64) Config {
    var config = defaults(seed);
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        const separator = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const key = std.mem.trim(u8, line[0..separator], " \t");
        const value = std.mem.trim(u8, line[separator + 1 ..], " \t\r");

        if (std.mem.eql(u8, key, "server-name")) {
            store(config.server_name[0..], &config.server_name_len, value);
        } else if (std.mem.eql(u8, key, "motd")) {
            store(config.motd[0..], &config.motd_len, value);
        } else if (std.mem.eql(u8, key, "seed")) {
            config.seed = std.fmt.parseInt(u64, value, 10) catch blk: {
                log.warn("server.properties seed value '{s}' is not a u64; ignoring", .{value});
                break :blk config.seed;
            };
        } else if (std.mem.eql(u8, key, "save-location")) {
            if (value.len == 0) {
                log.warn("server.properties save-location is empty; ignoring", .{});
            } else if (value.len > config.save_location.len) {
                log.warn("server.properties save-location too long ({d} bytes); ignoring", .{value.len});
            } else {
                store(config.save_location[0..], &config.save_location_len, value);
            }
        } else if (std.mem.eql(u8, key, "save-format")) {
            config.save_format = core.World.SaveFormat.parse(value) orelse blk: {
                log.warn("server.properties save-format '{s}' unknown; ignoring", .{value});
                break :blk config.save_format;
            };
        } else if (std.mem.eql(u8, key, "world-size")) {
            config.world_size = core.world_dims.WorldSize.parse(value) orelse blk: {
                log.warn("server.properties world-size '{s}' is not tiny|normal|huge; ignoring", .{value});
                break :blk config.world_size;
            };
        } else if (std.mem.eql(u8, key, "world-height")) {
            config.world_height = core.world_dims.WorldHeight.parse(value) orelse blk: {
                log.warn("server.properties world-height '{s}' is not normal|tall; ignoring", .{value});
                break :blk config.world_height;
            };
        } else if (std.mem.eql(u8, key, "login-timeout-ms")) {
            config.login_timeout_ms = parse_clamped(value, config.login_timeout_ms, 1_000, 60_000, key);
        } else if (std.mem.eql(u8, key, "max-pending-logins")) {
            config.max_pending_logins = parse_clamped(value, config.max_pending_logins, 1, Server.MaxPlayers, key);
        } else if (std.mem.eql(u8, key, "max-connections-per-ip")) {
            config.max_connections_per_ip = parse_clamped(value, config.max_connections_per_ip, 1, Server.MaxPlayers, key);
        } else if (std.mem.eql(u8, key, "whitelist")) {
            config.whitelist_enabled = std.mem.eql(u8, value, "true");
        } else if (std.mem.eql(u8, key, "max-players-saved")) {
            config.max_players_saved = parse_clamped(value, config.max_players_saved, 1, core.PlayersDb.max_capacity, key);
        } else if (std.mem.eql(u8, key, "max-policy-records")) {
            config.max_policy_records = parse_clamped(value, config.max_policy_records, 1, core.AccessControl.max_capacity, key);
        } else if (std.mem.eql(u8, key, "backup-autosave-seconds")) {
            config.autosave_seconds = parse_clamped(
                value,
                config.autosave_seconds,
                autosave_min_seconds,
                autosave_max_seconds,
                key,
            );
        } else if (std.mem.eql(u8, key, "heartbeat-url")) {
            parse_heartbeat_urls(&config.heartbeat, value);
        }
    }
    if (std.mem.eql(u8, config.save_location_slice(), Server.root_default_save_file_name)) {
        store(config.save_location[0..], &config.save_location_len, Server.default_save_location);
    }
    return config;
}

pub fn save_location_slice(self: *const Config) []const u8 {
    return self.save_location[0..self.save_location_len];
}

pub fn core_config(self: *const Config) Server.StandaloneConfig {
    return .{
        .world = .{
            .seed = self.seed,
            .save_location = self.save_location_slice(),
            .save_format = self.save_format,
            .size = self.world_size,
            .height = self.world_height,
        },
        .server_name = self.server_name[0..self.server_name_len],
        .server_motd = self.motd[0..self.motd_len],
        .whitelist_enabled = self.whitelist_enabled,
        .login_timeout_ms = self.login_timeout_ms,
        .max_pending_logins = self.max_pending_logins,
        .max_connections_per_ip = self.max_connections_per_ip,
        .max_players_saved = self.max_players_saved,
        .max_policy_records = self.max_policy_records,
    };
}

fn defaults(seed: u64) Config {
    var config: Config = .{ .seed = seed };
    store(config.server_name[0..], &config.server_name_len, Server.default_server_name);
    store(config.motd[0..], &config.motd_len, Server.default_server_motd);
    store(config.save_location[0..], &config.save_location_len, Server.default_save_location);
    return config;
}

fn store(out: []u8, len: *u16, value: []const u8) void {
    const n = @min(out.len, value.len);
    @memcpy(out[0..n], value[0..n]);
    len.* = @intCast(n);
}

fn parse_clamped(value: []const u8, fallback: u32, min: u32, max: u32, key: []const u8) u32 {
    const parsed = std.fmt.parseInt(u32, value, 10) catch {
        log.warn("server.properties {s} value '{s}' is not a u32; ignoring", .{ key, value });
        return fallback;
    };
    return std.math.clamp(parsed, min, max);
}

fn parse_heartbeat_urls(heartbeat: *Heartbeat, value: []const u8) void {
    heartbeat.count = 0;
    heartbeat.lens = @splat(0);
    var parts = std.mem.splitScalar(u8, value, ',');
    while (parts.next()) |part| {
        const endpoint = std.mem.trim(u8, part, " \t\r");
        if (endpoint.len == 0) continue;
        if (endpoint.len > max_heartbeat_url_len) {
            log.warn("Ignoring heartbeat URL longer than {d} bytes", .{max_heartbeat_url_len});
            continue;
        }

        const uri = std.Uri.parse(endpoint) catch {
            log.warn("Ignoring invalid or non-HTTP heartbeat URL", .{});
            continue;
        };
        if (!std.ascii.eqlIgnoreCase(uri.scheme, "http") or uri.host == null) {
            log.warn("Ignoring invalid or non-HTTP heartbeat URL", .{});
            continue;
        }
        if (heartbeat.count == max_heartbeat_urls) {
            log.warn("Ignoring heartbeat URLs after the first {d}", .{max_heartbeat_urls});
            break;
        }

        store(
            heartbeat.urls[heartbeat.count][0..],
            &heartbeat.lens[heartbeat.count],
            endpoint,
        );
        heartbeat.count += 1;
    }
}

fn write_default(io: std.Io, data_dir: std.Io.Dir, config: *const Config) void {
    const file = data_dir.createFile(io, properties_file_name, .{}) catch |err| {
        log.info("No {s}, failed to create ({}), using defaults", .{ properties_file_name, err });
        return;
    };
    defer file.close(io);

    var buf: [1024]u8 = undefined;
    const contents = std.fmt.bufPrint(
        &buf,
        "server-name:{s}\nmotd:{s}\nseed:{d}\nsave-location:{s}\nworld-size:{s}\nworld-height:{s}\nsave-format:{s}\nlogin-timeout-ms:{d}\nmax-pending-logins:{d}\nmax-connections-per-ip:{d}\nwhitelist:false\nmax-players-saved:{d}\nmax-policy-records:{d}\nbackup-autosave-seconds:{d}\nheartbeat-url:\n",
        .{
            config.server_name[0..config.server_name_len],
            config.motd[0..config.motd_len],
            config.seed,
            config.save_location_slice(),
            @tagName(config.world_size),
            @tagName(config.world_height),
            @tagName(config.save_format),
            config.login_timeout_ms,
            config.max_pending_logins,
            config.max_connections_per_ip,
            config.max_players_saved,
            config.max_policy_records,
            config.autosave_seconds,
        },
    ) catch |err| {
        log.info("Failed to format default {s} ({}), using defaults", .{ properties_file_name, err });
        return;
    };

    file.writeStreamingAll(io, contents) catch |err| {
        log.info("Failed to write default {s} ({}), using defaults", .{ properties_file_name, err });
        return;
    };
    log.info("Generated default {s}", .{properties_file_name});
}

test "server properties populate all standalone settings" {
    const config = parse(
        " server-name: Test Server \r\n" ++
            "motd: Hello World\r\n" ++
            "seed:42\r\n" ++
            "save-location: saves/custom.cw\r\n" ++
            "world-size:huge\r\n" ++
            "world-height:tall\r\n" ++
            "save-format:classic_dat\r\n" ++
            "login-timeout-ms:2500\r\n" ++
            "max-pending-logins:12\r\n" ++
            "max-connections-per-ip:3\r\n" ++
            "whitelist:true\r\n" ++
            "max-players-saved:200\r\n" ++
            "max-policy-records:300\r\n" ++
            "backup-autosave-seconds:120\r\n" ++
            "heartbeat-url: http://localhost/a, http://example.test/b \r\n",
        1,
    );
    const game = config.core_config();

    try std.testing.expectEqualStrings("Test Server", game.server_name);
    try std.testing.expectEqualStrings("Hello World", game.server_motd);
    try std.testing.expectEqual(@as(u64, 42), game.world.seed);
    try std.testing.expectEqualStrings("saves/custom.cw", game.world.save_location);
    try std.testing.expectEqual(core.world_dims.WorldSize.huge, game.world.size);
    try std.testing.expectEqual(core.world_dims.WorldHeight.tall, game.world.height);
    try std.testing.expectEqual(core.World.SaveFormat.classic_dat, std.meta.activeTag(game.world.save_format));
    try std.testing.expectEqual(@as(u32, 2500), game.login_timeout_ms);
    try std.testing.expectEqual(@as(u32, 12), game.max_pending_logins);
    try std.testing.expectEqual(@as(u32, 3), game.max_connections_per_ip);
    try std.testing.expect(game.whitelist_enabled);
    try std.testing.expectEqual(@as(u32, 200), game.max_players_saved);
    try std.testing.expectEqual(@as(u32, 300), game.max_policy_records);
    try std.testing.expectEqual(@as(u32, 120), config.autosave_seconds);
    try std.testing.expectEqual(@as(usize, 2), config.heartbeat.count);
    try std.testing.expectEqualStrings("http://localhost/a", config.heartbeat.url(0));
    try std.testing.expectEqualStrings("http://example.test/b", config.heartbeat.url(1));
}

test "server properties retain defaults and clamp bounded values" {
    const config = parse(
        "login-timeout-ms:1\n" ++
            "max-pending-logins:999\n" ++
            "max-connections-per-ip:0\n" ++
            "max-players-saved:999999\n" ++
            "max-policy-records:999999\n" ++
            "backup-autosave-seconds:9999\n",
        77,
    );
    const game = config.core_config();

    try std.testing.expectEqualStrings(Server.default_server_name, game.server_name);
    try std.testing.expectEqualStrings(Server.default_server_motd, game.server_motd);
    try std.testing.expectEqual(@as(u64, 77), game.world.seed);
    try std.testing.expectEqualStrings(Server.default_save_location, game.world.save_location);
    try std.testing.expectEqual(core.world_dims.WorldSize.normal, game.world.size);
    try std.testing.expectEqual(@as(u32, 1_000), game.login_timeout_ms);
    try std.testing.expectEqual(@as(u32, Server.MaxPlayers), game.max_pending_logins);
    try std.testing.expectEqual(@as(u32, 1), game.max_connections_per_ip);
    try std.testing.expectEqual(core.PlayersDb.max_capacity, game.max_players_saved);
    try std.testing.expectEqual(core.AccessControl.max_capacity, game.max_policy_records);
    try std.testing.expectEqual(autosave_max_seconds, config.autosave_seconds);
    try std.testing.expectEqual(@as(usize, 0), config.heartbeat.count);

    const legacy_location = parse("save-location:world.cw\r\n", 0);
    try std.testing.expectEqualStrings(Server.default_save_location, legacy_location.save_location_slice());
}

test "missing server properties writes the effective defaults" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const config = load(io, tmp.dir, 1234);
    const game = config.core_config();
    try std.testing.expectEqual(@as(u64, 1234), game.world.seed);
    try std.testing.expectEqualStrings(Server.default_save_location, game.world.save_location);

    const file = try tmp.dir.openFile(io, properties_file_name, .{});
    defer file.close(io);

    var buf: [1024]u8 = undefined;
    const len = try file.readPositionalAll(io, &buf, 0);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..len], "seed:1234\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..len], "save-location:saves/world.cw\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..len], "backup-autosave-seconds:300\n") != null);
}
