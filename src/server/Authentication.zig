//! Local authentication policy, separate from the Classic transport handshake.
const std = @import("std");
const Server = @import("core").Server;
const Accounts = @import("Accounts.zig");
const Passwords = @import("Passwords.zig");
const assert = std.debug.assert;

pub const Mode = enum { local, online, none };
pub const Action = enum { register, login, passwd };
pub var mode: Mode = .local;
var grace_seconds: u32 = 30;
var whitelist_enabled: bool = false;
// Policy edits, password commits and activation share this ordering. Hashing
// happens outside this lock, then rechecks the credential revision and session.
var action_mutex: std.Io.Mutex = .init;

pub fn init(alloc: std.mem.Allocator, selected: Mode, grace: u32, whitelist: bool) !void {
    assert(grace > 0 and grace <= 3600);
    if (selected == .online) return error.OnlineAuthenticationUnavailable;
    mode = selected;
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

pub fn begin(client: *Server.Client) !void {
    const registration = blk: {
        lock_actions();
        defer unlock_actions();

        const policy = Accounts.lookup(client.name[0..client.name_len]);
        if (denial(&policy)) |reason| {
            try client.send_disconnect(reason);
            return;
        }
        if (mode == .none) {
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

const TestSession = struct {
    output: [8192]u8 = undefined,
    reader: std.Io.Reader = undefined,
    writer: std.Io.Writer = undefined,
    connected: bool = true,

    fn open(self: *TestSession, name: []const u8) *Server.Client {
        self.reader = std.Io.Reader.fixed(&.{});
        self.writer = std.Io.Writer.fixed(&self.output);
        self.connected = true;
        Server.players.items[0] = .{
            .id = 0,
            .generation = 1,
            .reader = &self.reader,
            .writer = &self.writer,
            .connected = &self.connected,
            .local = true,
            .initialized = true,
            .phase = .init(.active),
            .authenticated = .init(mode == .none),
            .name_len = @intCast(name.len),
        };
        const client = &Server.players.items[0].?;
        @memcpy(client.name[0..name.len], name);
        return client;
    }
};

test "auth registration login password change and reset preserve ownership" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    Server.io = std.testing.io;
    Server.players = .{};
    defer Server.players = .{};

    try Accounts.init(std.testing.allocator, Server.io, tmp.dir, 8);
    defer Accounts.deinit();

    try init(std.testing.allocator, .local, 30, false);
    defer deinit();

    try Accounts.set_policy("Alice", .op, true, "");
    var session: TestSession = .{};
    const client = session.open("Alice");
    try begin(client);
    try std.testing.expect(!client.authenticated.load(.acquire));
    try std.testing.expect(!client.is_op.load(.acquire));
    try std.testing.expect(client.needs_registration);
    try std.testing.expectError(error.PasswordsDoNotMatch, execute(client, .register, "password1", "password2"));
    try std.testing.expect(Accounts.lookup("Alice").credential == null);
    try execute(client, .register, "password1", "password1");
    try std.testing.expect(client.authenticated.load(.acquire));
    try std.testing.expect(client.is_op.load(.acquire));
    try std.testing.expect(Accounts.lookup("alice").credential == null);
    try std.testing.expectError(error.AlreadyAuthenticated, execute(client, .register, "password2", "password2"));

    client.auth_next_attempt_ms = 0;
    try execute(client, .passwd, "password1", "password2");
    try reset_password("Alice", "password3");
    try std.testing.expect(!session.connected);
    const returning = session.open("Alice");
    try begin(returning);
    try std.testing.expect(!returning.needs_registration);
    try std.testing.expectError(error.AlreadyRegistered, execute(returning, .register, "password4", "password4"));
    try std.testing.expectError(error.WrongPassword, execute(returning, .login, "password2", ""));
    try std.testing.expectError(error.AuthenticationThrottled, execute(returning, .login, "password3", ""));
    returning.auth_next_attempt_ms = 0;
    try execute(returning, .login, "password3", "");
    try std.testing.expect(returning.authenticated.load(.acquire));
    try std.testing.expect(std.mem.indexOf(u8, session.writer.buffered(), "password3") == null);
}

test "auth expiry none mode whitelist and three failures gate access" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    Server.io = std.testing.io;
    Server.players = .{};
    defer Server.players = .{};

    try Accounts.init(std.testing.allocator, Server.io, tmp.dir, 4);
    defer Accounts.deinit();

    try init(std.testing.allocator, .local, 2, true);
    defer deinit();

    var session: TestSession = .{};
    var client = session.open("Alice");
    try begin(client);
    try std.testing.expect(!session.connected);
    try Accounts.set_policy("Alice", .whitelisted, true, "");
    client = session.open("Alice");
    try begin(client);
    const remaining = client.auth_deadline_ms - Server.Client.now_ms();
    try std.testing.expect(remaining > 0 and remaining <= 2000);
    client.auth_deadline_ms = Server.Client.now_ms();
    try std.testing.expectError(error.SessionClosed, execute(client, .register, "password1", "password1"));
    try std.testing.expect(Accounts.lookup("Alice").credential == null);

    const credential = try Passwords.create(Server.io, "password1");
    try Accounts.set_password("Alice", 0, credential);
    client = session.open("Alice");
    try begin(client);
    client.auth_deadline_ms = Server.Client.now_ms() + 30_000;
    for (0..3) |_| {
        client.auth_next_attempt_ms = 0;
        try std.testing.expectError(error.WrongPassword, execute(client, .login, "password2", ""));
    }
    try std.testing.expect(!session.connected);
    try std.testing.expect(!client.authenticated.load(.acquire));
    mode = .none;
    try Accounts.set_policy("Alice", .op, true, "");
    client = session.open("Alice");
    try begin(client);
    try std.testing.expect(client.authenticated.load(.acquire));
    try std.testing.expect(client.is_op.load(.acquire));
    try std.testing.expectEqual(@as(i64, 0), client.auth_deadline_ms);
    try std.testing.expectError(error.AuthenticationDisabled, execute(client, .login, "password1", ""));
    try std.testing.expect(Accounts.lookup("Alice").credential != null);
}

test "auth rechecks credential revision and policy after hashing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    Server.io = std.testing.io;
    Server.players = .{};
    defer Server.players = .{};

    try Accounts.init(std.testing.allocator, Server.io, tmp.dir, 2);
    defer Accounts.deinit();

    try init(std.testing.allocator, .local, 30, false);
    defer deinit();

    const credential = try Passwords.create(Server.io, "password1");
    try Accounts.set_password("Alice", 0, credential);
    const before = Accounts.lookup("Alice");
    var session: TestSession = .{};
    const client = session.open("Alice");
    try begin(client);
    try Accounts.set_password("Alice", before.revision, credential);
    try std.testing.expectError(error.CredentialsChanged, perform(client, .login, "password1", "", before));
    try std.testing.expect(!client.authenticated.load(.acquire));
    const current = Accounts.lookup("Alice");
    try Accounts.set_policy("Alice", .banned, true, "Banned during authentication");
    try std.testing.expectError(error.SessionClosed, perform(client, .login, "password1", "", current));
    try std.testing.expect(!session.connected);
}
