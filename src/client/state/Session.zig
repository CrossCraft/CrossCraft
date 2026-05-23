/// Shared session state between MenuState, LoadState, and GameState.
///
/// Holds the user's chosen mode (SP vs MP), their username, the raw server
/// address string from the direct-connect screen, and - once LoadState has
/// opened the socket - the live TCP stream plus its Reader/Writer that
/// GameState picks up.
const std = @import("std");

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

// Live TCP stream carried from LoadState into GameState. Null in SP, or
// before a successful connect(), or after a disconnect. GameState spawns
// a background read-loop task that owns `mp_reader` once it picks the
// stream up; the game thread only touches `mp_writer`.
pub var mp_stream: ?std.Io.net.Stream = null;
pub var mp_read_buf: [4096]u8 = undefined;
pub var mp_write_buf: [4096]u8 = undefined;
pub var mp_reader: std.Io.net.Stream.Reader = undefined;
pub var mp_writer: std.Io.net.Stream.Writer = undefined;

/// Flipped to false by the async read loop on EOF/error. Callbacks and
/// the disconnect handler observe it so the main loop can request quit.
pub var mp_connected: std.atomic.Value(bool) = .init(false);

// --- Disconnect reason ---

/// Human-readable reason for the last disconnect, set before mp_connected is
/// cleared (or before quit_requested is set for the DisconnectPlayer packet).
/// Read by DisconnectState after it is entered. Not atomic -- written from
/// the read-loop thread under release/acquire ordering on mp_connected.
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

    // Try literal IP first. parseLiteral returns port 0 if the user did not
    // specify one; substitute the default so "127.0.0.1" or "[::1]" work.
    if (std.Io.net.IpAddress.parseLiteral(input)) |parsed| {
        var addr = parsed;
        if (addr.getPort() == 0) addr.setPort(DEFAULT_PORT);
        return .{ .ip = addr };
    } else |_| {}

    // Fallback: treat as hostname[:port]. Hostnames cannot contain ':', so
    // splitting on the last colon is unambiguous (IPv6 literals are handled
    // by the parseLiteral branch above).
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

test "seed_from_text hashes nonblank text deterministically" {
    const a = seed_from_text("hello world") orelse return error.ExpectedSeed;
    const b = seed_from_text("hello world") orelse return error.ExpectedSeed;
    const c = seed_from_text("other world") orelse return error.ExpectedSeed;
    try std.testing.expectEqual(a, b);
    try std.testing.expect(a != c);
}

test "seed_from_text treats blank as no override" {
    try std.testing.expect(seed_from_text("") == null);
    try std.testing.expect(seed_from_text("   ") == null);
}

test "singleplayer_seed uses override when present" {
    clear_singleplayer_seed_override();
    try std.testing.expectEqual(@as(u64, 123), singleplayer_seed(123));
    set_singleplayer_seed_override(456);
    try std.testing.expectEqual(@as(u64, 456), singleplayer_seed(123));
    clear_singleplayer_seed_override();
}
