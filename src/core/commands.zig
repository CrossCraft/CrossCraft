const std = @import("std");
const players_db = @import("players_db.zig");
const access_control = @import("access_control.zig");
const Server = @import("server.zig");

const log = std.log.scoped(.commands);

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

const Tokens = std.mem.TokenIterator(u8, .any);

const Command = struct {
    name: []const u8,
    usage: []const u8,
    run: *const fn (Sink, *Tokens) void,
};

const commands = [_]Command{
    .{ .name = "help", .usage = "&e/help -- list commands", .run = cmd_help },
    .{ .name = "ipban", .usage = "&e/ipban <username> [reason] -- ban the IP of the connected username", .run = cmd_ipban },
    .{ .name = "kick", .usage = "&e/kick <username> [reason] -- kick the connected username", .run = cmd_kick },
    .{ .name = "ipop", .usage = "&e/ipop <username> -- grant op to the IP of the connected username", .run = cmd_ipop },
    .{ .name = "ipwhitelist", .usage = "&e/ipwhitelist <ip> -- add an IP to the whitelist", .run = cmd_ipwhitelist },
};

fn help_for(name: []const u8) ?[]const u8 {
    for (commands) |command| {
        if (std.mem.eql(u8, command.name, name)) return command.usage;
    }
    return null;
}

/// Dispatch text after the leading '/', gated by console/player privileges.
pub fn dispatch(sink: Sink, line: []const u8, is_op: bool) void {
    if (!is_op) {
        sink.write("&cFailed to process command: Insufficient permission");
        return;
    }

    const trimmed = std.mem.trim(u8, line, " \t");
    if (trimmed.len == 0) {
        sink.write("Unknown command, use /help");
        return;
    }

    var tok = std.mem.tokenizeAny(u8, trimmed, " \t");
    const cmd = tok.next() orelse {
        sink.write("Unknown command, use /help");
        return;
    };

    for (commands) |command| {
        if (std.mem.eql(u8, cmd, command.name)) {
            command.run(sink, &tok);
            return;
        }
    }
    sink.write("Unknown command, use /help");
}

fn cmd_help(sink: Sink, _: *Tokens) void {
    for (commands) |command| sink.write(command.usage);
}

fn cmd_ipban(sink: Sink, tok: *Tokens) void {
    const username = tok.next() orelse {
        sink.write(help_for("ipban").?);
        return;
    };
    const reason = rest_of(tok);

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

fn cmd_kick(sink: Sink, tok: *Tokens) void {
    const username = tok.next() orelse {
        sink.write(help_for("kick").?);
        return;
    };
    const reason = rest_of(tok);

    const target = find_client(sink, username) orelse return;

    const dc_reason = if (reason.len > 0) reason else "Kicked";
    _ = Server.disconnect_handle(target.handle, dc_reason);

    sink.print("Kicked {s}", .{username}, "Kicked");
}

fn cmd_ipop(sink: Sink, tok: *Tokens) void {
    const username = tok.next() orelse {
        sink.write(help_for("ipop").?);
        return;
    };
    if (tok.next() != null) {
        sink.write(help_for("ipop").?);
        return;
    }

    const target = find_client(sink, username) orelse return;

    const ip = target.ip_slice();
    if (ip.len == 0) {
        sink.write("Client has no recorded IP (local connection?)");
        return;
    }

    access_control.set_op(ip, true) catch |err| {
        report_policy_error(sink, err);
        return;
    };
    _ = Server.grant_op_handle(target.handle);

    sink.print("Granted op to {s} ({s})", .{ username, ip }, "Granted op");
}

fn cmd_ipwhitelist(sink: Sink, tok: *Tokens) void {
    const ip_text = tok.next() orelse {
        sink.write(help_for("ipwhitelist").?);
        return;
    };
    if (tok.next() != null) {
        sink.write(help_for("ipwhitelist").?);
        return;
    }

    var canon_buf: [players_db.ip_str_len]u8 = undefined;
    const canon = players_db.canonicalise_literal(ip_text, &canon_buf) orelse {
        sink.print("Invalid IP literal: {s}", .{ip_text}, "Invalid IP");
        return;
    };

    access_control.set_whitelisted(canon, true) catch |err| {
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

fn rest_of(tok: *Tokens) []const u8 {
    if (tok.index >= tok.buffer.len) return "";
    const tail = tok.buffer[tok.index..];
    return std.mem.trim(u8, tail, " \t");
}

fn report_policy_error(sink: Sink, err: anyerror) void {
    switch (err) {
        error.PolicyStoreFull => sink.write("&cAccess-control store is full; raise max-policy-records and restart the server"),
        else => sink.write("&cFailed to persist access-control policy"),
    }
}
