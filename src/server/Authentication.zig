//! Authentication policy, separate from the Classic transport handshake.
const std = @import("std");
const Server = @import("core").Server;
const Accounts = @import("Accounts.zig");
const Passwords = @import("Passwords.zig");
const assert = std.debug.assert;
const log = std.log.scoped(.auth);

pub const Mode = enum { local, online, none };

/// A heartbeat endpoint that vouches for players with ClassiCube's mppass scheme.
pub const Directory = struct {
    salt: [16]u8,
    /// Keyed by host so editing a heartbeat path or scheme keeps name bindings.
    authority: u32,
};

pub const Vouch = union(enum) {
    source: u8,
    rejected: []const u8,
};

const sign_in_reason = "Sign in to CrossCraft or ClassiCube and rejoin";
const foreign_name_reason = "That name belongs to another login service here";

pub const Action = enum { register, login, passwd };
pub var mode: Mode = .local;
var grace_seconds: u32 = 30;
var whitelist_enabled: bool = false;
// Policy edits, password commits and activation share this ordering. Hashing
// happens outside this lock, then rechecks the credential revision and session.
var action_mutex: std.Io.Mutex = .init;
var directories: []const Directory = &.{};

pub fn init(alloc: std.mem.Allocator, selected: Mode, grace: u32, whitelist: bool, sources: []const Directory) !void {
    assert(grace > 0 and grace <= 3600);
    assert(selected != .online or sources.len > 0);
    mode = selected;
    directories = sources;
    grace_seconds = grace;
    whitelist_enabled = whitelist;
    action_mutex = .init;
    if (mode == .local) try Passwords.init(alloc);
}

pub fn deinit() void {
    Passwords.deinit();
}

pub fn lock_actions() void {
    action_mutex.lockUncancelable(Server.io);
}

pub fn unlock_actions() void {
    action_mutex.unlock(Server.io);
}

pub fn denial(policy: *const Accounts.Snapshot) ?[]const u8 {
    if (policy.banned) return if (policy.reason_len > 0) policy.ban_reason() else "You have been banned";
    if (whitelist_enabled and !policy.whitelisted) return "Not whitelisted";
    return null;
}

/// Checks the login key against `md5(salt ++ name)` for every directory.
pub fn vouch(name: []const u8, key: *const [64]u8, policy: *const Accounts.Snapshot) Vouch {
    assert(mode == .online);
    const given = std.mem.trimEnd(u8, key, " \x00");
    if (given.len == 0 or given.len > 32) return .{ .rejected = sign_in_reason };
    // Some directories print the digest as an integer, dropping leading zeros.
    var padded: [32]u8 = @splat('0');
    for (given, padded[32 - given.len ..]) |byte, *out| out.* = std.ascii.toLower(byte);
    for (directories, 0..) |source, index| {
        var digest: [std.crypto.hash.Md5.digest_length]u8 = undefined;
        var md5 = std.crypto.hash.Md5.init(.{});
        md5.update(&source.salt);
        md5.update(name);
        md5.final(&digest);
        if (!std.crypto.timing_safe.eql([32]u8, std.fmt.bytesToHex(digest, .lower), padded)) continue;
        if (policy.authority != 0 and policy.authority != source.authority) return .{ .rejected = foreign_name_reason };
        return .{ .source = @intCast(index) };
    }
    return .{ .rejected = sign_in_reason };
}

pub fn begin(client: *Server.Client) !void {
    const registration = blk: {
        lock_actions();
        defer unlock_actions();

        const name = client.name[0..client.name_len];
        const policy = Accounts.lookup(name);
        if (denial(&policy)) |reason| {
            try client.send_disconnect(reason);
            return;
        }
        if (mode == .online) {
            Accounts.bind_authority(name, directories[client.auth_source.?].authority) catch |err| switch (err) {
                error.AuthorityMismatch => {
                    try client.send_disconnect(foreign_name_reason);
                    return;
                },
                // Losing the binding only weakens collision protection; keep the verified player.
                else => log.warn("Could not bind {s} to its login service: {}", .{ name, err }),
            };
        }
        if (mode != .local) {
            _ = Server.set_op_handle(.{ .id = @intCast(client.id), .generation = client.generation }, policy.op);
            return;
        }
        break :blk policy.credential == null;
    };
    assert(!client.authenticated.load(.acquire));
    // Socket flushing must not block other players' account operations.
    client.start_authentication(registration, grace_seconds);
}

pub fn execute(client: *Server.Client, action: Action, first: []const u8, second: []const u8) !void {
    if (mode != .local) return error.AuthenticationDisabled;
    if (!client.check_auth_deadline()) return error.SessionClosed;
    const authenticated = client.authenticated.load(.acquire);
    if (action == .passwd and !authenticated) return error.LoginRequired;
    if (action != .passwd and authenticated) return error.AlreadyAuthenticated;
    if (!Passwords.valid(first) or (action != .login and !Passwords.valid(second))) return error.InvalidPassword;
    if (action == .register and !std.mem.eql(u8, first, second)) return error.PasswordsDoNotMatch;

    const name = client.name[0..client.name_len];
    const before = Accounts.lookup(name);
    if (action == .register and before.credential != null) return error.AlreadyRegistered;
    if (action != .register and before.credential == null) return error.NotRegistered;
    const now = Server.Client.now_ms();
    if (now < client.auth_next_attempt_ms) return error.AuthenticationThrottled;
    client.auth_next_attempt_ms = now + 1000;
    perform(client, action, first, second, before) catch |err| {
        switch (err) {
            error.AuthenticationBusy => client.auth_next_attempt_ms = now,
            else => {},
        }
        return err;
    };
}

fn perform(client: *Server.Client, action: Action, first: []const u8, second: []const u8, before: Accounts.Snapshot) !void {
    var replacement: ?Accounts.Credential = null;
    if (action != .register) {
        if (!try Passwords.verify(Server.io, first, before.credential.?)) {
            if (!client.check_auth_deadline()) return error.SessionClosed;
            if (action == .login) {
                client.auth_failures += 1;
                if (client.auth_failures >= 3) try client.send_disconnect("Too many incorrect passwords");
            }
            return error.WrongPassword;
        }
    }
    if (action != .login) replacement = try Passwords.create(Server.io, second);
    defer if (replacement) |*credential| std.crypto.secureZero(u8, &credential.hash);

    lock_actions();
    defer unlock_actions();

    if (!client.check_auth_deadline()) return error.SessionClosed;
    const name = client.name[0..client.name_len];
    const current = Accounts.lookup(name);
    if (current.revision != before.revision) return error.CredentialsChanged;
    if (denial(&current)) |reason| {
        try client.send_disconnect(reason);
        return error.SessionClosed;
    }
    if (replacement) |credential| try Accounts.set_password(name, before.revision, credential);
    if (action == .passwd) {
        try client.send_message(client.id, "&aPassword changed");
    } else {
        _ = client.authenticate(current.op);
    }
}

pub fn reset_password(name: []const u8, password: []const u8) !void {
    if (mode != .local) return error.AuthenticationDisabled;
    if (!Server.Client.valid_username(name)) return error.InvalidUsername;
    const before = Accounts.lookup(name);
    if (before.credential == null) return error.NotRegistered;
    var credential = try Passwords.create(Server.io, password);
    defer std.crypto.secureZero(u8, &credential.hash);

    lock_actions();
    defer unlock_actions();

    try Accounts.set_password(name, before.revision, credential);
    if (Server.find_client_by_name(name)) |target| {
        _ = Server.disconnect_handle(target.handle, "Password reset; reconnect and log in");
    }
}
