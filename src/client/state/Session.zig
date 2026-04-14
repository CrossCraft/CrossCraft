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

// ---------------------------------------------------------------------------
// Disconnect reason
// ---------------------------------------------------------------------------

/// Human-readable reason for the last disconnect, set before mp_connected is
/// cleared (or before quit_requested is set for the DisconnectPlayer packet).
/// Read by DisconnectState after it is entered. Not atomic -- written from
/// the read-loop thread under release/acquire ordering on mp_connected.
pub var disconnect_reason_buf: [64]u8 = undefined;
pub var disconnect_reason_len: u8 = 0;

pub fn set_disconnect_reason(reason: []const u8) void {
    const len: u8 = @intCast(@min(reason.len, disconnect_reason_buf.len));
    @memcpy(disconnect_reason_buf[0..len], reason[0..len]);
    disconnect_reason_len = len;
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
