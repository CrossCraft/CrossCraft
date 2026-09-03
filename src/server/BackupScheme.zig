const std = @import("std");

const log = std.log.scoped(.backup);

pub const autosave_default_seconds: u32 = 300;
pub const autosave_min_seconds: u32 = 60;
pub const autosave_max_seconds: u32 = 900;

pub fn parse_autosave_seconds(content: []const u8) u32 {
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        const key = "backup-autosave-seconds:";
        if (!std.mem.startsWith(u8, line, key)) continue;
        const value = std.mem.trim(u8, line[key.len..], " \t");
        const parsed = std.fmt.parseInt(u32, value, 10) catch {
            log.warn("backup-autosave-seconds value '{s}' is not a number; using default", .{value});
            return autosave_default_seconds;
        };
        const clamped = std.math.clamp(parsed, autosave_min_seconds, autosave_max_seconds);
        if (clamped != parsed) {
            log.info("backup-autosave-seconds {d} clamped to {d} (allowed {d}-{d})", .{
                parsed, clamped, autosave_min_seconds, autosave_max_seconds,
            });
        }
        return clamped;
    }
    return autosave_default_seconds;
}

pub const Epoch = struct {
    name: []const u8,
    interval_s: u32,
    keep: usize,
};

pub const epochs = [_]Epoch{
    .{ .name = "5min", .interval_s = 5 * 60, .keep = 12 },
    .{ .name = "1hr", .interval_s = 60 * 60, .keep = 6 },
    .{ .name = "6hr", .interval_s = 6 * 60 * 60, .keep = 4 },
    .{ .name = "1day", .interval_s = 24 * 60 * 60, .keep = 3 },
    .{ .name = "3days", .interval_s = 3 * 24 * 60 * 60, .keep = 3 },
    .{ .name = "1week", .interval_s = 7 * 24 * 60 * 60, .keep = 4 },
};

pub const backup_root = "backups";
pub const BACKUP_ENTRY_NAME_MAX = 24;
pub const BACKUP_SCAN_CAP = 64;

pub fn format_backup_name(buf: *[BACKUP_ENTRY_NAME_MAX]u8, ts: u64, ext: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "{d}{s}", .{ ts, ext });
}

pub fn parse_backup_timestamp(name: []const u8) ?u64 {
    var digits: usize = 0;
    while (digits < name.len and std.ascii.isDigit(name[digits])) digits += 1;
    if (digits == 0) return null;
    const rest = name[digits..];
    if (rest.len > 0 and rest[0] != '.') return null;
    return std.fmt.parseInt(u64, name[0..digits], 10) catch null;
}

pub const BackupEntry = struct {
    ts: u64,
    name: [BACKUP_ENTRY_NAME_MAX]u8,
    name_len: u8,

    pub fn name_slice(self: *const BackupEntry) []const u8 {
        return self.name[0..self.name_len];
    }

    pub fn less_ts(_: void, a: BackupEntry, b: BackupEntry) bool {
        return a.ts < b.ts;
    }
};

pub fn sort_entries_desc(entries: []BackupEntry) void {
    std.mem.sort(BackupEntry, entries, {}, struct {
        fn less(_: void, a: BackupEntry, b: BackupEntry) bool {
            return a.ts > b.ts;
        }
    }.less);
}

pub const SaveLocation = struct {
    parent: []const u8,
    file_name: []const u8,
};

const max_name_len: usize = 256;

pub fn parse_save_location(
    content: []const u8,
    default_location: []const u8,
    root_default_name: []const u8,
    buf: *[max_name_len]u8,
) []const u8 {
    @memcpy(buf[0..default_location.len], default_location);
    var result: []const u8 = buf[0..default_location.len];

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        const key = "save-location:";
        if (!std.mem.startsWith(u8, line, key)) continue;
        const value = std.mem.trim(u8, line[key.len..], " \t");
        if (value.len == 0) {
            log.warn("server.properties save-location is empty; using default", .{});
        } else if (value.len > buf.len) {
            log.warn("server.properties save-location too long; using default", .{});
        } else {
            @memcpy(buf[0..value.len], value);
            result = buf[0..value.len];
        }
        break;
    }

    if (std.mem.eql(u8, result, root_default_name)) {
        @memcpy(buf[0..default_location.len], default_location);
        result = buf[0..default_location.len];
    }
    return result;
}

pub fn split_save_location(
    raw: []const u8,
    parent_buf: *[max_name_len]u8,
    file_buf: *[max_name_len]u8,
) ?SaveLocation {
    const sep = std.mem.lastIndexOfScalar(u8, raw, '/');
    const parent_raw = if (sep) |i| raw[0..i] else "";
    const file_raw = if (sep) |i| raw[i + 1 ..] else raw;

    if (file_raw.len == 0 or file_raw.len > file_buf.len) {
        log.warn("Save location '{s}' has an invalid file name", .{raw});
        return null;
    }
    if (parent_raw.len > parent_buf.len) {
        log.warn("Save location parent '{s}' is too long", .{parent_raw});
        return null;
    }

    @memcpy(parent_buf[0..parent_raw.len], parent_raw);
    @memcpy(file_buf[0..file_raw.len], file_raw);
    return .{
        .parent = parent_buf[0..parent_raw.len],
        .file_name = file_buf[0..file_raw.len],
    };
}
