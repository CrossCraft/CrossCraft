const std = @import("std");
const access_control = @import("access_control.zig");

const log = std.log.scoped(.players_db);

/// Recent-player metadata is deliberately bounded and non-authoritative. IP
/// bans, ops, and whitelist entries live in access_control.zig instead.
pub const max_capacity: u32 = 4096;
pub const ip_str_len: u32 = 15;
pub const username_len: u32 = 16;

const flush_period_seconds: i64 = 60;
const file_name = "players.json";

pub const PlayerRecord = struct {
    ip: [ip_str_len:0]u8,
    last_username: [username_len:0]u8,
    last_seen_unix: i64,

    pub fn ip_slice(self: *const PlayerRecord) []const u8 {
        return std.mem.sliceTo(self.ip[0..], 0);
    }

    pub fn username_slice(self: *const PlayerRecord) []const u8 {
        return std.mem.sliceTo(self.last_username[0..], 0);
    }
};

/// Current on-disk form. The cache contains only observation metadata, never
/// enforcement state.
const JsonRecord = struct {
    ip: []const u8,
    last_username: []const u8 = "",
    last_seen_unix: i64 = 0,
};

const JsonFile = struct {
    records: []const JsonRecord,
};

/// Legacy players.json records carried policy flags. We read them only so the
/// first boot after the split can import them into access-control.json.
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
var capacity: u32 = 0;
var save_dir: std.Io.Dir = undefined;
var save_io: std.Io = undefined;
var owning_alloc: std.mem.Allocator = undefined;
var initialized: bool = false;
var dirty: bool = false;
var dirty_since_unix: i64 = 0;

pub fn init(alloc: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, cap_request: u32) !void {
    const cap = std.math.clamp(cap_request, 1, max_capacity);
    const scratch_len: usize = @as(usize, cap) * 256 + 1024;

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
        dirty = false;
        dirty_since_unix = 0;
    }

    records = try alloc.alloc(PlayerRecord, cap);
    json_records = try alloc.alloc(JsonRecord, cap);
    json_scratch = try alloc.alloc(u8, scratch_len);

    @memset(std.mem.sliceAsBytes(records), 0);
    count = 0;
    capacity = cap;
    save_dir = dir;
    save_io = io;
    owning_alloc = alloc;
    initialized = true;
    dirty = false;
    dirty_since_unix = 0;
    try load_locked();
}

pub fn deinit() void {
    if (!initialized) return;
    mutex.lockUncancelable(save_io);
    defer mutex.unlock(save_io);

    flush_now_locked();
    owning_alloc.free(records);
    owning_alloc.free(json_records);
    owning_alloc.free(json_scratch);
    records = &.{};
    json_records = &.{};
    json_scratch = &.{};
    count = 0;
    capacity = 0;
    initialized = false;
    dirty = false;
    dirty_since_unix = 0;
}

/// Format an IPv4 peer address as "1.2.3.4" into out. Returns null for IPv6;
/// the listener is IPv4-only today.
pub fn format_ip(addr: std.Io.net.IpAddress, out: *[ip_str_len]u8) ?[]const u8 {
    const v4 = switch (addr) {
        .ip4 => |a| a,
        .ip6 => return null,
    };
    const b = &v4.bytes;
    return std.fmt.bufPrint(out, "{d}.{d}.{d}.{d}", .{ b[0], b[1], b[2], b[3] }) catch null;
}

/// Canonicalise a user-typed IPv4 literal (e.g. "1.2.3.4") into out.
pub fn canonicalise_literal(text: []const u8, out: *[ip_str_len]u8) ?[]const u8 {
    const parsed = std.Io.net.IpAddress.parseIp4(text, 0) catch return null;
    return format_ip(parsed, out);
}

/// Record only a fully initialized player. This function does no I/O; a
/// single server update later flushes the accumulated cache at most once per
/// minute, while a clean shutdown flushes any remaining changes.
pub fn record_completed_login(ip: []const u8, name: []const u8) void {
    if (ip.len == 0) return;

    if (!initialized) return;
    mutex.lockUncancelable(save_io);
    defer mutex.unlock(save_io);
    if (!initialized) return;

    const now = now_unix();
    const rec = &records[upsert_index_locked(ip)];
    @memset(&rec.last_username, 0);
    const n = @min(name.len, username_len);
    @memcpy(rec.last_username[0..n], name[0..n]);
    rec.last_seen_unix = now;
    if (!dirty) {
        dirty = true;
        dirty_since_unix = now;
    }
}

/// Called from the standalone server update loop. A failed write is retried
/// no more often than once per period, avoiding an error-path disk-I/O loop.
pub fn flush_if_due() void {
    if (!initialized or !dirty) return;
    mutex.lockUncancelable(save_io);
    defer mutex.unlock(save_io);
    if (!initialized or !dirty) return;
    flush_if_due_locked(now_unix());
}

fn flush_if_due_locked(now: i64) void {
    if (now - dirty_since_unix < flush_period_seconds) return;
    save_locked() catch |err| {
        log.warn("scheduled {s} write failed: {}", .{ file_name, err });
        dirty_since_unix = now;
        return;
    };
    dirty = false;
    dirty_since_unix = 0;
}

fn flush_now_locked() void {
    if (!dirty) return;
    save_locked() catch |err| {
        log.warn("final {s} write failed: {}", .{ file_name, err });
        return;
    };
    dirty = false;
    dirty_since_unix = 0;
}

fn find_index_locked(ip: []const u8) ?u32 {
    for (0..count) |i| {
        if (std.mem.eql(u8, records[i].ip_slice(), ip)) return @intCast(i);
    }
    return null;
}

fn upsert_index_locked(ip: []const u8) u32 {
    if (find_index_locked(ip)) |index| return index;

    const index: u32 = if (count < capacity) blk: {
        const next = count;
        count += 1;
        break :blk next;
    } else pick_lru_locked();

    const rec = &records[index];
    rec.* = std.mem.zeroes(PlayerRecord);
    const n = @min(ip.len, ip_str_len);
    @memcpy(rec.ip[0..n], ip[0..n]);
    return index;
}

fn pick_lru_locked() u32 {
    var index: u32 = 0;
    var oldest = records[0].last_seen_unix;
    for (1..count) |i| {
        if (records[i].last_seen_unix < oldest) {
            oldest = records[i].last_seen_unix;
            index = @intCast(i);
        }
    }
    return index;
}

fn now_unix() i64 {
    return std.Io.Clock.Timestamp.now(save_io, .real).raw.toSeconds();
}

fn load_locked() !void {
    const file = save_dir.openFile(save_io, file_name, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => {
            log.warn("open {s} failed: {}", .{ file_name, err });
            return;
        },
    };
    defer file.close(save_io);

    const n = file.readPositionalAll(save_io, json_scratch, 0) catch |err| {
        log.warn("read {s} failed: {}", .{ file_name, err });
        return;
    };
    if (n == 0) return;

    var arena = std.heap.ArenaAllocator.init(owning_alloc);
    defer arena.deinit();
    const parsed = std.json.parseFromSliceLeaky(
        LegacyJsonFile,
        arena.allocator(),
        json_scratch[0..n],
        .{ .ignore_unknown_fields = true },
    ) catch |err| {
        log.warn("parse {s} failed: {}", .{ file_name, err });
        return;
    };

    var metadata_truncated = false;
    for (parsed.records) |jr| {
        // Import policy before applying the bounded metadata limit. A legacy
        // file may contain more observations than the new cache capacity, but
        // no ban/op/whitelist entry may be skipped because of that.
        try access_control.import_legacy(
            jr.ip,
            jr.banned,
            jr.ban_reason,
            jr.op,
            jr.whitelisted,
        );

        if (count >= capacity) {
            if (!metadata_truncated) {
                log.warn("{s} has more entries than max-players-saved={d}; truncating recent metadata", .{ file_name, capacity });
                metadata_truncated = true;
            }
            continue;
        }

        const rec = &records[count];
        count += 1;
        rec.* = std.mem.zeroes(PlayerRecord);
        const ip_n = @min(jr.ip.len, ip_str_len);
        @memcpy(rec.ip[0..ip_n], jr.ip[0..ip_n]);
        const name_n = @min(jr.last_username.len, username_len);
        @memcpy(rec.last_username[0..name_n], jr.last_username[0..name_n]);
        rec.last_seen_unix = jr.last_seen_unix;
    }

    log.info("Loaded {s} ({d} recent player record(s))", .{ file_name, count });
}

fn save_locked() !void {
    for (0..count) |i| {
        json_records[i] = .{
            .ip = records[i].ip_slice(),
            .last_username = records[i].username_slice(),
            .last_seen_unix = records[i].last_seen_unix,
        };
    }

    var writer = std.Io.Writer.fixed(json_scratch);
    std.json.Stringify.value(
        JsonFile{ .records = json_records[0..count] },
        .{ .whitespace = .indent_2 },
        &writer,
    ) catch |err| {
        log.warn("serialize {s} failed: {}", .{ file_name, err });
        return err;
    };

    const file = save_dir.createFile(save_io, file_name, .{}) catch |err| {
        log.warn("create {s} failed: {}", .{ file_name, err });
        return err;
    };
    defer file.close(save_io);
    file.writeStreamingAll(save_io, writer.buffered()) catch |err| {
        log.warn("write {s} failed: {}", .{ file_name, err });
        return err;
    };
}

test "completed login is batched before players json is written" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try init(std.testing.allocator, io, tmp.dir, 2);
    defer deinit();

    record_completed_login("203.0.113.42", "Alice");
    try std.testing.expect(dirty);
    try std.testing.expectError(error.FileNotFound, tmp.dir.openFile(io, file_name, .{}));

    mutex.lockUncancelable(save_io);
    defer mutex.unlock(save_io);
    flush_if_due_locked(dirty_since_unix + flush_period_seconds - 1);
    try std.testing.expect(dirty);
    flush_if_due_locked(dirty_since_unix + flush_period_seconds);
    try std.testing.expect(!dirty);

    const file = try tmp.dir.openFile(io, file_name, .{});
    defer file.close(io);
    var contents: [512]u8 = undefined;
    const n = try file.readPositionalAll(io, &contents, 0);
    try std.testing.expect(std.mem.indexOf(u8, contents[0..n], "203.0.113.42") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents[0..n], "Alice") != null);
}

test "legacy players flags migrate into access control" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const legacy =
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
    try init(std.testing.allocator, io, tmp.dir, 2);
    defer deinit();
    try access_control.finish_legacy_migration();

    const first = access_control.lookup("198.51.100.1");
    const second = access_control.lookup("198.51.100.2");
    try std.testing.expect(first.banned);
    try std.testing.expectEqualStrings("first", first.ban_reason_slice());
    try std.testing.expect(second.op);
    try std.testing.expect(second.whitelisted);
}
