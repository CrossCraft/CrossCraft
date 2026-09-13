//! Authoritative, case-sensitive credentials and username policy. No eviction.
const std = @import("std");
const Server = @import("core").Server;
const assert = std.debug.assert;

pub const max_capacity: u32 = 65_536;
pub const file_name = "accounts.dat";
// Version 1: 8-byte magic, little-endian u32 version/count, 144-byte records,
// then a SHA-256 checksum of the header and records. Records contain lengths
// and flags (0..4), name (4..20), reason (20..84), salt (84..100), hash
// (100..132), credential revision (132..140), and zero padding (140..144).
const header_len = 16;
const record_len = 144;
const checksum_len = 32;
const magic = "CCAUTH\x00\x00";

pub const Credential = struct {
    salt: [16]u8,
    hash: [32]u8,
};

pub const Snapshot = struct {
    credential: ?Credential = null,
    revision: u64 = 0,
    banned: bool = false,
    op: bool = false,
    whitelisted: bool = false,
    reason: [64]u8 = @splat(0),
    reason_len: u8 = 0,

    pub fn ban_reason(self: *const Snapshot) []const u8 {
        assert(self.reason_len <= self.reason.len);
        return self.reason[0..self.reason_len];
    }
};

const Record = struct {
    name: [16]u8 = @splat(0),
    name_len: u8 = 0,
    data: Snapshot = .{},
};

var mutex: std.Io.Mutex = .init;
var records: []Record = &.{};
var scratch: []u8 = &.{};
var count: usize = 0;
var save_io: std.Io = undefined;
var save_dir: std.Io.Dir = undefined;
var allocator: std.mem.Allocator = undefined;

pub fn init(alloc: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, capacity: u32) !void {
    assert(records.len == 0);
    if (capacity == 0 or capacity > max_capacity) return error.InvalidAccountCapacity;
    allocator = alloc;
    save_io = io;
    save_dir = dir;
    mutex = .init;
    count = 0;
    records = try alloc.alloc(Record, capacity);
    errdefer {
        alloc.free(records);
        records = &.{};
    }
    scratch = try alloc.alloc(u8, header_len + @as(usize, capacity) * record_len + checksum_len + 1);
    errdefer {
        alloc.free(scratch);
        scratch = &.{};
    }
    try load();
}

pub fn deinit() void {
    assert(records.len > 0);
    allocator.free(records);
    allocator.free(scratch);
    records = &.{};
    scratch = &.{};
    count = 0;
}

pub fn lookup(name: []const u8) Snapshot {
    mutex.lockUncancelable(save_io);
    defer mutex.unlock(save_io);

    return if (find(name)) |index| records[index].data else .{};
}

fn find(name: []const u8) ?usize {
    assert(count <= records.len);
    for (records[0..count], 0..) |*record, index| {
        if (std.mem.eql(u8, record.name[0..record.name_len], name)) return index;
    }
    return null;
}

pub const PolicyFlag = enum { banned, op, whitelisted };

pub fn set_policy(name: []const u8, flag: PolicyFlag, enabled: bool, reason: []const u8) !void {
    mutex.lockUncancelable(save_io);
    defer mutex.unlock(save_io);

    var data = if (find(name)) |index| records[index].data else Snapshot{};
    switch (flag) {
        .banned => {
            data.banned = enabled;
            data.reason = @splat(0);
            data.reason_len = if (enabled) @intCast(@min(reason.len, data.reason.len)) else 0;
            @memcpy(data.reason[0..data.reason_len], reason[0..data.reason_len]);
        },
        .op => data.op = enabled,
        .whitelisted => data.whitelisted = enabled,
    }
    // Removing nonexistent policy should not consume capacity.
    if (!enabled and find(name) == null) return;
    try replace(name, data);
}

/// Revision is checked under the same lock as the durable replacement.
pub fn set_password(name: []const u8, expected_revision: u64, credential: Credential) !void {
    mutex.lockUncancelable(save_io);
    defer mutex.unlock(save_io);

    var data = if (find(name)) |index| records[index].data else Snapshot{};
    if (data.revision != expected_revision) return error.CredentialsChanged;
    data.credential = credential;
    data.revision = std.math.add(u64, data.revision, 1) catch return error.RevisionOverflow;
    try replace(name, data);
}

fn replace(name: []const u8, data: Snapshot) !void {
    if (!Server.Client.valid_username(name)) return error.InvalidUsername;
    const index = find(name) orelse count;
    if (index == records.len) return error.AccountStoreFull;
    const old_count = count;
    const previous = if (index < count) records[index] else Record{};
    errdefer {
        records[index] = previous;
        count = old_count;
    }
    records[index] = .{ .name_len = @intCast(name.len), .data = data };
    @memcpy(records[index].name[0..name.len], name);
    if (index == count) count += 1;
    try save();
}

fn encode(record: Record, out: *[record_len]u8) void {
    assert(record.name_len <= 16);
    @memset(out, 0);
    out[0] = record.name_len;
    const data = record.data;
    out[1] = @as(u8, @intFromBool(data.credential != null)) |
        (@as(u8, @intFromBool(data.banned)) << 1) |
        (@as(u8, @intFromBool(data.op)) << 2) |
        (@as(u8, @intFromBool(data.whitelisted)) << 3);
    out[2] = data.reason_len;
    @memcpy(out[4..20], &record.name);
    @memcpy(out[20..84], &data.reason);
    if (data.credential) |credential| {
        @memcpy(out[84..100], &credential.salt);
        @memcpy(out[100..132], &credential.hash);
    }
    std.mem.writeInt(u64, out[132..140], data.revision, .little);
}

fn decode(bytes: *const [record_len]u8) !Record {
    if (bytes[0] == 0 or bytes[0] > 16 or bytes[1] & 0xf0 != 0 or bytes[2] > 64)
        return error.InvalidAccountFile;
    var record: Record = .{ .name_len = bytes[0] };
    @memcpy(&record.name, bytes[4..20]);
    if (!Server.Client.valid_username(record.name[0..record.name_len])) return error.InvalidAccountFile;
    record.data = .{
        .banned = bytes[1] & 2 != 0,
        .op = bytes[1] & 4 != 0,
        .whitelisted = bytes[1] & 8 != 0,
        .reason_len = bytes[2],
        .reason = bytes[20..84].*,
        .revision = std.mem.readInt(u64, bytes[132..140], .little),
        .credential = if (bytes[1] & 1 != 0) .{ .salt = bytes[84..100].*, .hash = bytes[100..132].* } else null,
    };
    if ((record.data.credential == null) != (record.data.revision == 0)) return error.InvalidAccountFile;
    if (!record.data.banned and record.data.reason_len != 0) return error.InvalidAccountFile;
    var canonical: [record_len]u8 = undefined;
    encode(record, &canonical);
    // Also reject nonzero padding within names and reasons.
    if (!std.mem.allEqual(u8, record.name[record.name_len..], 0) or
        !std.mem.allEqual(u8, record.data.reason[record.data.reason_len..], 0) or
        !std.mem.eql(u8, bytes, &canonical)) return error.InvalidAccountFile;
    return record;
}

fn load() !void {
    const file = save_dir.openFile(save_io, file_name, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer file.close(save_io);

    const len = try file.readPositionalAll(save_io, scratch, 0);
    if (len < header_len + checksum_len or !std.mem.eql(u8, scratch[0..8], magic)) return error.InvalidAccountFile;
    if (std.mem.readInt(u32, scratch[8..12], .little) != 1) return error.UnsupportedAccountVersion;
    const file_count = std.mem.readInt(u32, scratch[12..16], .little);
    if (file_count > records.len) return error.AccountStoreFull;
    const payload_len = header_len + @as(usize, file_count) * record_len;
    if (len != payload_len + checksum_len) return error.InvalidAccountFile;
    var checksum: [checksum_len]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(scratch[0..payload_len], &checksum, .{});
    if (!std.mem.eql(u8, &checksum, scratch[payload_len..len])) return error.InvalidAccountFile;
    for (0..file_count) |index| {
        const offset = header_len + index * record_len;
        const record = try decode(scratch[offset..][0..record_len]);
        if (find(record.name[0..record.name_len]) != null) return error.DuplicateAccount;
        records[index] = record;
        count += 1;
    }
}

fn save() !void {
    assert(count <= records.len);
    @memcpy(scratch[0..8], magic);
    std.mem.writeInt(u32, scratch[8..12], 1, .little);
    std.mem.writeInt(u32, scratch[12..16], @intCast(count), .little);
    for (records[0..count], 0..) |record, index| {
        const offset = header_len + index * record_len;
        encode(record, scratch[offset..][0..record_len]);
    }
    const payload_len = header_len + count * record_len;
    std.crypto.hash.sha2.Sha256.hash(scratch[0..payload_len], scratch[payload_len..][0..checksum_len], .{});
    var file = try save_dir.createFileAtomic(save_io, file_name, .{
        .replace = true,
        .permissions = if (comptime std.Io.File.Permissions.has_executable_bit) .fromMode(0o600) else .default_file,
    });
    defer file.deinit(save_io);

    try file.file.writeStreamingAll(save_io, scratch[0 .. payload_len + checksum_len]);
    try file.file.sync(save_io);
    try file.replace(save_io);
}

test "accounts preserve case-sensitive credentials and policy across restart" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = std.testing.io;
    try init(std.testing.allocator, io, tmp.dir, 2);
    const credential: Credential = .{ .salt = @splat(7), .hash = @splat(9) };
    try set_policy("Alice", .whitelisted, true, "");
    try std.testing.expect(lookup("Alice").credential == null);
    try set_password("Alice", 0, credential);
    try set_policy("alice", .banned, true, "test ban");
    try std.testing.expectError(error.CredentialsChanged, set_password("Alice", 0, credential));
    try std.testing.expectError(error.AccountStoreFull, set_policy("Bob", .op, true, ""));
    deinit();
    try init(std.testing.allocator, io, tmp.dir, 2);
    defer deinit();

    try std.testing.expect(lookup("Alice").whitelisted);
    try std.testing.expect(!lookup("Alice").banned);
    try std.testing.expectEqual(credential, lookup("Alice").credential.?);
    try std.testing.expectEqualStrings("test ban", lookup("alice").ban_reason());
    try std.testing.expect(!lookup("Bob").op);
}

test "accounts failed writes roll back policy and credentials" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try init(std.testing.allocator, std.testing.io, tmp.dir, 2);
    defer deinit();

    try set_policy("Alice", .op, true, "");
    // Replacing a directory with a file must fail, even when tests run as root.
    try tmp.dir.deleteFile(std.testing.io, file_name);
    try tmp.dir.createDir(std.testing.io, file_name, .default_dir);
    try std.testing.expectError(error.IsDir, set_policy("Alice", .op, false, ""));
    try std.testing.expect(lookup("Alice").op);
    const credential: Credential = .{ .salt = @splat(1), .hash = @splat(2) };
    if (set_password("Bob", 0, credential)) |_| return error.ExpectedWriteFailure else |_| {}
    try std.testing.expect(lookup("Bob").credential == null);
}

test "accounts reject damaged truncated unsupported and over-capacity files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = std.testing.io;
    try init(std.testing.allocator, io, tmp.dir, 2);
    try set_policy("Alice", .op, true, "");
    try set_policy("Bob", .whitelisted, true, "");
    const length = header_len + 2 * record_len + checksum_len;
    var valid_file: [length]u8 = undefined;
    @memcpy(&valid_file, scratch[0..length]);
    deinit();
    try std.testing.expectError(error.AccountStoreFull, init(std.testing.allocator, io, tmp.dir, 1));
    const file = try tmp.dir.createFile(io, file_name, .{});
    defer file.close(io);

    var broken = valid_file;
    broken[header_len + 5] ^= 1;
    try file.writeStreamingAll(io, &broken);
    try std.testing.expectError(error.InvalidAccountFile, init(std.testing.allocator, io, tmp.dir, 2));
    broken = valid_file;
    broken[8] = 2;
    try file.writePositionalAll(io, &broken, 0);
    try std.testing.expectError(error.UnsupportedAccountVersion, init(std.testing.allocator, io, tmp.dir, 2));
    broken = valid_file;
    @memcpy(broken[header_len + record_len ..][0..record_len], broken[header_len..][0..record_len]);
    std.crypto.hash.sha2.Sha256.hash(broken[0 .. length - checksum_len], broken[length - checksum_len ..], .{});
    try file.writePositionalAll(io, &broken, 0);
    try std.testing.expectError(error.DuplicateAccount, init(std.testing.allocator, io, tmp.dir, 2));
    try file.setLength(io, 8);
    try std.testing.expectError(error.InvalidAccountFile, init(std.testing.allocator, io, tmp.dir, 2));
}
