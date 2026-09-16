//! Shared native/plugin command registry. Native authentication and
//! moderation commands keep their original synchronous routing and sensitive
//! text handling; plugin commands dispatch through the host's ordered gameplay
//! context.
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
pub const Permission = enum { anyone, op };
pub const Restriction = enum { any, player_only, console_only };

/// Plugin commands resolve through a host-owned dispatch shim so the registry
/// stays independent of the Luau runtime.
pub const ScriptDispatch = struct {
    ctx: *anyopaque,
    call: *const fn (ctx: *anyopaque, caller: Caller, args: []const []const u8) void,
};

const Handler = union(enum) { native: Kind, script: ScriptDispatch };

const NameBuf = struct {
    buf: [16]u8 = @splat(0),
    len: u8 = 0,

    fn set(self: *NameBuf, text: []const u8) bool {
        if (text.len == 0 or text.len > self.buf.len) return false;
        for (text) |c| {
            if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
        }
        @memcpy(self.buf[0..text.len], text);
        self.len = @intCast(text.len);
        return true;
    }

    fn slice(self: *const NameBuf) []const u8 {
        return self.buf[0..self.len];
    }
};

const UsageBuf = struct {
    buf: [96]u8 = @splat(0),
    len: u8 = 0,

    fn set(self: *UsageBuf, text: []const u8) bool {
        if (text.len == 0 or text.len > self.buf.len) return false;
        @memcpy(self.buf[0..text.len], text);
        self.len = @intCast(text.len);
        return true;
    }

    fn slice(self: *const UsageBuf) []const u8 {
        return self.buf[0..self.len];
    }
};

pub const Registration = struct {
    name: []const u8,
    aliases: []const []const u8 = &.{},
    usage: []const u8,
    permission: Permission = .anyone,
    restriction: Restriction = .any,
    script: ?ScriptDispatch = null,
};

const Kind = enum { help, register, login, passwd, resetpassword, ban, unban, op, deop, whitelist, unwhitelist, kick };
const max_entries = 64;
const max_aliases = 4;

const Entry = struct {
    name: NameBuf = .{},
    aliases: [max_aliases]NameBuf = @splat(.{}),
    alias_count: u8 = 0,
    usage: UsageBuf = .{},
    permission: Permission = .anyone,
    restriction: Restriction = .any,
    handler: Handler = .{ .native = .help },
    owner: ?*const anyopaque = null,
    enabled: bool = true,
};

var registry_lock: std.Io.RwLock = .init;
var entries: [max_entries]Entry = @splat(.{});
var entry_count: usize = 0;
var native_registered = false;

const native_usages = [_]struct { kind: Kind, usage: []const u8 }{
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

fn native_restriction(kind: Kind) Restriction {
    return switch (kind) {
        .resetpassword => .console_only,
        .register, .login, .passwd, .help => .player_only,
        else => .any,
    };
}

fn native_permission(kind: Kind) Permission {
    return switch (kind) {
        .help, .register, .login, .passwd, .resetpassword => .anyone,
        else => .op,
    };
}

/// Install the reserved native command set. Safe to call again; it rebuilds
/// the registry and drops any previously registered plugin commands.
pub fn reset_registry() void {
    registry_lock.lockUncancelable(Server.io);
    defer registry_lock.unlock(Server.io);

    entry_count = 0;
    native_registered = true;
    for (native_usages) |item| {
        var entry = Entry{
            .permission = native_permission(item.kind),
            .restriction = native_restriction(item.kind),
            .handler = .{ .native = item.kind },
        };
        if (!entry.name.set(@tagName(item.kind)) or !entry.usage.set(item.usage)) continue;
        entries[entry_count] = entry;
        entry_count += 1;
    }
}

fn ensure_native() void {
    if (native_registered) return;
    reset_registry();
}

fn find_entry_locked(name: []const u8) ?*Entry {
    for (entries[0..entry_count]) |*entry| {
        if (std.ascii.eqlIgnoreCase(entry.name.slice(), name)) return entry;
        for (entry.aliases[0..entry.alias_count]) |alias| {
            if (std.ascii.eqlIgnoreCase(alias.slice(), name)) return entry;
        }
    }
    return null;
}

/// Register a command, rejecting name and alias collisions explicitly. Script
/// registrations never override reserved native entries.
pub fn register(registration: Registration, owner: ?*const anyopaque) bool {
    ensure_native();

    registry_lock.lockUncancelable(Server.io);
    defer registry_lock.unlock(Server.io);

    if (entry_count == max_entries) return false;
    if (find_entry_locked(registration.name) != null) return false;

    var entry = Entry{ .owner = owner, .enabled = true };
    if (!entry.name.set(registration.name)) return false;
    if (!entry.usage.set(registration.usage)) return false;
    entry.permission = registration.permission;
    entry.restriction = registration.restriction;
    if (registration.script) |script| {
        entry.handler = .{ .script = script };
    } else {
        return false;
    }
    if (registration.aliases.len > max_aliases) return false;
    for (registration.aliases) |alias| {
        if (find_entry_locked(alias) != null) return false;
        if (!entry.aliases[entry.alias_count].set(alias)) return false;
        entry.alias_count += 1;
    }

    entries[entry_count] = entry;
    entry_count += 1;
    return true;
}

/// Revoke every registration owned by `owner` when a plugin fails or shuts
/// down; host cleanup does not rely on script cleanup succeeding.
pub fn unregister_owner(owner: *const anyopaque) void {
    registry_lock.lockUncancelable(Server.io);
    defer registry_lock.unlock(Server.io);

    var i: usize = 0;
    while (i < entry_count) {
        if (entries[i].owner == owner) {
            entries[i] = entries[entry_count - 1];
            entries[entry_count - 1] = .{};
            entry_count -= 1;
        } else {
            i += 1;
        }
    }
}

/// True when the first token names a plugin command; those dispatch on the
/// ordered host context instead of the calling thread.
pub fn is_script(name: []const u8) bool {
    ensure_native();

    registry_lock.lockSharedUncancelable(Server.io);
    defer registry_lock.unlockShared(Server.io);

    const entry = find_entry_locked(name) orelse return false;
    return entry.handler == .script;
}

pub fn set_enabled(owner: *const anyopaque, enabled: bool) void {
    registry_lock.lockUncancelable(Server.io);
    defer registry_lock.unlock(Server.io);

    for (entries[0..entry_count]) |*entry| {
        if (entry.owner == owner) entry.enabled = enabled;
    }
}

fn can_moderate(caller: Caller) bool {
    return switch (caller) {
        .console => true,
        .player => |client| client.session_open() and client.authenticated.load(.acquire) and client.is_op.load(.acquire),
    };
}

fn allowed(caller: Caller, entry: *const Entry) bool {
    switch (entry.restriction) {
        .player_only => if (caller != .player) return false,
        .console_only => if (caller != .console) return false,
        .any => {},
    }
    switch (entry.handler) {
        .native => |kind| {
            if (kind == .help) return true;
            if (kind == .register or kind == .login) return Authentication.mode == .local and caller == .player;
            if (kind == .passwd) return Authentication.mode == .local and caller == .player and caller.player.authenticated.load(.acquire);
            if (kind == .resetpassword) return Authentication.mode == .local and caller == .console;
            return can_moderate(caller);
        },
        .script => {
            const base = switch (caller) {
                .console => true,
                .player => |client| client.session_open() and client.authenticated.load(.acquire),
            };
            if (!base) return false;
            if (entry.permission == .op) return can_moderate(caller);
            return true;
        },
    }
}

/// Never log command text: it may contain a password, even on syntax errors.
pub fn dispatch(sink: Sink, line: []const u8, caller: Caller) void {
    ensure_native();

    var tokens = std.mem.tokenizeAny(u8, line, " \t");
    const name = tokens.next() orelse {
        sink.write("Unknown command, use /help");
        return;
    };

    registry_lock.lockSharedUncancelable(Server.io);
    const entry = find_entry_locked(name) orelse {
        registry_lock.unlockShared(Server.io);
        sink.write("Unknown command, use /help");
        return;
    };
    if (!entry.enabled or !allowed(caller, entry)) {
        registry_lock.unlockShared(Server.io);
        sink.write("&cCommand unavailable or insufficient permission");
        return;
    }
    switch (entry.handler) {
        .native => |kind| {
            registry_lock.unlockShared(Server.io);
            dispatch_native(sink, caller, kind, tokens.rest());
        },
        .script => |script| {
            var args: [16][]const u8 = undefined;
            var arg_count: usize = 0;
            while (tokens.next()) |arg| {
                if (arg_count == args.len) break;
                args[arg_count] = arg;
                arg_count += 1;
            }
            registry_lock.unlockShared(Server.io);
            script.call(script.ctx, caller, args[0..arg_count]);
        },
    }
}

fn dispatch_native(sink: Sink, caller: Caller, kind: Kind, rest: []const u8) void {
    var tokens = std.mem.tokenizeAny(u8, rest, " \t");
    const first = tokens.next();
    const second = if (kind == .ban or kind == .kick)
        std.mem.trimEnd(u8, tokens.rest(), " \t")
    else
        tokens.next();
    const argument_count: u8 = switch (kind) {
        .help => 0,
        .register, .passwd, .resetpassword => 2,
        else => 1,
    };
    const with_reason = kind == .ban or kind == .kick;
    if ((argument_count == 0 and first != null) or
        (argument_count > 0 and first == null) or
        (argument_count == 2 and second == null) or
        (!with_reason and ((argument_count < 2 and second != null) or tokens.next() != null)))
    {
        sink.write(usage_for(kind));
        return;
    }
    run_native(sink, caller, kind, first orelse "", second orelse "") catch |err| report_error(sink, err);
}

fn usage_for(kind: Kind) []const u8 {
    for (native_usages) |item| {
        if (item.kind == kind) return item.usage;
    }
    return "";
}

fn run_native(sink: Sink, caller: Caller, kind: Kind, first: []const u8, second: []const u8) !void {
    switch (kind) {
        .help => {
            write_help(sink, caller);
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

pub fn write_help(sink: Sink, caller: Caller) void {
    ensure_native();

    registry_lock.lockSharedUncancelable(Server.io);
    defer registry_lock.unlockShared(Server.io);

    for (entries[0..entry_count]) |*entry| {
        if (!entry.enabled or !allowed(caller, entry)) continue;
        if (caller == .player and caller.player.authenticated.load(.acquire) and entry.handler == .native) {
            const kind = entry.handler.native;
            if (kind == .register or kind == .login) continue;
        }
        sink.write(entry.usage.slice());
        if (entry.alias_count > 0) {
            var line_buf: [160]u8 = undefined;
            var fbs = std.Io.Writer.fixed(&line_buf);
            fbs.print("  aliases: /{s}", .{entry.aliases[0].slice()}) catch {};
            for (entry.aliases[1..entry.alias_count]) |alias| {
                fbs.print(", /{s}", .{alias.slice()}) catch {};
            }
            sink.write(fbs.buffered());
        }
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

test "registry rejects collisions and groups aliases in help" {
    Server.io = std.testing.io;
    var output: [2048]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output);
    const sink: Sink = .{ .ctx = &writer, .write_fn = struct {
        fn write(ctx: *anyopaque, line: []const u8) void {
            const target: *std.Io.Writer = @ptrCast(@alignCast(ctx));
            target.writeAll(line) catch unreachable;
        }
    }.write };

    var calls: usize = 0;
    const script = ScriptDispatch{
        .ctx = &calls,
        .call = struct {
            fn call(ctx: *anyopaque, caller: Caller, args: []const []const u8) void {
                _ = caller;
                _ = args;
                const counter: *usize = @ptrCast(@alignCast(ctx));
                counter.* += 1;
            }
        }.call,
    };
    reset_registry();
    defer reset_registry();

    try std.testing.expect(register(.{
        .name = "shrug",
        .aliases = &.{"shrugy"},
        .usage = "&e/shrug -- shrug",
        .script = script,
    }, @ptrFromInt(0x1000)));
    try std.testing.expect(!register(.{ .name = "shrug", .usage = "x", .script = script }, @ptrFromInt(0x2000)));
    try std.testing.expect(!register(.{ .name = "shrugy", .usage = "x", .script = script }, @ptrFromInt(0x2000)));
    try std.testing.expect(!register(.{ .name = "op", .usage = "x", .script = script }, @ptrFromInt(0x2000)));
    try std.testing.expect(!register(.{ .name = "bad name!", .usage = "x", .script = script }, @ptrFromInt(0x2000)));

    dispatch(sink, "shrugy", .console);
    try std.testing.expectEqual(@as(usize, 1), calls);

    const owner: *const anyopaque = @ptrFromInt(0x1000);
    unregister_owner(owner);
    dispatch(sink, "shrug", .console);
    try std.testing.expectEqual(@as(usize, 1), calls);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "Unknown command") != null);
}
