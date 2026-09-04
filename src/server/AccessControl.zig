const std = @import("std");
const assert = std.debug.assert;

const log = std.log.scoped(.access_control);

// Policy entries are never evicted when the store reaches capacity.
pub const max_capacity: u32 = 65_536;
const ip_str_len = @import("core").Server.Client.ip_str_len;
pub const reason_len: u32 = 64;

const Policy = struct {
    ip: [ip_str_len:0]u8,
    ban_reason: [reason_len:0]u8,
    banned: bool,
    op: bool,
    whitelisted: bool,

    pub fn ip_slice(self: *const Policy) []const u8 {
        return std.mem.sliceTo(self.ip[0..], 0);
    }

    pub fn ban_reason_slice(self: *const Policy) []const u8 {
        return std.mem.sliceTo(self.ban_reason[0..], 0);
    }
};

/// Returned by value so callers do not retain records protected by the lock.
pub const Snapshot = struct {
    banned: bool = false,
    op: bool = false,
    whitelisted: bool = false,
    ban_reason: [reason_len:0]u8 = std.mem.zeroes([reason_len:0]u8),

    pub fn ban_reason_slice(self: *const Snapshot) []const u8 {
        return std.mem.sliceTo(self.ban_reason[0..], 0);
    }
};

const JsonRecord = struct {
    ip: []const u8,
    ban_reason: []const u8 = "",
    banned: bool = false,
    op: bool = false,
    whitelisted: bool = false,
};

const JsonFile = struct {
    records: []const JsonRecord,
};

const file_name = "access-control.json";
// JSON escaping can expand a 64-byte reason to 384 bytes.
const json_bytes_per_record: usize = 640;

var mutex: std.Io.Mutex = .init;
var records: []Policy = &.{};
var json_records: []JsonRecord = &.{};
var json_scratch: []u8 = &.{};
var count: u32 = 0;
var save_dir: std.Io.Dir = undefined;
var save_io: std.Io = undefined;
var owning_alloc: std.mem.Allocator = undefined;
var initialized: bool = false;

// An existing access-control.json always takes precedence over legacy flags.
var accepting_legacy_import: bool = false;
var legacy_imported: bool = false;

pub fn init(alloc: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, cap_request: u32) !void {
    const cap = std.math.clamp(cap_request, 1, max_capacity);
    const scratch_len: usize = @as(usize, cap) * json_bytes_per_record + 1024;

    assert(!initialized);
    errdefer clear(alloc);

    records = try alloc.alloc(Policy, cap);
    json_records = try alloc.alloc(JsonRecord, cap);
    json_scratch = try alloc.alloc(u8, scratch_len);

    count = 0;
    save_dir = dir;
    save_io = io;
    owning_alloc = alloc;
    initialized = true;

    const exists = try load_locked();
    accepting_legacy_import = !exists;
    legacy_imported = false;
}

pub fn deinit() void {
    if (!initialized) return;
    mutex.lockUncancelable(save_io);
    defer mutex.unlock(save_io);

    clear(owning_alloc);
}

fn clear(alloc: std.mem.Allocator) void {
    alloc.free(records);
    alloc.free(json_records);
    alloc.free(json_scratch);
    records = &.{};
    json_records = &.{};
    json_scratch = &.{};
    count = 0;
    initialized = false;
    accepting_legacy_import = false;
    legacy_imported = false;
}

pub fn lookup(ip: []const u8) Snapshot {
    if (!initialized) return .{};
    mutex.lockUncancelable(save_io);
    defer mutex.unlock(save_io);

    const index = find_index_locked(ip) orelse return .{};
    const rec = &records[index];
    return .{
        .banned = rec.banned,
        .op = rec.op,
        .whitelisted = rec.whitelisted,
        .ban_reason = rec.ban_reason,
    };
}

pub fn set_banned(ip: []const u8, banned: bool, reason: []const u8) !void {
    if (!initialized) return;
    mutex.lockUncancelable(save_io);
    defer mutex.unlock(save_io);

    const index = if (banned) try upsert_index_locked(ip) else find_index_locked(ip) orelse return;
    const rec = &records[index];
    rec.banned = banned;
    @memset(&rec.ban_reason, 0);
    if (banned) {
        const n = @min(reason.len, reason_len);
        @memcpy(rec.ban_reason[0..n], reason[0..n]);
    }
    remove_if_empty_locked(index);
    try save_locked();
}

pub fn set_flag(ip: []const u8, comptime flag: enum { op, whitelisted }, enabled: bool) !void {
    if (!initialized) return;
    mutex.lockUncancelable(save_io);
    defer mutex.unlock(save_io);

    const index = if (enabled) try upsert_index_locked(ip) else find_index_locked(ip) orelse return;
    @field(records[index], @tagName(flag)) = enabled;
    remove_if_empty_locked(index);
    try save_locked();
}

pub fn import_legacy(
    ip: []const u8,
    banned: bool,
    ban_reason: []const u8,
    op: bool,
    whitelisted: bool,
) !void {
    if (!initialized or !accepting_legacy_import) return;
    mutex.lockUncancelable(save_io);
    defer mutex.unlock(save_io);

    if (!accepting_legacy_import) return;
    if (!banned and !op and !whitelisted) return;

    const rec = &records[try upsert_index_locked(ip)];
    rec.banned = rec.banned or banned;
    rec.op = rec.op or op;
    rec.whitelisted = rec.whitelisted or whitelisted;
    if (banned and rec.ban_reason_slice().len == 0) {
        const n = @min(ban_reason.len, reason_len);
        @memcpy(rec.ban_reason[0..n], ban_reason[0..n]);
    }
    legacy_imported = true;
}

/// Persist migrated policy before accepting connections or rewriting the cache.
pub fn finish_legacy_migration() !void {
    if (!initialized or !accepting_legacy_import) return;
    mutex.lockUncancelable(save_io);
    defer mutex.unlock(save_io);

    if (!accepting_legacy_import) return;

    accepting_legacy_import = false;
    if (legacy_imported) try save_locked();
}

fn find_index_locked(ip: []const u8) ?u32 {
    for (0..count) |i| {
        if (std.mem.eql(u8, records[i].ip_slice(), ip)) return @intCast(i);
    }
    return null;
}

fn upsert_index_locked(ip: []const u8) !u32 {
    if (find_index_locked(ip)) |index| return index;
    if (count >= records.len) return error.PolicyStoreFull;

    const index = count;
    const rec = &records[index];
    count += 1;
    rec.* = std.mem.zeroes(Policy);
    const n = @min(ip.len, ip_str_len);
    @memcpy(rec.ip[0..n], ip[0..n]);
    return index;
}

fn remove_if_empty_locked(index: u32) void {
    const rec = &records[index];
    if (rec.banned or rec.op or rec.whitelisted) return;
    const last: u32 = count - 1;
    if (index != last) records[index] = records[last];
    count -= 1;
}

// Empty files are authoritative too and suppress legacy migration.
fn load_locked() !bool {
    const file = save_dir.openFile(save_io, file_name, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => {
            log.err("open {s} failed: {}", .{ file_name, err });
            return err;
        },
    };
    defer file.close(save_io);

    const n = file.readPositionalAll(save_io, json_scratch, 0) catch |err| {
        log.err("read {s} failed: {}", .{ file_name, err });
        return err;
    };
    if (n == 0) return true;

    const parsed = std.json.parseFromSlice(
        JsonFile,
        owning_alloc,
        json_scratch[0..n],
        .{ .ignore_unknown_fields = true },
    ) catch |err| {
        log.err("parse {s} failed: {}", .{ file_name, err });
        return error.InvalidPolicyFile;
    };
    defer parsed.deinit();

    for (parsed.value.records) |jr| {
        if (!jr.banned and !jr.op and !jr.whitelisted) continue;
        if (count >= records.len) return error.PolicyStoreFull;

        const rec = &records[count];
        count += 1;
        rec.* = std.mem.zeroes(Policy);
        const ip_n = @min(jr.ip.len, ip_str_len);
        @memcpy(rec.ip[0..ip_n], jr.ip[0..ip_n]);
        const reason_n = @min(jr.ban_reason.len, reason_len);
        @memcpy(rec.ban_reason[0..reason_n], jr.ban_reason[0..reason_n]);
        rec.banned = jr.banned;
        rec.op = jr.op;
        rec.whitelisted = jr.whitelisted;
    }

    log.info("Loaded {s} ({d} policy record(s))", .{ file_name, count });
    return true;
}

fn save_locked() !void {
    for (0..count) |i| {
        json_records[i] = .{
            .ip = records[i].ip_slice(),
            .ban_reason = records[i].ban_reason_slice(),
            .banned = records[i].banned,
            .op = records[i].op,
            .whitelisted = records[i].whitelisted,
        };
    }

    var writer = std.Io.Writer.fixed(json_scratch);
    std.json.Stringify.value(
        JsonFile{ .records = json_records[0..count] },
        .{ .whitespace = .indent_2 },
        &writer,
    ) catch |err| {
        log.err("serialize {s} failed: {}", .{ file_name, err });
        return err;
    };

    const file = save_dir.createFile(save_io, file_name, .{}) catch |err| {
        log.err("create {s} failed: {}", .{ file_name, err });
        return err;
    };
    defer file.close(save_io);

    file.writeStreamingAll(save_io, writer.buffered()) catch |err| {
        log.err("write {s} failed: {}", .{ file_name, err });
        return err;
    };
}

test "policy capacity rejects new entries without evicting existing policy" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try init(std.testing.allocator, io, tmp.dir, 1);
    defer deinit();

    try set_banned("203.0.113.10", true, "test ban");
    try std.testing.expectError(error.PolicyStoreFull, set_flag("203.0.113.11", .op, true));

    const policy = lookup("203.0.113.10");
    try std.testing.expect(policy.banned);
    try std.testing.expectEqualStrings("test ban", policy.ban_reason_slice());
    try std.testing.expect(!lookup("203.0.113.11").op);
}
