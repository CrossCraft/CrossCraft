const std = @import("std");
const assert = std.debug.assert;
const access_control = @import("AccessControl.zig");

const log = std.log.scoped(.players_db);

// This bounded cache stores observations; durable policy lives in access_control.
pub const max_capacity: u32 = 4096;
pub const ip_str_len = @import("core").Server.Client.ip_str_len;
pub const username_len: u32 = 16;

const flush_period_seconds: i64 = 60;
const file_name = "players.json";
// Allow escaped legacy ban reasons without tying migration to the current cache size.
const max_file_len: usize = max_capacity * 1024;

const PlayerRecord = struct {
    ip: [ip_str_len:0]u8,
    last_username: [username_len:0]u8,
    last_seen_unix: i64,

    pub fn ip_slice(self: *const PlayerRecord) []const u8 {
        return std.mem.sliceTo(self.ip[0..], 0);
    }
};

const JsonRecord = struct {
    ip: []const u8,
    last_username: []const u8 = "",
    last_seen_unix: i64 = 0,
};

const JsonFile = struct {
    records: []const JsonRecord,
};

// Read old policy fields for migration, but never write them back to the cache.
const LegacyJsonRecord = struct {
    ip: []const u8,
    last_username: []const u8 = "",
    ban_reason: []const u8 = "",
    last_seen_unix: i64 = 0,
    banned: bool = false,
    op: bool = false,
    whitelisted: bool = false,
};

const LegacyJsonFile = struct {
    records: []const LegacyJsonRecord,
};

var mutex: std.Io.Mutex = .init;
var records: []PlayerRecord = &.{};
var json_records: []JsonRecord = &.{};
var json_scratch: []u8 = &.{};
var count: u32 = 0;
var save_dir: std.Io.Dir = undefined;
var save_io: std.Io = undefined;
var owning_alloc: std.mem.Allocator = undefined;
var initialized: bool = false;
var dirty_since_unix: ?i64 = null;

pub fn init(alloc: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, cap_request: u32) !void {
    const cap = std.math.clamp(cap_request, 1, max_capacity);
    const scratch_len: usize = @as(usize, cap) * 256 + 1024;

    assert(!initialized);
    errdefer clear(alloc);

    records = try alloc.alloc(PlayerRecord, cap);
    json_records = try alloc.alloc(JsonRecord, cap);
    json_scratch = try alloc.alloc(u8, scratch_len);

    count = 0;
    save_dir = dir;
    save_io = io;
    owning_alloc = alloc;
    initialized = true;
    dirty_since_unix = null;
    try load_locked();
}

pub fn deinit() void {
    if (!initialized) return;
    mutex.lockUncancelable(save_io);
    defer mutex.unlock(save_io);

    if (dirty_since_unix != null) save_locked() catch |err| {
        log.warn("final {s} write failed: {}", .{ file_name, err });
    };
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
    dirty_since_unix = null;
}

/// Returns null for IPv6; the listener supports IPv4 only.
pub fn format_ip(addr: std.Io.net.IpAddress, out: *[ip_str_len]u8) ?[]const u8 {
    const v4 = switch (addr) {
        .ip4 => |a| a,
        .ip6 => return null,
    };
    const b = &v4.bytes;
    return std.fmt.bufPrint(out, "{d}.{d}.{d}.{d}", .{ b[0], b[1], b[2], b[3] }) catch null;
}

/// Batches metadata in memory until the periodic flush or shutdown.
pub fn record_completed_login(ip: []const u8, name: []const u8) void {
    if (!initialized or ip.len == 0) return;
    mutex.lockUncancelable(save_io);
    defer mutex.unlock(save_io);

    const now = std.Io.Clock.Timestamp.now(save_io, .real).raw.toSeconds();
    const rec = &records[upsert_index_locked(ip)];
    @memset(&rec.last_username, 0);
    const n = @min(name.len, username_len);
    @memcpy(rec.last_username[0..n], name[0..n]);
    rec.last_seen_unix = now;
    if (dirty_since_unix == null) dirty_since_unix = now;
}

/// Failed writes are retried at most once per flush period.
pub fn flush_if_due() void {
    if (!initialized) return;
    mutex.lockUncancelable(save_io);
    defer mutex.unlock(save_io);

    flush_if_due_locked(std.Io.Clock.Timestamp.now(save_io, .real).raw.toSeconds());
}

fn flush_if_due_locked(now: i64) void {
    const since = dirty_since_unix orelse return;
    if (now - since < flush_period_seconds) return;
    save_locked() catch |err| {
        log.warn("scheduled {s} write failed: {}", .{ file_name, err });
        dirty_since_unix = now;
        return;
    };
    dirty_since_unix = null;
}

fn find_index_locked(ip: []const u8) ?u32 {
    for (0..count) |i| {
        if (std.mem.eql(u8, records[i].ip_slice(), ip)) return @intCast(i);
    }
    return null;
}

fn upsert_index_locked(ip: []const u8) u32 {
    if (find_index_locked(ip)) |index| return index;

    const index: u32 = if (count < records.len) blk: {
        const next = count;
        count += 1;
        break :blk next;
    } else blk: {
        var oldest: u32 = 0;
        for (1..count) |i| {
            if (records[i].last_seen_unix < records[oldest].last_seen_unix) oldest = @intCast(i);
        }
        break :blk oldest;
    };

    const rec = &records[index];
    rec.* = std.mem.zeroes(PlayerRecord);
    const n = @min(ip.len, ip_str_len);
    @memcpy(rec.ip[0..n], ip[0..n]);
    return index;
}

fn load_locked() !void {
    const contents = save_dir.readFileAlloc(save_io, file_name, owning_alloc, .limited(max_file_len)) catch |err| switch (err) {
        error.FileNotFound => return,
        else => {
            log.warn("read {s} failed: {}", .{ file_name, err });
            return;
        },
    };
    defer owning_alloc.free(contents);

    if (contents.len == 0) return;

    const parsed = std.json.parseFromSlice(
        LegacyJsonFile,
        owning_alloc,
        contents,
        .{ .ignore_unknown_fields = true },
    ) catch |err| {
        log.warn("parse {s} failed: {}", .{ file_name, err });
        return;
    };
    defer parsed.deinit();

    for (parsed.value.records) |jr| {
        // Cache capacity must not discard legacy policy.
        try access_control.import_legacy(
            jr.ip,
            jr.banned,
            jr.ban_reason,
            jr.op,
            jr.whitelisted,
        );

        if (count >= records.len) continue;

        const rec = &records[count];
        count += 1;
        rec.* = std.mem.zeroes(PlayerRecord);
        const ip_n = @min(jr.ip.len, ip_str_len);
        @memcpy(rec.ip[0..ip_n], jr.ip[0..ip_n]);
        const name_n = @min(jr.last_username.len, username_len);
        @memcpy(rec.last_username[0..name_n], jr.last_username[0..name_n]);
        rec.last_seen_unix = jr.last_seen_unix;
    }
    if (parsed.value.records.len > records.len) {
        log.warn("{s} has more entries than max-players-saved={d}; truncating recent metadata", .{ file_name, records.len });
    }

    log.info("Loaded {s} ({d} recent player record(s))", .{ file_name, count });
}

fn save_locked() !void {
    for (0..count) |i| {
        json_records[i] = .{
            .ip = records[i].ip_slice(),
            .last_username = std.mem.sliceTo(records[i].last_username[0..], 0),
            .last_seen_unix = records[i].last_seen_unix,
        };
    }

    var writer = std.Io.Writer.fixed(json_scratch);
    try std.json.Stringify.value(
        JsonFile{ .records = json_records[0..count] },
        .{ .whitespace = .indent_2 },
        &writer,
    );

    const file = try save_dir.createFile(save_io, file_name, .{});
    defer file.close(save_io);

    try file.writeStreamingAll(save_io, writer.buffered());
}

test "completed login is batched before players json is written" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try init(std.testing.allocator, io, tmp.dir, 2);
    defer deinit();

    record_completed_login("203.0.113.42", "Alice");
    try std.testing.expect(dirty_since_unix != null);
    try std.testing.expectError(error.FileNotFound, tmp.dir.openFile(io, file_name, .{}));

    mutex.lockUncancelable(save_io);
    defer mutex.unlock(save_io);

    flush_if_due_locked(dirty_since_unix.? + flush_period_seconds - 1);
    try std.testing.expect(dirty_since_unix != null);
    flush_if_due_locked(dirty_since_unix.? + flush_period_seconds);
    try std.testing.expectEqual(null, dirty_since_unix);

    const file = try tmp.dir.openFile(io, file_name, .{});
    defer file.close(io);

    var contents: [512]u8 = undefined;
    const n = try file.readPositionalAll(io, &contents, 0);
    try std.testing.expect(std.mem.indexOf(u8, contents[0..n], "203.0.113.42") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents[0..n], "Alice") != null);
}

test "legacy policy survives cache truncation and does not override canonical policy" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const legacy = (" " ** 2048) ++
        \\{
        \\  "records": [
        \\    {"ip":"198.51.100.1","last_username":"One","banned":true,"ban_reason":"first"},
        \\    {"ip":"198.51.100.2","last_username":"Two","op":true,"whitelisted":true}
        \\  ]
        \\}
    ;
    const legacy_file = try tmp.dir.createFile(io, file_name, .{});
    try legacy_file.writeStreamingAll(io, legacy);
    legacy_file.close(io);

    try access_control.init(std.testing.allocator, io, tmp.dir, 2);
    defer access_control.deinit();

    try init(std.testing.allocator, io, tmp.dir, 1);
    defer deinit();

    try access_control.finish_legacy_migration();
    access_control.deinit();
    try access_control.init(std.testing.allocator, io, tmp.dir, 2);

    const first = access_control.lookup("198.51.100.1");
    const second = access_control.lookup("198.51.100.2");
    try std.testing.expect(first.banned);
    try std.testing.expectEqualStrings("first", first.ban_reason_slice());
    try std.testing.expect(second.op);
    try std.testing.expect(second.whitelisted);
    try std.testing.expectEqual(@as(u32, 1), count);

    try access_control.set_banned("198.51.100.1", false, "");
    deinit();
    access_control.deinit();
    try access_control.init(std.testing.allocator, io, tmp.dir, 2);
    try init(std.testing.allocator, io, tmp.dir, 1);
    try access_control.finish_legacy_migration();

    try std.testing.expect(!access_control.lookup("198.51.100.1").banned);
    const restored = access_control.lookup("198.51.100.2");
    try std.testing.expect(restored.op);
    try std.testing.expect(restored.whitelisted);
}
