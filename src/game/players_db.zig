const std = @import("std");

const log = std.log.scoped(.players_db);

// --- Capacity ---

/// Hard ceiling shared by every platform. The actual table size comes
/// from `server.properties:max-players-saved` (default 1024) and is
/// clamped to this. Each record is ~140 bytes; 4096 caps memory at
/// ~560 KiB which is still comfortable on the leanest PSP target.
pub const max_capacity: u32 = 4096;

/// Largest IPv4 literal: "255.255.255.255". The listener binds 0.0.0.0
/// so we only ever see IPv4 peers; IPv6 support would just bloat every
/// record. Sentinel byte makes string compares trivial without a length
/// field.
pub const ip_str_len: u32 = 15;
pub const username_len: u32 = 16;
pub const reason_len: u32 = 64;

// --- In-memory record ---

pub const PlayerRecord = struct {
    ip: [ip_str_len:0]u8,
    last_username: [username_len:0]u8,
    ban_reason: [reason_len:0]u8,
    last_seen_unix: i64,
    banned: bool,
    op: bool,
    whitelisted: bool,

    pub fn ip_slice(self: *const PlayerRecord) []const u8 {
        return std.mem.sliceTo(self.ip[0..], 0);
    }

    pub fn username_slice(self: *const PlayerRecord) []const u8 {
        return std.mem.sliceTo(self.last_username[0..], 0);
    }

    pub fn ban_reason_slice(self: *const PlayerRecord) []const u8 {
        return std.mem.sliceTo(self.ban_reason[0..], 0);
    }

    /// True when dropping this record would silently weaken enforcement.
    /// LRU eviction inspects this to decide whether to log a warning.
    pub fn has_persistent_flag(self: *const PlayerRecord) bool {
        return self.banned or self.op or self.whitelisted;
    }
};

// --- JSON wire form ---

const JsonRecord = struct {
    ip: []const u8,
    last_username: []const u8 = "",
    ban_reason: []const u8 = "",
    last_seen_unix: i64 = 0,
    banned: bool = false,
    op: bool = false,
    whitelisted: bool = false,
};

const JsonFile = struct {
    records: []const JsonRecord,
};

// --- Module state ---

var records: []PlayerRecord = &.{};
var count: u32 = 0;
var capacity: u32 = 0;
var save_dir: std.Io.Dir = undefined;
var save_io: std.Io = undefined;
var owning_alloc: std.mem.Allocator = undefined;
var initialized: bool = false;
var last_eviction_warning: ?[ip_str_len:0]u8 = null;

// JSON scratch buffer sized once at init. Lives off the heap (not the
// per-task stack) so the PSP's 64 KiB async stack isn't blown when a
// large record table is serialized.
var json_scratch: []u8 = &.{};

const file_name = "players.json";

// --- Init / deinit ---

pub fn init(alloc: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, cap_request: u32) !void {
    const cap = std.math.clamp(cap_request, 1, max_capacity);
    records = try alloc.alloc(PlayerRecord, cap);
    @memset(std.mem.sliceAsBytes(records), 0);
    // ~256 bytes per record covers the worst-case JSON expansion with
    // indent_2 plus a small header allowance. Two passes use the same
    // buffer (parse + serialize) so size for the larger of the two.
    const json_size: usize = @as(usize, cap) * 256 + 1024;
    json_scratch = try alloc.alloc(u8, json_size);
    count = 0;
    capacity = cap;
    save_dir = dir;
    save_io = io;
    owning_alloc = alloc;
    initialized = true;
    load();
}

pub fn deinit() void {
    if (!initialized) return;
    owning_alloc.free(records);
    owning_alloc.free(json_scratch);
    records = &.{};
    json_scratch = &.{};
    count = 0;
    capacity = 0;
    initialized = false;
}

// --- IP canonicalisation ---

/// Format an IPv4 peer address as "1.2.3.4" into `out`. Returns null
/// when the address is IPv6 (the listener is IPv4-only, so this should
/// never happen in practice -- treat it as a hard skip on lookup).
pub fn format_ip(addr: std.Io.net.IpAddress, out: *[ip_str_len]u8) ?[]const u8 {
    const v4 = switch (addr) {
        .ip4 => |a| a,
        .ip6 => return null,
    };
    const b = &v4.bytes;
    return std.fmt.bufPrint(out, "{d}.{d}.{d}.{d}", .{ b[0], b[1], b[2], b[3] }) catch null;
}

/// Canonicalise a user-typed IPv4 literal (e.g. "1.2.3.4") into `out`.
/// Returns null on parse failure or if the user typed an IPv6 literal.
pub fn canonicalise_literal(text: []const u8, out: *[ip_str_len]u8) ?[]const u8 {
    const parsed = std.Io.net.IpAddress.parseIp4(text, 0) catch return null;
    return format_ip(parsed, out);
}

// --- Lookup ---

/// O(n) scan; n is bounded by `max_players_saved` (1024 default) so this is
/// fine even on the connect hot path.
pub fn lookup_by_ip(ip: []const u8) ?*PlayerRecord {
    if (!initialized) return null;
    for (0..count) |i| {
        if (std.mem.eql(u8, records[i].ip_slice(), ip)) {
            return &records[i];
        }
    }
    return null;
}

pub fn lookup_by_username(name: []const u8) ?*PlayerRecord {
    if (!initialized) return null;
    for (0..count) |i| {
        if (std.mem.eql(u8, records[i].username_slice(), name)) {
            return &records[i];
        }
    }
    return null;
}

// --- Mutators ---

/// Find-or-insert by IP. May evict the LRU entry; on eviction of a record
/// with persistent flags (ban/op/whitelist) we log a loud warning so the
/// operator notices a silent enforcement gap.
pub fn upsert(ip: []const u8) ?*PlayerRecord {
    if (!initialized) return null;
    if (lookup_by_ip(ip)) |existing| return existing;

    var slot: u32 = undefined;
    if (count < capacity) {
        slot = count;
        count += 1;
    } else {
        slot = pick_lru();
        const victim = &records[slot];
        if (victim.has_persistent_flag()) {
            warn_eviction(victim);
        }
    }

    const rec = &records[slot];
    rec.* = std.mem.zeroes(PlayerRecord);
    const n = @min(ip.len, ip_str_len);
    @memcpy(rec.ip[0..n], ip[0..n]);
    rec.last_seen_unix = now_unix();
    return rec;
}

pub fn touch_seen(ip: []const u8) void {
    const rec = upsert(ip) orelse return;
    rec.last_seen_unix = now_unix();
    save();
}

pub fn set_username(ip: []const u8, name: []const u8) void {
    const rec = upsert(ip) orelse return;
    @memset(&rec.last_username, 0);
    const n = @min(name.len, username_len);
    @memcpy(rec.last_username[0..n], name[0..n]);
    save();
}

pub fn set_banned(ip: []const u8, banned: bool, reason: []const u8) ?*PlayerRecord {
    const rec = upsert(ip) orelse return null;
    rec.banned = banned;
    @memset(&rec.ban_reason, 0);
    if (banned) {
        const n = @min(reason.len, reason_len);
        @memcpy(rec.ban_reason[0..n], reason[0..n]);
    }
    save();
    return rec;
}

pub fn set_op(ip: []const u8, op: bool) ?*PlayerRecord {
    const rec = upsert(ip) orelse return null;
    rec.op = op;
    save();
    return rec;
}

pub fn set_whitelisted(ip: []const u8, whitelisted: bool) ?*PlayerRecord {
    const rec = upsert(ip) orelse return null;
    rec.whitelisted = whitelisted;
    save();
    return rec;
}

// --- Internal helpers ---

fn pick_lru() u32 {
    var idx: u32 = 0;
    var oldest: i64 = records[0].last_seen_unix;
    for (1..count) |i| {
        if (records[i].last_seen_unix < oldest) {
            oldest = records[i].last_seen_unix;
            idx = @intCast(i);
        }
    }
    return idx;
}

fn warn_eviction(victim: *const PlayerRecord) void {
    log.warn(
        "players.json full (cap={d}): evicting ip={s} last_user='{s}' last_seen={d} flags=[{s}{s}{s}] -- enforcement for this IP is now LOST. Raise max-players-saved in server.properties.",
        .{
            capacity,
            victim.ip_slice(),
            victim.username_slice(),
            victim.last_seen_unix,
            if (victim.banned) "banned " else "",
            if (victim.op) "op " else "",
            if (victim.whitelisted) "whitelisted" else "",
        },
    );
    // Stash the IP so the console layer can echo a yellow warning if it
    // wants. Cleared by `take_eviction_warning`.
    var stash: [ip_str_len:0]u8 = std.mem.zeroes([ip_str_len:0]u8);
    const slice = victim.ip_slice();
    @memcpy(stash[0..slice.len], slice);
    last_eviction_warning = stash;
}

/// One-shot getter for the console layer. Returns the IP slice of the
/// most recently evicted persistent record (since the previous call), or
/// null if none. Subsequent calls return null until the next eviction.
pub fn take_eviction_warning(out: *[ip_str_len:0]u8) ?[]const u8 {
    if (last_eviction_warning) |stash| {
        out.* = stash;
        last_eviction_warning = null;
        return std.mem.sliceTo(out[0..], 0);
    }
    return null;
}

fn now_unix() i64 {
    return std.Io.Clock.Timestamp.now(save_io, .real).raw.toSeconds();
}

// --- JSON load/save ---

fn load() void {
    const file = save_dir.openFile(save_io, file_name, .{}) catch return;
    defer file.close(save_io);

    const n = file.readPositionalAll(save_io, json_scratch, 0) catch |err| {
        log.warn("read {s} failed: {}", .{ file_name, err });
        return;
    };
    if (n == 0) return;

    // Reserve a heap-backed arena for the parser. The owning_alloc is the
    // same pool the records table lives in, so this stays predictable.
    var arena = std.heap.ArenaAllocator.init(owning_alloc);
    defer arena.deinit();
    const parsed = std.json.parseFromSliceLeaky(
        JsonFile,
        arena.allocator(),
        json_scratch[0..n],
        .{ .ignore_unknown_fields = true },
    ) catch |err| {
        log.warn("parse {s} failed: {} -- starting empty", .{ file_name, err });
        return;
    };

    count = 0;
    for (parsed.records) |jr| {
        if (count >= capacity) {
            log.warn("{s} has more entries than max-players-saved={d}; truncating", .{ file_name, capacity });
            break;
        }
        const rec = &records[count];
        rec.* = std.mem.zeroes(PlayerRecord);
        const ip_n = @min(jr.ip.len, ip_str_len);
        @memcpy(rec.ip[0..ip_n], jr.ip[0..ip_n]);
        const u_n = @min(jr.last_username.len, username_len);
        @memcpy(rec.last_username[0..u_n], jr.last_username[0..u_n]);
        const r_n = @min(jr.ban_reason.len, reason_len);
        @memcpy(rec.ban_reason[0..r_n], jr.ban_reason[0..r_n]);
        rec.last_seen_unix = jr.last_seen_unix;
        rec.banned = jr.banned;
        rec.op = jr.op;
        rec.whitelisted = jr.whitelisted;
        count += 1;
    }

    log.info("Loaded {s} ({d} record(s))", .{ file_name, count });
}

/// Synchronous write after every mutation -- Classic Minecraft is a tiny
/// audience and ban state correctness matters more than save throughput.
fn save() void {
    if (!initialized) return;

    var arena = std.heap.ArenaAllocator.init(owning_alloc);
    defer arena.deinit();
    const a = arena.allocator();

    var jr_list = a.alloc(JsonRecord, count) catch |err| {
        log.warn("alloc JsonRecord list failed: {}", .{err});
        return;
    };
    for (0..count) |i| {
        jr_list[i] = .{
            .ip = records[i].ip_slice(),
            .last_username = records[i].username_slice(),
            .ban_reason = records[i].ban_reason_slice(),
            .last_seen_unix = records[i].last_seen_unix,
            .banned = records[i].banned,
            .op = records[i].op,
            .whitelisted = records[i].whitelisted,
        };
    }
    const json_file: JsonFile = .{ .records = jr_list };

    var w = std.Io.Writer.fixed(json_scratch);
    std.json.Stringify.value(json_file, .{ .whitespace = .indent_2 }, &w) catch |err| {
        log.warn("serialize {s} failed: {}", .{ file_name, err });
        return;
    };
    const slice = w.buffered();

    const file = save_dir.createFile(save_io, file_name, .{}) catch |err| {
        log.warn("create {s} failed: {}", .{ file_name, err });
        return;
    };
    defer file.close(save_io);
    file.writeStreamingAll(save_io, slice) catch |err|
        log.warn("write {s} failed: {}", .{ file_name, err });
}
