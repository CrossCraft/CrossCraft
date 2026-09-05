const std = @import("std");
const players_db = @import("PlayersDb.zig");
const access_control = @import("AccessControl.zig");
const Server = @import("core").Server;

pub const Sink = struct {
    ctx: *anyopaque,
    write_fn: *const fn (ctx: *anyopaque, line: []const u8) void,

    pub fn write(self: Sink, line: []const u8) void {
        self.write_fn(self.ctx, line);
    }

    fn print(self: Sink, comptime fmt: []const u8, args: anytype, fallback: []const u8) void {
        var buf: [128]u8 = undefined;
        self.write(std.fmt.bufPrint(&buf, fmt, args) catch fallback);
    }
};

const Command = struct {
    name: []const u8,
    usage: []const u8,
    arguments: enum { none, single, with_reason } = .single,
    run: *const fn (Sink, []const u8, []const u8) void,
};

const commands = [_]Command{
    .{ .name = "help", .usage = "&e/help -- list commands", .arguments = .none, .run = cmd_help },
    .{ .name = "ipban", .usage = "&e/ipban <username> [reason] -- ban the IP of the connected username", .arguments = .with_reason, .run = cmd_ipban },
    .{ .name = "kick", .usage = "&e/kick <username> [reason] -- kick the connected username", .arguments = .with_reason, .run = cmd_kick },
    .{ .name = "ipop", .usage = "&e/ipop <username> -- grant op to the IP of the connected username", .run = cmd_ipop },
    .{ .name = "ipwhitelist", .usage = "&e/ipwhitelist <ip> -- add an IP to the whitelist", .run = cmd_ipwhitelist },
};

/// Dispatch text after the leading '/', gated by console/player privileges.
pub fn dispatch(sink: Sink, line: []const u8, is_op: bool) void {
    if (!is_op) {
        sink.write("&cFailed to process command: Insufficient permission");
        return;
    }

    var tok = std.mem.tokenizeAny(u8, line, " \t");
    const cmd = tok.next() orelse {
        sink.write("Unknown command, use /help");
        return;
    };

    for (commands) |command| {
        if (std.mem.eql(u8, cmd, command.name)) {
            const argument = tok.next();
            const reason = std.mem.trimEnd(u8, tok.rest(), " \t");
            if (command.arguments != .none and
                (argument == null or (command.arguments == .single and reason.len != 0)))
            {
                sink.write(command.usage);
                return;
            }
            command.run(sink, argument orelse "", reason);
            return;
        }
    }
    sink.write("Unknown command, use /help");
}

fn cmd_help(sink: Sink, _: []const u8, _: []const u8) void {
    for (commands) |command| sink.write(command.usage);
}

fn cmd_ipban(sink: Sink, username: []const u8, reason: []const u8) void {
    const target = find_client(sink, username) orelse return;

    const ip = target.ip_slice();
    if (ip.len == 0) {
        sink.write("Client has no recorded IP (local connection?)");
        return;
    }

    access_control.set_banned(ip, true, if (reason.len > 0) reason else "Banned") catch |err| {
        report_policy_error(sink, err);
        return;
    };
    const dc_reason = if (reason.len > 0) reason else "You have been banned";
    _ = Server.disconnect_handle(target.handle, dc_reason);

    sink.print("Banned {s} ({s})", .{ username, ip }, "Banned");
}

fn cmd_kick(sink: Sink, username: []const u8, reason: []const u8) void {
    const target = find_client(sink, username) orelse return;

    const dc_reason = if (reason.len > 0) reason else "Kicked";
    _ = Server.disconnect_handle(target.handle, dc_reason);

    sink.print("Kicked {s}", .{username}, "Kicked");
}

fn cmd_ipop(sink: Sink, username: []const u8, _: []const u8) void {
    const target = find_client(sink, username) orelse return;

    const ip = target.ip_slice();
    if (ip.len == 0) {
        sink.write("Client has no recorded IP (local connection?)");
        return;
    }

    access_control.set_flag(ip, .op, true) catch |err| {
        report_policy_error(sink, err);
        return;
    };
    _ = Server.grant_op_handle(target.handle);

    sink.print("Granted op to {s} ({s})", .{ username, ip }, "Granted op");
}

fn cmd_ipwhitelist(sink: Sink, ip_text: []const u8, _: []const u8) void {
    var canon_buf: [players_db.ip_str_len]u8 = undefined;
    const address = std.Io.net.IpAddress.parseIp4(ip_text, 0) catch {
        sink.print("Invalid IP literal: {s}", .{ip_text}, "Invalid IP");
        return;
    };
    const canon = players_db.format_ip(address, &canon_buf).?;

    access_control.set_flag(canon, .whitelisted, true) catch |err| {
        report_policy_error(sink, err);
        return;
    };

    sink.print("Whitelisted {s}", .{canon}, "Whitelisted");
}

fn find_client(sink: Sink, username: []const u8) ?Server.ClientSnapshot {
    return Server.find_client_by_name(username) orelse {
        sink.print("User '{s}' is not connected", .{username}, "User not connected");
        return null;
    };
}

fn report_policy_error(sink: Sink, err: anyerror) void {
    switch (err) {
        error.PolicyStoreFull => sink.write("&cAccess-control store is full; raise max-policy-records and restart the server"),
        else => sink.write("&cFailed to persist access-control policy"),
    }
}

test "commands require privileges before changing persistent policy" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try access_control.init(std.testing.allocator, io, tmp.dir, 1);
    defer access_control.deinit();

    var output: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output);
    const sink: Sink = .{ .ctx = &writer, .write_fn = struct {
        fn write(ctx: *anyopaque, line: []const u8) void {
            const out: *std.Io.Writer = @ptrCast(@alignCast(ctx));
            out.writeAll(line) catch unreachable;
        }
    }.write };

    dispatch(sink, "ipwhitelist 203.0.113.10", false);
    try std.testing.expectEqualStrings("&cFailed to process command: Insufficient permission", writer.buffered());
    try std.testing.expect(!access_control.lookup("203.0.113.10").whitelisted);

    writer.end = 0;
    dispatch(sink, "ipwhitelist 203.0.113.10 extra", true);
    try std.testing.expectEqualStrings("&e/ipwhitelist <ip> -- add an IP to the whitelist", writer.buffered());
    try std.testing.expect(!access_control.lookup("203.0.113.10").whitelisted);

    writer.end = 0;
    dispatch(sink, "ipwhitelist 203.0.113.10", true);
    try std.testing.expectEqualStrings("Whitelisted 203.0.113.10", writer.buffered());
    try std.testing.expect(access_control.lookup("203.0.113.10").whitelisted);
}
