const std = @import("std");
const ae = @import("aether");
const core = @import("core");

const Block = core.blocks.Block;

const log = std.log.scoped(.backup);

const epochs = [_]struct { name: []const u8, interval_s: u32, keep: usize }{
    .{ .name = "5min", .interval_s = 5 * 60, .keep = 12 },
    .{ .name = "1hr", .interval_s = 60 * 60, .keep = 6 },
    .{ .name = "6hr", .interval_s = 6 * 60 * 60, .keep = 4 },
    .{ .name = "1day", .interval_s = 24 * 60 * 60, .keep = 3 },
    .{ .name = "3days", .interval_s = 3 * 24 * 60 * 60, .keep = 3 },
    .{ .name = "1week", .interval_s = 7 * 24 * 60 * 60, .keep = 4 },
};
const backup_root = "backups";
const backup_entry_name_max = 24;
const backup_scan_cap = 64;
const max_name_len: usize = 256;

const BackupEntry = struct {
    ts: u64,
    name: [backup_entry_name_max]u8,
    name_len: u8,

    fn name_slice(self: *const BackupEntry) []const u8 {
        return self.name[0..self.name_len];
    }

    fn newest_first(_: void, a: BackupEntry, b: BackupEntry) bool {
        return a.ts > b.ts;
    }
};

fn file_exists(io: std.Io, dir: std.Io.Dir, path: []const u8) bool {
    const file = dir.openFile(io, path, .{}) catch return false;
    file.close(io);
    return true;
}

fn validate_save_file(io: std.Io, dir: std.Io.Dir, file_name: []const u8, scratch: std.mem.Allocator) bool {
    // Backups may use different dimensions from the configured world.
    const dims = core.World.SaveFormat.sniff_dims(io, dir, file_name, scratch) orelse {
        log.warn("'{s}' has no recognizable save header; failing validation", .{file_name});
        return false;
    };

    const file = dir.openFile(io, file_name, .{}) catch return false;
    defer file.close(io);

    const read_prefix_buf_len: usize = 32768;
    const read_buf = scratch.alloc(u8, read_prefix_buf_len) catch |err| {
        log.err("Failed to allocate save validation buffer: {}", .{err});
        return false;
    };
    defer scratch.free(read_buf);

    var reader = file.reader(io, read_buf);

    const prefix = reader.interface.peek(read_prefix_buf_len) catch reader.interface.buffered();
    if (prefix.len < 2) return false;

    const sniff = core.World.SaveFormat.detect(prefix) orelse return false;
    if (std.meta.activeTag(sniff) == .classic_cw and
        !core.World.SaveFormat.verify_classic_cw(prefix, scratch))
    {
        log.warn("'{s}' is gzip but not ClassicWorld NBT; failing validation", .{file_name});
        return false;
    }

    const blocks = scratch.alloc(Block, dims.volume()) catch |err| {
        log.err("Failed to allocate world scratch for save validation: {}", .{err});
        return false;
    };
    defer scratch.free(blocks);

    const outcome = sniff.load_world(scratch, dims, blocks, &reader.interface) catch |err| {
        log.warn("'{s}' failed to parse as {s}: {}", .{ file_name, @tagName(sniff), err });
        return false;
    };

    if (!dims.matches(outcome.dimensions)) {
        log.warn("'{s}' has dimensions {d}x{d}x{d}, expected {d}x{d}x{d}", .{
            file_name,
            outcome.dimensions[0],
            outcome.dimensions[1],
            outcome.dimensions[2],
            dims.length,
            dims.height,
            dims.depth,
        });
        return false;
    }
    return true;
}

pub fn pre_init_validate_and_restore(
    io: std.Io,
    data_dir: std.Io.Dir,
    alloc: std.mem.Allocator,
    save_location: []const u8,
) void {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    const scratch = arena.allocator();

    const separator = std.mem.lastIndexOfScalar(u8, save_location, '/');
    const parent = if (separator) |i| save_location[0..i] else "";
    const file_name = if (separator) |i| save_location[i + 1 ..] else save_location;
    if (file_name.len == 0 or file_name.len > max_name_len) {
        log.warn("Save location '{s}' has an invalid file name", .{save_location});
        return;
    }
    const save_dir = if (parent.len == 0) data_dir else data_dir.createDirPathOpen(io, parent, .{}) catch |err| {
        log.err("Failed to open save dir '{s}': {}", .{ parent, err });
        return;
    };
    defer if (parent.len != 0) save_dir.close(io);

    const exists = file_exists(io, save_dir, file_name);
    if (exists and validate_save_file(io, save_dir, file_name, scratch)) return;

    if (exists) {
        log.warn("Save '{s}' failed validation; attempting backup restore", .{file_name});
    } else {
        log.info("Save '{s}' not found; checking backups", .{file_name});
    }

    if (restore_newest_valid(io, save_dir, file_name, scratch)) {
        log.info("Backup restore complete; the restored save will be loaded", .{});
    } else if (exists) {
        log.err("No valid backup found; the world will be regenerated", .{});
    }
}

fn restore_newest_valid(io: std.Io, save_dir: std.Io.Dir, save_file_name: []const u8, scratch: std.mem.Allocator) bool {
    for (epochs) |epoch| {
        var bucket = open_bucket(io, save_dir, epoch.name) orelse continue;
        defer bucket.close(io);

        var entries: [backup_scan_cap]BackupEntry = undefined;
        const count = collect_backups(io, bucket, &entries);
        if (count == 0) continue;
        std.mem.sort(BackupEntry, entries[0..count], {}, BackupEntry.newest_first);

        for (entries[0..count]) |entry| {
            if (!validate_save_file(io, bucket, entry.name_slice(), scratch)) {
                log.warn("Backup '{s}/{s}' failed validation; trying older", .{ epoch.name, entry.name_slice() });
                continue;
            }

            var tmp_buf: [max_name_len + 16]u8 = undefined;
            const tmp_name = std.fmt.bufPrint(&tmp_buf, "{s}.restore.tmp", .{save_file_name}) catch {
                log.err("Restore temp name overflow", .{});
                return false;
            };

            bucket.copyFile(entry.name_slice(), save_dir, tmp_name, io, .{}) catch |err| {
                log.err("Failed to copy backup '{s}/{s}' into place: {}", .{ epoch.name, entry.name_slice(), err });
                continue;
            };

            preserve_displaced_save(io, save_dir, save_file_name);

            save_dir.rename(tmp_name, save_dir, save_file_name, io) catch |err| {
                log.err("Failed to promote restored save: {}", .{err});
                save_dir.deleteFile(io, tmp_name) catch {};
                continue;
            };

            log.info("Restored save '{s}' from backup '{s}/{s}'", .{ save_file_name, epoch.name, entry.name_slice() });
            return true;
        }
    }
    return false;
}

fn preserve_displaced_save(io: std.Io, save_dir: std.Io.Dir, save_file_name: []const u8) void {
    var corrupt_buf: [max_name_len + 12]u8 = undefined;
    const corrupt_name = std.fmt.bufPrint(&corrupt_buf, "{s}.corrupt", .{save_file_name}) catch return;

    save_dir.deleteFile(io, corrupt_name) catch {};
    save_dir.rename(save_file_name, save_dir, corrupt_name, io) catch {};
}

fn open_bucket(io: std.Io, save_dir: std.Io.Dir, epoch_name: []const u8) ?std.Io.Dir {
    var path_buf: [64]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ backup_root, epoch_name }) catch return null;
    return save_dir.openDir(io, path, .{ .iterate = true }) catch null;
}

fn parse_backup_timestamp(name: []const u8) ?u64 {
    var digits: usize = 0;
    while (digits < name.len and std.ascii.isDigit(name[digits])) digits += 1;
    if (digits == 0 or (digits < name.len and name[digits] != '.')) return null;
    return std.fmt.parseInt(u64, name[0..digits], 10) catch null;
}

fn collect_backups(io: std.Io, dir: std.Io.Dir, entries: []BackupEntry) usize {
    var iter = dir.iterate();
    var count: usize = 0;
    while (iter.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        const ts = parse_backup_timestamp(entry.name) orelse continue;
        if (entry.name.len > backup_entry_name_max) continue;
        if (count == entries.len) {
            log.warn("Backup bucket scan capped at {d} entries", .{entries.len});
            break;
        }
        entries[count] = .{
            .ts = ts,
            .name = undefined,
            .name_len = @intCast(entry.name.len),
        };
        @memcpy(entries[count].name[0..entry.name.len], entry.name);
        count += 1;
    }
    return count;
}

fn newest_timestamp(io: std.Io, dir: std.Io.Dir) ?u64 {
    var iter = dir.iterate();
    var newest: ?u64 = null;
    while (iter.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        const ts = parse_backup_timestamp(entry.name) orelse continue;
        if (newest == null or ts > newest.?) newest = ts;
    }
    return newest;
}

fn prune_bucket(io: std.Io, dir: std.Io.Dir, keep: usize) void {
    var entries: [backup_scan_cap]BackupEntry = undefined;
    const count = collect_backups(io, dir, &entries);
    if (count <= keep) return;

    std.mem.sort(BackupEntry, entries[0..count], {}, BackupEntry.newest_first);
    for (entries[keep..count]) |entry| {
        dir.deleteFile(io, entry.name_slice()) catch |err| {
            log.warn("Failed to prune backup '{s}': {}", .{ entry.name_slice(), err });
        };
    }
}

const Backup = @This();

autosave_seconds: u32,
save_dir: std.Io.Dir,
save_file_name: []const u8,
ext: []const u8,
last_save_ms: u64,

pub fn init(io: std.Io, autosave_seconds: u32) Backup {
    var self: Backup = .{
        .autosave_seconds = autosave_seconds,
        .save_dir = core.World.saver.save_dir,
        .save_file_name = core.World.saver.save_file_name,
        .ext = "",
        .last_save_ms = current_unix_ms(io),
    };

    if (self.save_file_name.len == 0 or self.save_file_name.len > max_name_len) {
        log.err("Could not resolve save file name; periodic backups disabled", .{});
        self.save_file_name = "";
        return self;
    }
    if (std.mem.lastIndexOfScalar(u8, self.save_file_name, '.')) |dot| {
        const ext = self.save_file_name[dot..];
        if (ext.len <= 8) self.ext = ext;
    }

    self.prepare_buckets(io);
    if (file_exists(io, self.save_dir, self.save_file_name) and !core.World.saver.save_in_progress()) {
        self.snapshot_into(io, 0, self.last_save_ms);
    }
    log.info("Backups active: autosave every {d}s into '{s}/', {d} epoch buckets", .{
        self.autosave_seconds, backup_root, epochs.len,
    });
    return self;
}

fn prepare_buckets(self: *Backup, io: std.Io) void {
    for (epochs) |epoch| {
        var path_buf: [64]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ backup_root, epoch.name }) catch continue;
        var bucket = self.save_dir.createDirPathOpen(io, path, .{}) catch |err| {
            log.err("Failed to create backup bucket '{s}': {}", .{ path, err });
            continue;
        };
        bucket.close(io);
    }
}

const poll_interval_ms: i64 = 2_000;

pub fn loop(self: *Backup, engine: *ae.Engine) std.Io.Cancelable!void {
    while (true) {
        try engine.io.sleep(.{ .nanoseconds = poll_interval_ms * std.time.ns_per_ms }, .real);
        self.tick_once(engine.io);
    }
}

fn tick_once(self: *Backup, io: std.Io) void {
    if (self.save_file_name.len == 0) return;

    const now_ms = current_unix_ms(io);
    if (now_ms < self.last_save_ms) self.last_save_ms = now_ms;
    if (now_ms - self.last_save_ms < @as(u64, self.autosave_seconds) * std.time.ms_per_s) return;

    if (core.World.saver.save_in_progress()) return;

    core.World.save();
    core.World.wait_for_save();
    self.last_save_ms = now_ms;

    for (0..epochs.len) |index| self.snapshot_into(io, index, now_ms);
}

fn snapshot_into(self: *Backup, io: std.Io, index: usize, now_ms: u64) void {
    const epoch = epochs[index];
    var bucket = open_bucket(io, self.save_dir, epoch.name) orelse {
        log.err("Failed to open backup bucket '{s}'", .{epoch.name});
        return;
    };
    defer bucket.close(io);

    if (index != 0) {
        if (newest_timestamp(io, bucket)) |ts| {
            if (now_ms -| ts < @as(u64, epoch.interval_s) * std.time.ms_per_s) return;
        }
    }

    var name_buf: [backup_entry_name_max]u8 = undefined;
    const name = std.fmt.bufPrint(&name_buf, "{d}{s}", .{ current_unix_ms(io), self.ext }) catch {
        log.err("Backup name overflow", .{});
        return;
    };

    self.save_dir.copyFile(self.save_file_name, bucket, name, io, .{}) catch |err| {
        log.err("Failed to snapshot '{s}' into '{s}': {}", .{ self.save_file_name, epoch.name, err });
        return;
    };

    prune_bucket(io, bucket, epoch.keep);
    log.info("Snapshot '{s}' stored in bucket '{s}'", .{ name, epoch.name });
}

fn current_unix_ms(io: std.Io) u64 {
    return @intCast(@max(std.Io.Clock.Timestamp.now(io, .real).raw.toMilliseconds(), 0));
}
