const std = @import("std");

const log = std.log.scoped(.backup);

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

pub fn split_save_location(raw: []const u8) ?SaveLocation {
    const sep = std.mem.lastIndexOfScalar(u8, raw, '/');
    const parent_raw = if (sep) |i| raw[0..i] else "";
    const file_raw = if (sep) |i| raw[i + 1 ..] else raw;

    if (file_raw.len == 0 or file_raw.len > max_name_len) {
        log.warn("Save location '{s}' has an invalid file name", .{raw});
        return null;
    }
    return .{ .parent = parent_raw, .file_name = file_raw };
}
