const std = @import("std");

const log = std.log.scoped(.heartbeat);

pub const max_urls: usize = 8;
pub const max_url_len: usize = 512;
const max_config_len: usize = 4096;
const request_buffer_len = max_url_len + 384;
const redirect_buffer_len = 8 * 1024;
const retry_delays_ms = [_]i64{ 1_000, 2_000, 4_000 };

pub const Config = struct {
    urls: [max_urls][max_url_len]u8 = undefined,
    lens: [max_urls]u16 = @splat(0),
    count: usize = 0,

    pub fn load(io: std.Io, data_dir: std.Io.Dir) Config {
        const file = data_dir.openFile(io, "server.properties", .{}) catch return .{};
        defer file.close(io);

        var buf: [max_config_len]u8 = undefined;
        const len = file.readPositionalAll(io, &buf, 0) catch |err| {
            log.warn("Failed to read heartbeat configuration: {}", .{err});
            return .{};
        };
        if (len == buf.len) log.warn("server.properties may exceed the heartbeat configuration buffer", .{});

        var lines = std.mem.splitScalar(u8, buf[0..len], '\n');
        while (lines.next()) |raw_line| {
            const line = std.mem.trim(u8, raw_line, " \t\r");
            const key = "heartbeat-url:";
            if (std.mem.startsWith(u8, line, key)) return parse_url_list(line[key.len..]);
        }
        return .{};
    }
};

pub const RequestData = struct {
    server_name: []const u8,
    port: u16,
    users: u32,
    max_players: u32,
    salt: []const u8,
};

pub fn parse_url_list(value: []const u8) Config {
    var config: Config = .{};
    var parts = std.mem.splitScalar(u8, value, ',');

    while (parts.next()) |part| {
        const endpoint = std.mem.trim(u8, part, " \t\r");
        if (endpoint.len == 0) continue;
        if (endpoint.len > max_url_len) {
            log.warn("Ignoring heartbeat URL longer than {d} bytes", .{max_url_len});
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
        if (config.count == max_urls) {
            log.warn("Ignoring heartbeat URLs after the first {d}", .{max_urls});
            break;
        }

        @memcpy(config.urls[config.count][0..endpoint.len], endpoint);
        config.lens[config.count] = @intCast(endpoint.len);
        config.count += 1;
    }

    return config;
}

pub fn send(
    io: std.Io,
    client: *std.http.Client,
    endpoint: []const u8,
    data: RequestData,
) (std.http.Client.FetchError || error{BadStatus})!void {
    var url_buf: [request_buffer_len]u8 = undefined;
    const url = try build_url(endpoint, data, &url_buf);
    var redirect_buf: [redirect_buffer_len]u8 = undefined;

    var retry_index: usize = 0;
    while (true) {
        const result = client.fetch(.{
            .location = .{ .url = url },
            .method = .GET,
            .redirect_behavior = .not_allowed,
            .redirect_buffer = &redirect_buf,
            .keep_alive = false,
        }) catch |err| {
            if (retry_index == retry_delays_ms.len) return err;
            try io.sleep(.{ .nanoseconds = @as(i96, retry_delays_ms[retry_index]) * std.time.ns_per_ms }, .real);
            retry_index += 1;
            continue;
        };
        if (result.status.class() == .success) return;
        if (retry_index == retry_delays_ms.len) return error.BadStatus;
        try io.sleep(.{ .nanoseconds = @as(i96, retry_delays_ms[retry_index]) * std.time.ns_per_ms }, .real);
        retry_index += 1;
    }
}

pub fn build_url(endpoint: []const u8, data: RequestData, out: []u8) std.Io.Writer.Error![]const u8 {
    var writer = std.Io.Writer.fixed(out);
    const fragment_start = std.mem.indexOfScalar(u8, endpoint, '#') orelse endpoint.len;
    const base = endpoint[0..fragment_start];
    const fragment = endpoint[fragment_start..];
    const separator = if (base.len == 0 or base[base.len - 1] == '?' or base[base.len - 1] == '&') "" else if (std.mem.indexOfScalar(u8, base, '?') != null) "&" else "?";

    try writer.print("{s}{s}name=", .{ base, separator });
    try write_query_value(&writer, std.mem.trimEnd(u8, data.server_name, " \r\n"));
    try writer.print(
        "&port={d}&users={d}&max={d}&public=True&version=7&salt={s}&software=CrossCraft%20Classic&web=False{s}",
        .{ data.port, data.users, data.max_players, data.salt, fragment },
    );
    return writer.buffered();
}

fn write_query_value(writer: *std.Io.Writer, value: []const u8) std.Io.Writer.Error!void {
    for (value) |byte| switch (byte) {
        'A'...'Z', 'a'...'z', '0'...'9', '-', '.', '_', '~' => try writer.writeByte(byte),
        else => try writer.print("%{X:0>2}", .{byte}),
    };
}

test "heartbeat URL lists accept comma-separated HTTP endpoints" {
    const config = parse_url_list(" http://localhost:3000/api/v1/heartbeat, http://example.test/heartbeat ");
    try std.testing.expectEqual(@as(usize, 2), config.count);
    try std.testing.expectEqualStrings("http://localhost:3000/api/v1/heartbeat", config.urls[0][0..config.lens[0]]);
    try std.testing.expectEqualStrings("http://example.test/heartbeat", config.urls[1][0..config.lens[1]]);
}

test "heartbeat query values are escaped and existing queries are preserved" {
    var out: [request_buffer_len]u8 = undefined;
    const url = try build_url("http://localhost:3000/heartbeat?token=abc#fragment", .{
        .server_name = "A&B Server",
        .port = 25565,
        .users = 3,
        .max_players = 128,
        .salt = "0123456789ABCDEF",
    }, &out);

    try std.testing.expectEqualStrings(
        "http://localhost:3000/heartbeat?token=abc&name=A%26B%20Server&port=25565&users=3&max=128&public=True&version=7&salt=0123456789ABCDEF&software=CrossCraft%20Classic&web=False#fragment",
        url,
    );
}
