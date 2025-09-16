const std = @import("std");

pub const IO = struct {
    pub const Connection = struct {
        reader: *std.io.Reader,
        writer: *std.io.Writer,
        connected: *bool,
    };

    pub const Listener = struct {
        pub const ConnectionHandle = struct {
            stream: std.net.Stream,
            address: std.net.Address,
            reader: std.net.Stream.Reader = undefined,
            writer: std.net.Stream.Writer = undefined,
            connected: bool = true,

            pub fn close(self: *const ConnectionHandle) void {
                self.stream.close();
            }

            pub fn to_connection(self: *ConnectionHandle, read_buffer: []u8, write_buffer: []u8) Connection {
                self.reader = self.stream.reader(read_buffer);
                self.writer = self.stream.writer(write_buffer);

                return .{
                    .reader = self.reader.interface(),
                    .writer = &self.writer.interface,
                    .connected = &self.connected,
                };
            }
        };

        stream: std.net.Stream,
        listen_address: std.net.Address,

        pub fn init(listen_address: std.net.Address) !Listener {
            const sock_flags = std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC | std.posix.SOCK.NONBLOCK;
            const proto: u32 = std.posix.IPPROTO.TCP;

            const sockfd = try std.posix.socket(listen_address.any.family, sock_flags, proto);

            try std.posix.setsockopt(sockfd, std.posix.SOL.SOCKET, std.posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));
            if (@hasDecl(std.posix.SO, "REUSEPORT")) {
                try std.posix.setsockopt(sockfd, std.posix.SOL.SOCKET, std.posix.SO.REUSEPORT, &std.mem.toBytes(@as(c_int, 1)));
            }

            var socklen = listen_address.getOsSockLen();
            try std.posix.bind(sockfd, &listen_address.any, socklen);
            try std.posix.listen(sockfd, 1);

            var s: Listener = .{
                .stream = .{ .handle = sockfd },
                .listen_address = undefined,
            };

            try std.posix.getsockname(sockfd, &s.listen_address.any, &socklen);
            return s;
        }

        pub fn deinit(self: *Listener) void {
            self.stream.close();
        }

        pub fn accept(self: *Listener) !ConnectionHandle {
            var accepted_addr: std.net.Address = undefined;
            var addr_len: std.posix.socklen_t = @sizeOf(std.net.Address);

            const fd = try std.posix.accept(self.stream.handle, &accepted_addr.any, &addr_len, std.posix.SOCK.CLOEXEC | std.posix.SOCK.NONBLOCK);
            return .{
                .stream = .{ .handle = fd },
                .address = accepted_addr,
            };
        }
    };
};
