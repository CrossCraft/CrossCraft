const std = @import("std");
const Accounts = @import("Accounts.zig");
const Authentication = @import("Authentication.zig");
const Server = @import("core").Server;

pub const Sink = struct {
    ctx: *anyopaque,
    write_fn: *const fn (ctx: *anyopaque, line: []const u8) void,

    pub fn write(self: Sink, line: []const u8) void {
        self.write_fn(self.ctx, line);
    }
};

pub const Caller = union(enum) { console, player: *Server.Client };
const Kind = enum { help, register, login, passwd, resetpassword, ban, unban, op, deop, whitelist, unwhitelist, kick };
const Command = struct { kind: Kind, usage: []const u8 };
const commands = [_]Command{
    .{ .kind = .help, .usage = "&e/help -- list commands" },
    .{ .kind = .register, .usage = "&e/register <pass> <pass>" },
    .{ .kind = .login, .usage = "&e/login <pass>" },
    .{ .kind = .passwd, .usage = "&e/passwd <old> <new>" },
    .{ .kind = .resetpassword, .usage = "&e/resetpassword <username> <new> -- console only" },
    .{ .kind = .ban, .usage = "&e/ban <username> [reason]" },
    .{ .kind = .unban, .usage = "&e/unban <username>" },
    .{ .kind = .op, .usage = "&e/op <username>" },
    .{ .kind = .deop, .usage = "&e/deop <username>" },
    .{ .kind = .whitelist, .usage = "&e/whitelist <username>" },
    .{ .kind = .unwhitelist, .usage = "&e/unwhitelist <username>" },
    .{ .kind = .kick, .usage = "&e/kick <username> [reason]" },
};

fn can_moderate(caller: Caller) bool {
    return switch (caller) {
        .console => true,
        .player => |client| client.session_open() and client.authenticated.load(.acquire) and client.is_op.load(.acquire),
    };
}

fn allowed(caller: Caller, kind: Kind) bool {
    return switch (kind) {
        .help => true,
        .register, .login => Authentication.mode == .local and caller == .player,
        .passwd => Authentication.mode == .local and caller == .player and caller.player.authenticated.load(.acquire),
        .resetpassword => Authentication.mode == .local and caller == .console,
        else => can_moderate(caller),
    };
}

/// Never log command text: it may contain a password, even on syntax errors.
pub fn dispatch(sink: Sink, line: []const u8, caller: Caller) void {
    var tokens = std.mem.tokenizeAny(u8, line, " \t");
    const name = tokens.next() orelse {
        sink.write("Unknown command, use /help");
        return;
    };
    const command = for (commands) |command| {
        if (std.mem.eql(u8, name, @tagName(command.kind))) break command;
    } else {
        sink.write("Unknown command, use /help");
        return;
    };
    if (!allowed(caller, command.kind)) {
        sink.write("&cCommand unavailable or insufficient permission");
        return;
    }
    const first = tokens.next();
    const second = if (command.kind == .ban or command.kind == .kick)
        std.mem.trimEnd(u8, tokens.rest(), " \t")
    else
        tokens.next();
    const argument_count: u8 = switch (command.kind) {
        .help => 0,
        .register, .passwd, .resetpassword => 2,
        else => 1,
    };
    const with_reason = command.kind == .ban or command.kind == .kick;
    if ((argument_count == 0 and first != null) or
        (argument_count > 0 and first == null) or
        (argument_count == 2 and second == null) or
        (!with_reason and ((argument_count < 2 and second != null) or tokens.next() != null)))
    {
        sink.write(command.usage);
        return;
    }
    run(sink, caller, command.kind, first orelse "", second orelse "") catch |err| report_error(sink, err);
}

fn run(sink: Sink, caller: Caller, kind: Kind, first: []const u8, second: []const u8) !void {
    switch (kind) {
        .help => for (commands) |command| {
            if (!allowed(caller, command.kind)) continue;
            if (caller == .player and caller.player.authenticated.load(.acquire) and
                (command.kind == .register or command.kind == .login)) continue;
            sink.write(command.usage);
        },
        .register => try Authentication.execute(caller.player, .register, first, second),
        .login => try Authentication.execute(caller.player, .login, first, second),
        .passwd => try Authentication.execute(caller.player, .passwd, first, second),
        .resetpassword => {
            try Authentication.reset_password(first, second);
            sink.write("Password reset");
        },
        else => try moderate(sink, caller, kind, first, second),
    }
}

fn moderate(sink: Sink, caller: Caller, kind: Kind, username: []const u8, reason: []const u8) !void {
    if (!Server.Client.valid_username(username)) return error.InvalidUsername;
    Authentication.lock_actions();
    defer Authentication.unlock_actions();

    if (!can_moderate(caller)) return error.InsufficientPermission;
    switch (kind) {
        .ban => try Accounts.set_policy(username, .banned, true, if (reason.len > 0) reason else "You have been banned"),
        .unban => try Accounts.set_policy(username, .banned, false, ""),
        .op, .deop => try Accounts.set_policy(username, .op, kind == .op, ""),
        .whitelist, .unwhitelist => try Accounts.set_policy(username, .whitelisted, kind == .whitelist, ""),
        .kick => {},
        else => unreachable,
    }
    const target = Server.find_client_by_name(username);
    if (kind == .kick and target == null) {
        sink.write("User is not connected");
        return;
    }
    if (target) |connected| switch (kind) {
        .ban, .kick => {
            _ = Server.disconnect_handle(connected.handle, if (reason.len > 0) reason else @tagName(kind));
        },
        .op, .deop => {
            _ = Server.set_op_handle(connected.handle, kind == .op);
        },
        else => {},
    };
    sink.write("Command completed");
}

fn report_error(sink: Sink, err: anyerror) void {
    sink.write(switch (err) {
        error.InvalidUsername => "&cUsernames must be 1-16 letters, digits or underscores",
        error.InvalidPassword => "&cPasswords must be 8-26 printable characters without spaces",
        error.PasswordsDoNotMatch => "&cPasswords do not match",
        error.WrongPassword => "&cIncorrect password",
        error.AlreadyRegistered => "&cAlready registered; use /login <pass>",
        error.NotRegistered => "&cUsername is not registered",
        error.AlreadyAuthenticated => "&cAlready logged in; use /passwd <old> <new>",
        error.LoginRequired => "&cLog in first",
        error.AuthenticationBusy => "&eAuthentication is busy; try again shortly",
        error.AuthenticationThrottled => "&eWait one second between password checks",
        error.AuthenticationDisabled => "&cPassword authentication is disabled",
        error.CredentialsChanged => "&cCredentials changed; try again",
        error.AccountStoreFull => "&cAccount store full; raise max-accounts and restart",
        error.SessionClosed => "&cAuthentication session ended",
        error.InsufficientPermission => "&cInsufficient permission",
        else => "&cCould not complete the account operation",
    });
}

test "auth commands enforce caller permissions and exact arguments" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    Server.io = std.testing.io;
    Server.players = .{};
    defer Server.players = .{};

    try Accounts.init(std.testing.allocator, Server.io, tmp.dir, 4);
    defer Accounts.deinit();

    try Authentication.init(std.testing.allocator, .none, 30, false);
    defer Authentication.deinit();

    var output: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output);
    const sink: Sink = .{ .ctx = &writer, .write_fn = struct {
        fn write(ctx: *anyopaque, line: []const u8) void {
            const target: *std.Io.Writer = @ptrCast(@alignCast(ctx));
            target.writeAll(line) catch unreachable;
        }
    }.write };
    var reader = std.Io.Reader.fixed(&.{});
    var connected = true;
    var client: Server.Client = .{
        .reader = &reader,
        .writer = &writer,
        .connected = &connected,
        .phase = .init(.active),
        .authenticated = .init(false),
        .is_op = .init(true),
    };
    dispatch(sink, "op Alice", .{ .player = &client });
    try std.testing.expect(!Accounts.lookup("Alice").op);
    writer.end = 0;
    dispatch(sink, "op Alice extra", .console);
    try std.testing.expectEqualStrings("&e/op <username>", writer.buffered());
    try std.testing.expect(!Accounts.lookup("Alice").op);
    writer.end = 0;
    dispatch(sink, "op Alice", .console);
    try std.testing.expect(Accounts.lookup("Alice").op);
    dispatch(sink, "ban alice a complete reason", .console);
    try std.testing.expectEqualStrings("a complete reason", Accounts.lookup("alice").ban_reason());
    try std.testing.expect(!Accounts.lookup("Alice").banned);
    dispatch(sink, "unban alice", .console);
    try std.testing.expect(!Accounts.lookup("alice").banned);
    dispatch(sink, "deop Alice", .console);
    try std.testing.expect(!Accounts.lookup("Alice").op);
    dispatch(sink, "whitelist Alice", .console);
    try std.testing.expect(Accounts.lookup("Alice").whitelisted);
    dispatch(sink, "unwhitelist Alice", .console);
    try std.testing.expect(!Accounts.lookup("Alice").whitelisted);
    writer.end = 0;
    dispatch(sink, "ipop Alice", .console);
    try std.testing.expectEqualStrings("Unknown command, use /help", writer.buffered());
    writer.end = 0;
    Authentication.mode = .local;
    dispatch(sink, "resetpassword Alice private-password", .{ .player = &client });
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "private-password") == null);
    try std.testing.expect(Accounts.lookup("Alice").credential == null);
    writer.end = 0;
    dispatch(sink, "register private-password private-password", .console);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "private-password") == null);
    try std.testing.expect(Accounts.lookup("Alice").credential == null);
}
