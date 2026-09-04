/// Session data shared by the menu, loading, and game states.
const std = @import("std");
const core = @import("core");

const wd = core.world_dims;

pub const Mode = enum { singleplayer, multiplayer };

pub const USERNAME_MAX: u8 = 16;
pub const SERVER_MAX: u8 = 64;
pub const DEFAULT_PORT: u16 = 25565;
pub const SAVE_PATH_MAX: usize = 256;

pub var mode: Mode = .singleplayer;

pub var username_buf: [USERNAME_MAX]u8 = undefined;
pub var username_len: u8 = 0;

pub var server_buf: [SERVER_MAX]u8 = undefined;
pub var server_len: u8 = 0;

pub var singleplayer_save_buf: [SAVE_PATH_MAX]u8 = undefined;
pub var singleplayer_save_len: u16 = 0;
pub var singleplayer_seed_override: ?u64 = null;
pub var singleplayer_size: ?wd.WorldSize = null;
pub var singleplayer_height: ?wd.WorldHeight = null;

// The read-loop owns mp_reader after loading; the game thread owns mp_writer.
pub var mp_stream: ?std.Io.net.Stream = null;
pub var mp_read_buf: [4096]u8 = undefined;
pub var mp_write_buf: [4096]u8 = undefined;
pub var mp_reader: std.Io.net.Stream.Reader = undefined;
pub var mp_writer: std.Io.net.Stream.Writer = undefined;

pub var mp_connected: std.atomic.Value(bool) = .init(false);

/// Human-readable reason for the last disconnect, set before mp_connected is
/// cleared. Its release/acquire ordering publishes this non-atomic buffer.
pub var disconnect_reason_buf: [64]u8 = undefined;
pub var disconnect_reason_len: u8 = 0;

pub fn clear_disconnect_reason() void {
    disconnect_reason_len = 0;
}

pub fn set_disconnect_reason(reason: []const u8) void {
    const len: u8 = @intCast(@min(reason.len, disconnect_reason_buf.len));
    @memcpy(disconnect_reason_buf[0..len], reason[0..len]);
    disconnect_reason_len = len;
}

pub fn set_disconnect_reason_if_empty(reason: []const u8) void {
    if (disconnect_reason_len == 0) set_disconnect_reason(reason);
}

pub fn disconnect_reason() []const u8 {
    return disconnect_reason_buf[0..disconnect_reason_len];
}

pub fn set_username(name: []const u8) void {
    const len: u8 = @intCast(@min(name.len, USERNAME_MAX));
    @memcpy(username_buf[0..len], name[0..len]);
    username_len = len;
}

pub fn username() []const u8 {
    return username_buf[0..username_len];
}

pub fn set_server(addr: []const u8) void {
    const len: u8 = @intCast(@min(addr.len, SERVER_MAX));
    @memcpy(server_buf[0..len], addr[0..len]);
    server_len = len;
}

pub fn server() []const u8 {
    return server_buf[0..server_len];
}

pub fn set_singleplayer_save(path: []const u8) void {
    const len: u16 = @intCast(@min(path.len, SAVE_PATH_MAX));
    @memcpy(singleplayer_save_buf[0..len], path[0..len]);
    singleplayer_save_len = len;
}

pub fn singleplayer_save() []const u8 {
    return singleplayer_save_buf[0..singleplayer_save_len];
}

pub fn set_singleplayer_seed_override(seed: ?u64) void {
    singleplayer_seed_override = seed;
}

pub fn clear_singleplayer_seed_override() void {
    singleplayer_seed_override = null;
}

pub fn singleplayer_seed(random_seed: u64) u64 {
    return singleplayer_seed_override orelse random_seed;
}

/// These presets affect only a newly generated world.
pub fn set_singleplayer_size(size: wd.WorldSize) void {
    singleplayer_size = size;
}

pub fn set_singleplayer_height(height: wd.WorldHeight) void {
    singleplayer_height = height;
}

pub fn clear_singleplayer_size_height() void {
    singleplayer_size = null;
    singleplayer_height = null;
}

pub fn seed_from_text(input: []const u8) ?u64 {
    const trimmed = std.mem.trim(u8, input, " ");
    if (trimmed.len == 0) return null;
    return fnv1a64(trimmed);
}

fn fnv1a64(input: []const u8) u64 {
    var hash: u64 = 0xcbf29ce484222325;
    for (input) |ch| {
        hash ^= ch;
        hash *%= 0x100000001b3;
    }
    return hash;
}

/// Either an already-resolved IP literal or a hostname that needs DNS
/// resolution at connect time. The hostname slice borrows from `server_buf`,
/// so the endpoint is only valid while `server_buf` is unchanged.
pub const ServerEndpoint = union(enum) {
    ip: std.Io.net.IpAddress,
    host: struct { name: []const u8, port: u16 },
};

/// Parse the stored server string. Accepts IPv4/IPv6 literals with or
/// without a port ("1.2.3.4", "1.2.3.4:25565", "[::1]:25") and bare
/// hostnames ("play.example.com", "play.example.com:25565"). When the port
/// is absent, defaults to `DEFAULT_PORT` (25565).
pub fn parse_server_endpoint() !ServerEndpoint {
    const input = server();
    if (input.len == 0) return error.EmptyHost;

    // parseLiteral reports port zero when none was supplied.
    if (std.Io.net.IpAddress.parseLiteral(input)) |parsed| {
        var addr = parsed;
        if (addr.getPort() == 0) addr.setPort(DEFAULT_PORT);
        return .{ .ip = addr };
    } else |_| {}

    // IPv6 was handled above, so the last colon unambiguously separates a port.
    var name = input;
    var port: u16 = DEFAULT_PORT;
    if (std.mem.lastIndexOfScalar(u8, input, ':')) |i| {
        if (std.fmt.parseInt(u16, input[i + 1 ..], 10)) |p| {
            name = input[0..i];
            port = p;
        } else |_| {}
    }
    if (name.len == 0) return error.EmptyHost;
    return .{ .host = .{ .name = name, .port = port } };
}

/// Connect to the parsed endpoint, resolving via DNS if it is a hostname.
pub fn connect_endpoint(ep: ServerEndpoint, io: std.Io) !std.Io.net.Stream {
    return switch (ep) {
        .ip => |addr| addr.connect(io, .{ .mode = .stream }),
        .host => |h| blk: {
            const hostname = try std.Io.net.HostName.init(h.name);
            break :blk hostname.connect(io, h.port, .{ .mode = .stream });
        },
    };
}

test "seed_from_text uses FNV-1a" {
    try std.testing.expectEqual(@as(?u64, 0x779a65e7023cd2e7), seed_from_text("hello world"));
    try std.testing.expectEqual(@as(?u64, 0x779a65e7023cd2e7), seed_from_text(" hello world "));
}

test "seed_from_text treats blank as no override" {
    try std.testing.expect(seed_from_text("") == null);
    try std.testing.expect(seed_from_text("   ") == null);
}

test "parse_server_endpoint handles literals and hostnames" {
    defer set_server("");

    set_server("127.0.0.1");
    switch (try parse_server_endpoint()) {
        .ip => |addr| try std.testing.expectEqual(DEFAULT_PORT, addr.getPort()),
        .host => return error.ExpectedIpAddress,
    }

    set_server("[::1]:25570");
    switch (try parse_server_endpoint()) {
        .ip => |addr| try std.testing.expectEqual(@as(u16, 25570), addr.getPort()),
        .host => return error.ExpectedIpAddress,
    }

    set_server("play.example.com:25571");
    switch (try parse_server_endpoint()) {
        .host => |host| {
            try std.testing.expectEqualStrings("play.example.com", host.name);
            try std.testing.expectEqual(@as(u16, 25571), host.port);
        },
        .ip => return error.ExpectedHostName,
    }

    set_server("");
    try std.testing.expectError(error.EmptyHost, parse_server_endpoint());
}
