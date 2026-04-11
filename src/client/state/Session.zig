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

pub var mode: Mode = .singleplayer;

pub var username_buf: [USERNAME_MAX]u8 = undefined;
pub var username_len: u8 = 0;

pub var server_buf: [SERVER_MAX]u8 = undefined;
pub var server_len: u8 = 0;

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

/// Parse the stored server string into an `IpAddress`. Accepts IPv4/IPv6
/// literals with or without a port ("1.2.3.4", "1.2.3.4:25565", "[::1]:25").
/// When the port is absent, defaults to `DEFAULT_PORT` (25565). Hostnames
/// are not supported yet; the caller must provide a literal address.
pub fn parse_server_address() !std.Io.net.IpAddress {
    const input = server();
    if (input.len == 0) return error.EmptyHost;

    // parseLiteral returns port 0 if the user did not specify one (for IPv4
    // without a colon, or IPv6 brackets with no trailing :port). Detect that
    // case and substitute our default so "127.0.0.1" or "[::1]" both work.
    var addr = try std.Io.net.IpAddress.parseLiteral(input);
    if (addr.getPort() == 0) addr.setPort(DEFAULT_PORT);
    return addr;
}
