const std = @import("std");
const ae = @import("aether");
const game = @import("game");

const scheme = @import("BackupScheme.zig");
const c = @import("common").consts;
const Block = c.Block;

const log = std.log.scoped(.backup);

const epochs = scheme.epochs;
const backup_root = scheme.backup_root;

const properties_file_name = "server.properties";
const max_config_len: usize = 4096;
const max_name_len: usize = 256;

// --- Configuration ---

pub const Config = struct {
    autosave_seconds: u32 = scheme.autosave_default_seconds,

    pub fn load(io: std.Io, data_dir: std.Io.Dir) Config {
        var buf: [max_config_len]u8 = undefined;
        return .{ .autosave_seconds = scheme.parse_autosave_seconds(read_properties(io, data_dir, &buf)) };
    }
};

fn read_properties(io: std.Io, data_dir: std.Io.Dir, buf: *[max_config_len]u8) []const u8 {
    const file = data_dir.openFile(io, properties_file_name, .{}) catch return "";
    defer file.close(io);

    const len = file.readPositionalAll(io, buf, 0) catch |err| {
        log.warn("Failed to read server.properties: {}", .{err});
        return "";
    };
    if (len == buf.len) log.warn("server.properties may exceed the backup config buffer", .{});
    return buf[0..len];
}

// --- Save location resolution ---

fn file_exists(io: std.Io, dir: std.Io.Dir, path: []const u8) bool {
    const file = dir.openFile(io, path, .{}) catch return false;
    file.close(io);
    return true;
}

const OpenedDir = struct {
    dir: std.Io.Dir,
    owned: bool,
};

fn resolve_parent_dir(io: std.Io, data_dir: std.Io.Dir, sub_path: []const u8) ?OpenedDir {
    if (sub_path.len == 0) return .{ .dir = data_dir, .owned = false };
    const dir = data_dir.createDirPathOpen(io, sub_path, .{}) catch |err| {
        log.err("Failed to open save dir '{s}': {}", .{ sub_path, err });
        return null;
    };
    return .{ .dir = dir, .owned = true };
}

fn validate_save_file(io: std.Io, dir: std.Io.Dir, file_name: []const u8, scratch: std.mem.Allocator) bool {
    const file = dir.openFile(io, file_name, .{}) catch return false;
    defer file.close(io);

    const read_prefix_buf_len: usize = 32768;
    const read_buf = scratch.alloc(u8, read_prefix_buf_len) catch |err| {
        log.err("Failed to allocate save validation buffer: {}", .{err});
        return false;
    };
    defer scratch.free(read_buf);
    var reader = file.reader(io, read_buf);

    const peek_sizes = [_]usize{ read_prefix_buf_len, 8192, 4096, 1024, 256, 64, 12 };
    var prefix: []const u8 = &.{};
    inline for (peek_sizes) |sz| {
        if (reader.interface.peek(sz)) |s| {
            prefix = s;
            break;
        } else |_| {}
    }
    if (prefix.len < 2) return false;

    const sniff = game.World.SaveFormat.detect(prefix) orelse return false;
    if (std.meta.activeTag(sniff) == .classic_cw and
        !game.World.SaveFormat.verify_classic_cw(prefix, scratch))
    {
        log.warn("'{s}' is gzip but not ClassicWorld NBT; failing validation", .{file_name});
        return false;
    }

    const volume: usize = c.WorldLength * c.WorldHeight * c.WorldDepth;
    const raw = scratch.alloc(u8, volume + 4) catch |err| {
        log.err("Failed to allocate world scratch for save validation: {}", .{err});
        return false;
    };
    defer scratch.free(raw);
    const blocks: []Block = @ptrCast(raw[4..]);

    const outcome = sniff.load_world(scratch, raw, blocks, &reader.interface) catch |err| {
        log.warn("'{s}' failed to parse as {s}: {}", .{ file_name, @tagName(sniff), err });
        return false;
    };

    if (outcome.dimensions[0] != c.WorldLength or
        outcome.dimensions[1] != c.WorldHeight or
        outcome.dimensions[2] != c.WorldDepth)
    {
        log.warn("'{s}' has dimensions {}x{}x{}, expected {}x{}x{}", .{
            file_name,             outcome.dimensions[0], outcome.dimensions[1],
            outcome.dimensions[2], c.WorldLength,         c.WorldHeight,
            c.WorldDepth,
        });
        return false;
    }
    return true;
}

pub fn pre_init_validate_and_restore(io: std.Io, data_dir: std.Io.Dir, alloc: std.mem.Allocator) void {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const scratch = arena.allocator();

    var props_buf: [max_config_len]u8 = undefined;
    const props = read_properties(io, data_dir, &props_buf);

    var raw_buf: [max_name_len]u8 = undefined;
    const raw = scheme.parse_save_location(
        props,
        game.Server.default_save_location,
        game.Server.root_default_save_file_name,
        &raw_buf,
    );

    var parent_buf: [max_name_len]u8 = undefined;
    var file_buf: [max_name_len]u8 = undefined;
    const loc = scheme.split_save_location(raw, &parent_buf, &file_buf) orelse return;

    const save_dir = resolve_parent_dir(io, data_dir, loc.parent) orelse return;
    defer if (save_dir.owned) save_dir.dir.close(io);

    const exists = file_exists(io, save_dir.dir, loc.file_name);
    if (exists and validate_save_file(io, save_dir.dir, loc.file_name, scratch)) return;

    if (exists) {
        log.warn("Save '{s}' failed validation; attempting backup restore", .{loc.file_name});
    } else {
        log.info("Save '{s}' not found; checking backups", .{loc.file_name});
    }

    if (restore_newest_valid(io, save_dir.dir, loc.file_name, scratch)) {
        log.info("Backup restore complete; the restored save will be loaded", .{});
    } else if (exists) {
        log.err("No valid backup found; the world will be regenerated", .{});
    }
}

fn restore_newest_valid(io: std.Io, save_dir: std.Io.Dir, save_file_name: []const u8, scratch: std.mem.Allocator) bool {
    for (epochs) |epoch| {
        var bucket = open_bucket(io, save_dir, epoch.name) orelse continue;
        defer bucket.close(io);

        var entries: [scheme.BACKUP_SCAN_CAP]BackupEntry = undefined;
        const count = collect_backups(io, bucket, &entries);
        if (count == 0) continue;
        scheme.sort_entries_desc(entries[0..count]);

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

            copy_streaming(io, bucket, entry.name_slice(), save_dir, tmp_name) catch |err| {
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

    if (file_exists(io, save_dir, corrupt_name)) {
        save_dir.deleteFile(io, corrupt_name) catch {};
    }
    save_dir.rename(save_file_name, save_dir, corrupt_name, io) catch {
        // Old save stays in the way; the promote-rename below will simply
        // overwrite it.
    };
}

fn open_bucket(io: std.Io, save_dir: std.Io.Dir, epoch_name: []const u8) ?std.Io.Dir {
    var path_buf: [64]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ backup_root, epoch_name }) catch return null;
    return save_dir.openDir(io, path, .{ .iterate = true }) catch null;
}

const BackupEntry = scheme.BackupEntry;

fn collect_backups(io: std.Io, dir: std.Io.Dir, entries: []BackupEntry) usize {
    var iter = dir.iterate();
    var count: usize = 0;
    while (iter.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        const ts = scheme.parse_backup_timestamp(entry.name) orelse continue;
        if (entry.name.len > scheme.BACKUP_ENTRY_NAME_MAX) continue;
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
        const ts = scheme.parse_backup_timestamp(entry.name) orelse continue;
        if (newest == null or ts > newest.?) newest = ts;
    }
    return newest;
}

/// Stream-copy `src_name` from `src_dir` to `dst_name` in `dst_dir`.
fn copy_streaming(io: std.Io, src_dir: std.Io.Dir, src_name: []const u8, dst_dir: std.Io.Dir, dst_name: []const u8) !void {
    const src = try src_dir.openFile(io, src_name, .{});
    defer src.close(io);

    const dst = try dst_dir.createFile(io, dst_name, .{});
    var dst_closed = false;
    errdefer dst_dir.deleteFile(io, dst_name) catch {};
    defer if (!dst_closed) dst.close(io);

    var buf: [8192]u8 = undefined;
    var offset: u64 = 0;
    while (true) {
        const n = try src.readPositionalAll(io, &buf, offset);
        if (n == 0) break;
        try dst.writeStreamingAll(io, buf[0..n]);
        offset += n;
    }

    dst.close(io);
    dst_closed = true;
}

fn prune_bucket(io: std.Io, dir: std.Io.Dir, keep: usize) void {
    var entries: [scheme.BACKUP_SCAN_CAP]BackupEntry = undefined;
    const count = collect_backups(io, dir, &entries);
    if (count <= keep) return;

    const excess = count - keep;
    std.mem.sort(BackupEntry, entries[0..count], {}, BackupEntry.less_ts);
    for (entries[0..excess]) |entry| {
        dir.deleteFile(io, entry.name_slice()) catch |err| {
            log.warn("Failed to prune backup '{s}': {}", .{ entry.name_slice(), err });
        };
    }
}

const Backup = @This();

config: Config,
save_dir: std.Io.Dir,
save_file_name: [max_name_len]u8,
save_file_name_len: u16,
ext: [8]u8,
ext_len: u8,
last_save_ms: u64,

pub fn init(io: std.Io, data_dir: std.Io.Dir) Backup {
    var self: Backup = .{
        .config = Config.load(io, data_dir),
        .save_dir = game.World.saver.save_dir,
        .save_file_name = @splat(0),
        .save_file_name_len = 0,
        .ext = @splat(0),
        .ext_len = 0,
        .last_save_ms = current_unix_ms(io),
    };

    const save_file_name = game.World.saver.save_file_name;
    if (save_file_name.len == 0 or save_file_name.len > self.save_file_name.len) {
        log.err("Could not resolve save file name; periodic backups disabled", .{});
        return self;
    }
    @memcpy(self.save_file_name[0..save_file_name.len], save_file_name);
    self.save_file_name_len = @intCast(save_file_name.len);

    if (std.mem.lastIndexOfScalar(u8, save_file_name, '.')) |dot| {
        const ext = save_file_name[dot..];
        if (ext.len <= self.ext.len) {
            @memcpy(self.ext[0..ext.len], ext);
            self.ext_len = @intCast(ext.len);
        }
    }

    self.prepare_buckets(io);
    self.catch_up_snapshot(io);
    log.info("Backups active: autosave every {d}s into '{s}/', {d} epoch buckets", .{
        self.config.autosave_seconds, backup_root, epochs.len,
    });
    return self;
}

pub fn deinit(self: *Backup) void {
    self.* = undefined;
}

fn current_save_name(self: *const Backup) []const u8 {
    return self.save_file_name[0..self.save_file_name_len];
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

fn catch_up_snapshot(self: *Backup, io: std.Io) void {
    if (self.save_file_name_len == 0) return;
    if (!file_exists(io, self.save_dir, self.current_save_name())) return;
    if (game.World.saver.save_in_flight.load(.acquire)) return;
    self.snapshot_into(io, 0);
}

const poll_interval_ms: i64 = 2_000;

pub fn loop(self: *Backup, engine: *ae.Engine) std.Io.Cancelable!void {
    while (true) {
        try engine.io.sleep(.{ .nanoseconds = poll_interval_ms * std.time.ns_per_ms }, .real);
        self.tick_once(engine.io);
    }
}

fn tick_once(self: *Backup, io: std.Io) void {
    if (self.save_file_name_len == 0) return;

    const now_ms = current_unix_ms(io);
    if (now_ms < self.last_save_ms) self.last_save_ms = now_ms; // clock stepped back
    if (now_ms - self.last_save_ms < @as(u64, self.config.autosave_seconds) * std.time.ms_per_s) return;

    // Never fight an in-flight save (initial generation, world dump).
    if (game.World.saver.save_in_flight.load(.acquire)) return;

    game.World.save();
    game.World.wait_for_save();
    self.last_save_ms = now_ms;

    // Bucket 0 receives every completed save. Longer epochs promote on
    // their own wall-clock interval; checking them here means every
    // snapshot sources a file whose save has fully completed.
    self.snapshot_into(io, 0);
    for (1..epochs.len) |index| self.snapshot_epoch_if_due(io, index, now_ms);
}

fn snapshot_epoch_if_due(self: *Backup, io: std.Io, index: usize, now_ms: u64) void {
    const epoch = epochs[index];
    var bucket = open_bucket(io, self.save_dir, epoch.name) orelse return;
    defer bucket.close(io);

    if (newest_timestamp(io, bucket)) |ts| {
        if (now_ms - ts < @as(u64, epoch.interval_s) * std.time.ms_per_s) return;
    }
    self.snapshot_into(io, index);
}

fn snapshot_into(self: *Backup, io: std.Io, index: usize) void {
    const epoch = epochs[index];
    var bucket = open_bucket(io, self.save_dir, epoch.name) orelse {
        log.err("Failed to open backup bucket '{s}'", .{epoch.name});
        return;
    };
    defer bucket.close(io);

    var name_buf: [scheme.BACKUP_ENTRY_NAME_MAX]u8 = undefined;
    const name = scheme.format_backup_name(&name_buf, current_unix_ms(io), self.ext[0..self.ext_len]) catch {
        log.err("Backup name overflow", .{});
        return;
    };

    copy_streaming(io, self.save_dir, self.current_save_name(), bucket, name) catch |err| {
        log.err("Failed to snapshot '{s}' into '{s}': {}", .{ self.current_save_name(), epoch.name, err });
        return;
    };

    prune_bucket(io, bucket, epoch.keep);
    log.info("Snapshot '{s}' stored in bucket '{s}'", .{ name, epoch.name });
}

fn current_unix_ms(io: std.Io) u64 {
    const real_ns: i64 = @truncate(std.Io.Clock.Timestamp.now(io, .real).raw.nanoseconds);
    return @intCast(@max(real_ns, 0) / std.time.ns_per_ms);
}
