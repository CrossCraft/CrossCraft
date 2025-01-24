//! General Purpose IO interface
//! TODO: Make this a VTable

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

const Self = @This();

pub fn init() !Self {
    if (builtin.os.tag == .windows) {
        _ = try std.os.windows.WSAStartup(2, 2);
    }

    return .{};
}

pub fn deinit(self: *Self) void {
    self.* = undefined;
}

fn set_nonblocking(socket: posix.socket_t) !void {
    if (builtin.os.tag != .windows) {
        const flags = try posix.fcntl(socket, posix.F.GETFL, 0);
        const nb = posix.O{
            .NONBLOCK = true,
        };

        _ = try posix.fcntl(socket, posix.F.SETFL, flags | @as(u32, @bitCast(nb)));
    } else {
        var mode: u32 = 1;
        if (std.os.windows.ws2_32.ioctlsocket(socket, std.os.windows.ws2_32.FIONBIO, &mode) == std.os.windows.ws2_32.SOCKET_ERROR) {
            return error.WindowsFailedNonblocking;
        }
    }
}

/// Creates a server socket, binds and listens.
/// `ip` IP address in little endian
/// `port` Port number in little endian
/// These will automatically be byteswapped
pub fn create_server_socket(self: *Self, ip: u32, port: u16) !posix.socket_t {
    _ = self;

    // Create a socket
    const socket = try posix.socket(posix.AF.INET, posix.SOCK.STREAM, 0);

    // Let it bind over previous instance
    const true_flag: u32 = 1;
    if (builtin.os.tag == .windows) {
        try posix.setsockopt(socket, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(true_flag));
    } else {
        try posix.setsockopt(socket, posix.SOL.SOCKET, posix.SO.REUSEPORT, &std.mem.toBytes(true_flag));
    }

    try set_nonblocking(socket);

    const addr = posix.sockaddr.in{
        .addr = @byteSwap(ip),
        .port = @byteSwap(port),
    };

    try posix.bind(socket, @ptrCast(&addr), @sizeOf(posix.sockaddr.in));
    try posix.listen(socket, 1);

    return socket;
}

/// Close a socket
pub fn close_socket(self: *Self, socket: posix.socket_t) void {
    _ = self;
    posix.close(socket);
}

pub const Connection = struct {
    address: posix.sockaddr.in = undefined,
    socket: posix.socket_t,

    pub fn write(self: *Connection, buf: []u8) !void {
        try posix.write(self.socket, buf, 0);
    }

    pub fn read(self: *Connection, buf: []u8) !bool {
        const recv_size = posix.recv(self.socket, buf[0..1], posix.MSG.PEEK) catch |e| {
            switch (e) {
                error.WouldBlock => {
                    return false;
                },
                else => {
                    return e;
                },
            }
        };

        // This is true as far as I know -- peeking when no data results in EWOULDBLOCK/EAGAIN; Other errors are handled
        if (recv_size == 0) {
            return error.ConnectionDropped;
        }

        const len: u8 = switch (buf[0]) {
            0x00 => 131,
            0x05 => 9,
            0x08 => 10,
            0x0D => 66,
            else => return error.InvalidPacketID,
        };

        _ = posix.recv(self.socket, buf[0..len], posix.MSG.PEEK) catch |e| {
            switch (e) {
                error.WouldBlock => {
                    return false;
                },
                else => {
                    return e;
                },
            }
        };

        _ = try posix.recv(self.socket, buf[0..len], 0);
        return true;
    }
};

/// Accept a connection
pub fn accept(self: *Self, socket: posix.socket_t) !?Connection {
    _ = self;

    var address: posix.sockaddr.in = undefined;
    var addr_len: u32 = @sizeOf(posix.sockaddr.in);

    const client_socket = posix.accept(socket, @ptrCast(&address), &addr_len, 0) catch |e| {
        switch (e) {
            error.WouldBlock => {
                return null;
            },
            else => return e,
        }
    };

    try set_nonblocking(client_socket);

    return Connection{
        .address = address,
        .socket = client_socket,
    };
}
