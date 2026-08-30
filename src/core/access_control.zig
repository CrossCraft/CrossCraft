const std = @import("std");

const log = std.log.scoped(.access_control);

/// The policy store is separate from the bounded recent-player cache. A
/// policy entry is never evicted: if the configured capacity is exhausted,
/// the administrative mutation fails instead of weakening enforcement.
pub const max_capacity: u32 = 65_536;
pub const ip_str_len: u32 = 15;
pub const reason_len: u32 = 64;

pub const Policy = struct {
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

    fn has_any_flag(self: *const Policy) bool {
        return self.banned or self.op or self.whitelisted;
    }
};

/// An immutable copy returned to callers so the store lock never leaks a
/// mutable record pointer to connection or console tasks.
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
// A 64-byte reason can expand to 384 bytes when JSON-escaped. Leave room for
// the remaining fields and indentation so every valid in-memory policy can be
// serialized without allocating during a synchronous command.
const json_bytes_per_record: usize = 640;

var mutex: std.Io.Mutex = .init;
var records: []Policy = &.{};
var json_records: []JsonRecord = &.{};
var json_scratch: []u8 = &.{};
var count: u32 = 0;
var capacity: u32 = 0;
var save_dir: std.Io.Dir = undefined;
var save_io: std.Io = undefined;
var owning_alloc: std.mem.Allocator = undefined;
var initialized: bool = false;

/// True only when access-control.json did not exist at init. During this
/// one-time window players_db may import legacy policy flags from players.json.
var accepting_legacy_import: bool = false;
var legacy_imported: bool = false;

pub fn init(alloc: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, cap_request: u32) !void {
    const cap = std.math.clamp(cap_request, 1, max_capacity);
    const scratch_len: usize = @as(usize, cap) * json_bytes_per_record + 1024;

    std.debug.assert(!initialized);
    errdefer {
        if (records.len > 0) alloc.free(records);
        if (json_records.len > 0) alloc.free(json_records);
        if (json_scratch.len > 0) alloc.free(json_scratch);
        records = &.{};
        json_records = &.{};
        json_scratch = &.{};
        count = 0;
        capacity = 0;
        initialized = false;
        accepting_legacy_import = false;
        legacy_imported = false;
    }

    records = try alloc.alloc(Policy, cap);
    json_records = try alloc.alloc(JsonRecord, cap);
    json_scratch = try alloc.alloc(u8, scratch_len);

    @memset(std.mem.sliceAsBytes(records), 0);
    count = 0;
    capacity = cap;
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

    owning_alloc.free(records);
    owning_alloc.free(json_records);
    owning_alloc.free(json_scratch);
    records = &.{};
    json_records = &.{};
    json_scratch = &.{};
    count = 0;
    capacity = 0;
    initialized = false;
    accepting_legacy_import = false;
    legacy_imported = false;
}

pub fn lookup(ip: []const u8) Snapshot {
    if (!initialized) return .{};
    mutex.lockUncancelable(save_io);
    defer mutex.unlock(save_io);

    const rec = find_locked(ip) orelse return .{};
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

pub fn set_op(ip: []const u8, op: bool) !void {
    if (!initialized) return;
    mutex.lockUncancelable(save_io);
    defer mutex.unlock(save_io);

    const index = if (op) try upsert_index_locked(ip) else find_index_locked(ip) orelse return;
    const rec = &records[index];
    rec.op = op;
    remove_if_empty_locked(index);
    try save_locked();
}

pub fn set_whitelisted(ip: []const u8, whitelisted: bool) !void {
    if (!initialized) return;
    mutex.lockUncancelable(save_io);
    defer mutex.unlock(save_io);

    const index = if (whitelisted) try upsert_index_locked(ip) else find_index_locked(ip) orelse return;
    const rec = &records[index];
    rec.whitelisted = whitelisted;
    remove_if_empty_locked(index);
    try save_locked();
}

/// Import one legacy players.json record. This intentionally does nothing
/// after the first boot with access-control.json so a current policy file is
/// always authoritative (including future unban/unop operations).
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

/// Complete the one-time migration after players_db has finished loading.
/// Persist policy before serving connections so no legacy enforcement state is
/// silently lost in a crash or subsequent cache write.
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

fn find_locked(ip: []const u8) ?*Policy {
    const index = find_index_locked(ip) orelse return null;
    return &records[index];
}

fn upsert_index_locked(ip: []const u8) !u32 {
    if (find_index_locked(ip)) |index| return index;
    if (count >= capacity) return error.PolicyStoreFull;

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
    if (rec.has_any_flag()) return;
    const last: u32 = count - 1;
    if (index != last) records[index] = records[last];
    count -= 1;
}

/// Returns whether a policy file existed. Existing-but-empty files are still
/// authoritative and deliberately suppress legacy migration.
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

    var arena = std.heap.ArenaAllocator.init(owning_alloc);
    defer arena.deinit();
    const parsed = std.json.parseFromSliceLeaky(
        JsonFile,
        arena.allocator(),
        json_scratch[0..n],
        .{ .ignore_unknown_fields = true },
    ) catch |err| {
        log.err("parse {s} failed: {}", .{ file_name, err });
        return error.InvalidPolicyFile;
    };

    for (parsed.records) |jr| {
        if (!jr.banned and !jr.op and !jr.whitelisted) continue;
        if (count >= capacity) return error.PolicyStoreFull;

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
    try std.testing.expectError(error.PolicyStoreFull, set_op("203.0.113.11", true));

    const policy = lookup("203.0.113.10");
    try std.testing.expect(policy.banned);
    try std.testing.expectEqualStrings("test ban", policy.ban_reason_slice());
    try std.testing.expect(!lookup("203.0.113.11").op);
}

test "legacy policy import persists as canonical access control" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try init(std.testing.allocator, io, tmp.dir, 2);
    try import_legacy("198.51.100.7", true, "legacy ban", true, false);
    try finish_legacy_migration();
    deinit();

    try init(std.testing.allocator, io, tmp.dir, 2);
    defer deinit();
    const policy = lookup("198.51.100.7");
    try std.testing.expect(policy.banned);
    try std.testing.expect(policy.op);
    try std.testing.expectEqualStrings("legacy ban", policy.ban_reason_slice());
}
