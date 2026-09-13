//! One bounded Argon2 workspace; hashing never holds the account or roster lock.
const std = @import("std");
const Accounts = @import("Accounts.zig");
const assert = std.debug.assert;
// accounts.dat version 1 fixes these parameters; changes require a format upgrade.
const params: std.crypto.pwhash.argon2.Params = .{ .t = 2, .m = 19 * 1024, .p = 1 };
var workspace: []u8 = &.{};
var allocator: std.mem.Allocator = undefined;
var busy: std.atomic.Value(bool) = .init(false);

pub fn init(alloc: std.mem.Allocator) !void {
    assert(workspace.len == 0);
    allocator = alloc;
    workspace = try alloc.alloc(u8, @as(usize, params.m) * 1024 + 64);
    busy = .init(false);
}

pub fn deinit() void {
    assert(!busy.load(.acquire));
    if (workspace.len == 0) return;
    std.crypto.secureZero(u8, workspace);
    allocator.free(workspace);
    workspace = &.{};
}

pub fn valid(password: []const u8) bool {
    if (password.len < 8 or password.len > 26) return false;
    for (password) |byte| if (byte < 0x21 or byte > 0x7e) return false;
    return true;
}

pub fn derive(io: std.Io, password: []const u8, salt: [16]u8) !Accounts.Credential {
    if (!valid(password)) return error.InvalidPassword;
    if (workspace.len == 0) return error.AuthenticationDisabled;
    if (busy.cmpxchgStrong(false, true, .acquire, .monotonic) != null) return error.AuthenticationBusy;
    defer busy.store(false, .release);
    defer std.crypto.secureZero(u8, workspace);

    var buffer = std.heap.FixedBufferAllocator.init(workspace);
    var credential: Accounts.Credential = .{ .salt = salt, .hash = undefined };
    try std.crypto.pwhash.argon2.kdf(buffer.allocator(), &credential.hash, password, &salt, params, .argon2id, io);
    return credential;
}

pub fn create(io: std.Io, password: []const u8) !Accounts.Credential {
    var salt: [16]u8 = undefined;
    try io.randomSecure(&salt);
    return derive(io, password, salt);
}

pub fn verify(io: std.Io, password: []const u8, credential: Accounts.Credential) !bool {
    var candidate = try derive(io, password, credential.salt);
    defer std.crypto.secureZero(u8, &candidate.hash);

    return std.crypto.timing_safe.eql([32]u8, candidate.hash, credential.hash);
}

test "auth password hashing salts independently and verifies exactly" {
    try init(std.testing.allocator);
    defer deinit();

    const first = try create(std.testing.io, "password123");
    const second = try create(std.testing.io, "password123");
    try std.testing.expect(!std.mem.eql(u8, &first.salt, &second.salt));
    try std.testing.expect(!std.mem.eql(u8, &first.hash, &second.hash));
    try std.testing.expect(try verify(std.testing.io, "password123", first));
    try std.testing.expect(!try verify(std.testing.io, "Password123", first));
    try std.testing.expect(!valid("short"));
    try std.testing.expect(!valid("white space"));
    try std.testing.expect(valid("12345678901234567890123456"));
    try std.testing.expect(!valid("123456789012345678901234567"));
}
