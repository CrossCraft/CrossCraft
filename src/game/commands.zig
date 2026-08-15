const std = @import("std");
const players_db = @import("players_db.zig");
const access_control = @import("access_control.zig");
const Server = @import("server.zig");

const log = std.log.scoped(.commands);

// --- Sink: console-side stdout writer or in-game per-client chat reply ---

pub const Sink = struct {
    ctx: *anyopaque,
    write_fn: *const fn (ctx: *anyopaque, line: []const u8) void,

    pub fn write(self: Sink, line: []const u8) void {
        self.write_fn(self.ctx, line);
    }
};

// --- Help text: single source of truth ---

const HelpLine = struct {
    name: []const u8,
    usage: []const u8, // formatted as "&e/<usage> -- <explain>"
};

const help_lines = [_]HelpLine{
    .{ .name = "help", .usage = "&e/help -- list commands" },
    .{ .name = "ipban", .usage = "&e/ipban <username> [reason] -- ban the IP of the connected username" },
    .{ .name = "kick", .usage = "&e/kick <username> [reason] -- kick the connected username" },
    .{ .name = "ipop", .usage = "&e/ipop <username> -- grant op to the IP of the connected username" },
    .{ .name = "ipwhitelist", .usage = "&e/ipwhitelist <ip> -- add an IP to the whitelist" },
};

fn help_for(name: []const u8) ?[]const u8 {
    for (help_lines) |h| {
        if (std.mem.eql(u8, h.name, name)) return h.usage;
    }
    return null;
}

// --- Public dispatch ---

/// `line` is the raw text after the leading '/'. `is_op` is true for the
/// console (always) and for in-game players whose record has op = true
/// (or for singleplayer, where the local player is implicitly op).
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

    if (std.mem.eql(u8, cmd, "help")) {
        cmd_help(sink);
    } else if (std.mem.eql(u8, cmd, "ipban")) {
        cmd_ipban(sink, &tok);
    } else if (std.mem.eql(u8, cmd, "kick")) {
        cmd_kick(sink, &tok);
    } else if (std.mem.eql(u8, cmd, "ipop")) {
        cmd_ipop(sink, &tok);
    } else if (std.mem.eql(u8, cmd, "ipwhitelist")) {
        cmd_ipwhitelist(sink, &tok);
    } else {
        sink.write("Unknown command, use /help");
    }
}

// --- Commands ---

fn cmd_help(sink: Sink) void {
    for (help_lines) |h| sink.write(h.usage);
}

fn cmd_ipban(sink: Sink, tok: *std.mem.TokenIterator(u8, .any)) void {
    const username = tok.next() orelse {
        sink.write(help_for("ipban").?);
        return;
    };
    const reason = rest_of(tok);

    const client = Server.find_client_by_name(username) orelse {
        var buf: [80]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "User '{s}' is not connected", .{username}) catch "User not connected";
        sink.write(msg);
        return;
    };

    const ip = client.ip_slice();
    if (ip.len == 0) {
        sink.write("Client has no recorded IP (local connection?)");
        return;
    }

    access_control.set_banned(ip, true, if (reason.len > 0) reason else "Banned") catch |err| {
        report_policy_error(sink, err);
        return;
    };
    const dc_reason = if (reason.len > 0) reason else "You have been banned";
    client.send_disconnect(dc_reason) catch {};

    var out_buf: [128]u8 = undefined;
    const msg = std.fmt.bufPrint(&out_buf, "Banned {s} ({s})", .{ username, ip }) catch "Banned";
    sink.write(msg);
}

fn cmd_kick(sink: Sink, tok: *std.mem.TokenIterator(u8, .any)) void {
    const username = tok.next() orelse {
        sink.write(help_for("kick").?);
        return;
    };
    const reason = rest_of(tok);

    const client = Server.find_client_by_name(username) orelse {
        var buf: [80]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "User '{s}' is not connected", .{username}) catch "User not connected";
        sink.write(msg);
        return;
    };

    const dc_reason = if (reason.len > 0) reason else "Kicked";
    client.send_disconnect(dc_reason) catch {};

    var out_buf: [80]u8 = undefined;
    const msg = std.fmt.bufPrint(&out_buf, "Kicked {s}", .{username}) catch "Kicked";
    sink.write(msg);
}

fn cmd_ipop(sink: Sink, tok: *std.mem.TokenIterator(u8, .any)) void {
    const username = tok.next() orelse {
        sink.write(help_for("ipop").?);
        return;
    };
    if (tok.next() != null) {
        sink.write(help_for("ipop").?);
        return;
    }

    const client = Server.find_client_by_name(username) orelse {
        var buf: [80]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "User '{s}' is not connected", .{username}) catch "User not connected";
        sink.write(msg);
        return;
    };

    const ip = client.ip_slice();
    if (ip.len == 0) {
        sink.write("Client has no recorded IP (local connection?)");
        return;
    }

    access_control.set_op(ip, true) catch |err| {
        report_policy_error(sink, err);
        return;
    };
    client.is_op = true;
    client.send_update_player_type(true) catch {};

    var out_buf: [128]u8 = undefined;
    const msg = std.fmt.bufPrint(&out_buf, "Granted op to {s} ({s})", .{ username, ip }) catch "Granted op";
    sink.write(msg);
}

fn cmd_ipwhitelist(sink: Sink, tok: *std.mem.TokenIterator(u8, .any)) void {
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
        var buf: [80]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Invalid IP literal: {s}", .{ip_text}) catch "Invalid IP";
        sink.write(msg);
        return;
    };

    access_control.set_whitelisted(canon, true) catch |err| {
        report_policy_error(sink, err);
        return;
    };

    var out_buf: [80]u8 = undefined;
    const msg = std.fmt.bufPrint(&out_buf, "Whitelisted {s}", .{canon}) catch "Whitelisted";
    sink.write(msg);
}

// --- Helpers ---

/// Return the remainder of `tok` (everything from the current cursor to
/// the end of the source string) trimmed of surrounding whitespace.
fn rest_of(tok: *std.mem.TokenIterator(u8, .any)) []const u8 {
    if (tok.index >= tok.buffer.len) return "";
    const tail = tok.buffer[tok.index..];
    return std.mem.trim(u8, tail, " \t");
}

fn report_policy_error(sink: Sink, err: anyerror) void {
    if (err == error.PolicyStoreFull) {
        sink.write("&cAccess-control store is full; raise max-policy-records and restart the server");
    } else {
        sink.write("&cFailed to persist access-control policy");
    }
}
