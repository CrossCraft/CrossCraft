// Saves copy live block storage in short read-locked bands. Mutations may occur
// between bands, so this is a race-free progressive capture, not one instant.

const std = @import("std");
const builtin = @import("builtin");

const WorldData = @import("WorldData.zig");
const fmt_mod = @import("SaveFormat.zig");
const SaveFormat = fmt_mod.SaveFormat;
const SaveContext = fmt_mod.SaveContext;
const compress_worker = @import("../compress_worker.zig");

const log = std.log.scoped(.world);

const BLOCK_SIZE = 32768;
const DUMP_FILE_NAME_MAX = 256;
const DUMP_WORLD_NAME_MAX = 64;
const TEMP_SUFFIX = ".saving.tmp";
const PREVIOUS_SUFFIX = ".previous.tmp";
const TEMP_NAME_MAX = DUMP_FILE_NAME_MAX + PREVIOUS_SUFFIX.len;

const WorldSaver = @This();

io: std.Io,
save_dir: std.Io.Dir,
save_file_name: []const u8,

format: SaveFormat,
format_for_worker: SaveFormat,

/// Prevents automatic saves of multiplayer worlds.
owned_locally: bool,
/// Pinned storage for an explicit multiplayer world dump.
save_override_active: bool,
save_override_file_name: [DUMP_FILE_NAME_MAX]u8,
save_override_file_name_len: u16,
save_override_world_name: [DUMP_WORLD_NAME_MAX]u8,
save_override_world_name_len: u8,

/// Requests a rewrite when the loaded and configured formats differ.
needs_format_upgrade: bool,

data_for_worker: *WorldData,

// The job state is also the single-flight gate.
cw_job: compress_worker.Job,

pub fn init(io: std.Io, save_dir: std.Io.Dir, save_file_name: []const u8, format: SaveFormat) WorldSaver {
    return .{
        .io = io,
        .save_dir = save_dir,
        .save_file_name = save_file_name,
        .format = format,
        .format_for_worker = format,
        .owned_locally = false,
        .save_override_active = false,
        .save_override_file_name = undefined,
        .save_override_file_name_len = 0,
        .save_override_world_name = undefined,
        .save_override_world_name_len = 0,
        .needs_format_upgrade = false,
        .data_for_worker = undefined,
        .cw_job = .{ .state = .init(.done), .run = cw_save_run },
    };
}

pub fn deinit(self: *WorldSaver) void {
    self.* = undefined;
}

/// Dispatch an asynchronous, single-flight save.
pub fn save(self: *WorldSaver, data: *WorldData) void {
    if (!self.owned_locally) return;
    self.dispatch_save(data, self.format, null) catch |err| switch (err) {
        error.SaveInFlight => log.warn("save already in flight; skipping", .{}),
    };
}

/// Save an explicit snapshot even when the world is not locally owned.
pub fn dump(
    self: *WorldSaver,
    data: *WorldData,
    save_file_name: []const u8,
    world_name: []const u8,
    format: SaveFormat,
) !void {
    if (save_file_name.len == 0 or save_file_name.len > self.save_override_file_name.len) {
        return error.InvalidSaveFileName;
    }
    if (world_name.len == 0 or world_name.len > self.save_override_world_name.len) {
        return error.InvalidWorldName;
    }
    try self.dispatch_save(data, format, .{
        .file_name = save_file_name,
        .world_name = world_name,
    });
}

const SaveOverride = struct {
    file_name: []const u8,
    world_name: []const u8,
};

fn dispatch_save(self: *WorldSaver, data: *WorldData, format: SaveFormat, override: ?SaveOverride) error{SaveInFlight}!void {
    if (!self.cw_job.try_begin()) return error.SaveInFlight;

    self.cw_job.next = null;
    self.cw_job.err = null;
    self.data_for_worker = data;
    self.format_for_worker = format;
    self.save_override_active = override != null;
    if (override) |value| {
        @memcpy(self.save_override_file_name[0..value.file_name.len], value.file_name);
        self.save_override_file_name_len = @intCast(value.file_name.len);
        @memcpy(self.save_override_world_name[0..value.world_name.len], value.world_name);
        self.save_override_world_name_len = @intCast(value.world_name.len);
    }

    if (comptime builtin.os.tag == .wasi) {
        defer self.cw_job.mark_done(self.io);

        save_worker(self);
        return;
    }
    compress_worker.submit(&self.cw_job);
}

pub fn save_in_progress(self: *const WorldSaver) bool {
    return !self.cw_job.is_done();
}

/// Wait unconditionally before freeing world storage read by the worker.
pub fn wait_for_save(self: *WorldSaver) void {
    self.cw_job.wait(self.io);
}

/// Cancel a queued save while unwinding initialization before the worker starts.
pub fn cancel_pending_before_compressor(self: *WorldSaver) void {
    if (self.cw_job.is_done()) return;
    _ = compress_worker.cancel_pending_before_worker(&self.cw_job);
}

fn cw_save_run(base: *compress_worker.Job) anyerror!void {
    const self: *WorldSaver = @fieldParentPtr("cw_job", base);
    save_worker(self);
}

fn save_worker(self: *WorldSaver) void {
    const save_file_name = self.worker_save_file_name();
    var temp_name_buf: [TEMP_NAME_MAX]u8 = undefined;
    const temp_name = sibling_name(save_file_name, TEMP_SUFFIX, &temp_name_buf) catch {
        log.err("Save file name is too long: '{s}'", .{save_file_name});
        return;
    };
    var previous_name_buf: [TEMP_NAME_MAX]u8 = undefined;
    const previous_name = sibling_name(save_file_name, PREVIOUS_SUFFIX, &previous_name_buf) catch {
        log.err("Save file name is too long: '{s}'", .{save_file_name});
        return;
    };

    const start = std.Io.Clock.Timestamp.now(self.io, .boot);
    const data = self.data_for_worker;
    const real_ns: i64 = @truncate(std.Io.Clock.Timestamp.now(self.io, .real).raw.nanoseconds);
    const last_modified_ms = @divTrunc(real_ns, std.time.ns_per_ms);
    var world_name_buf: [DUMP_WORLD_NAME_MAX]u8 = undefined;
    const ctx: SaveContext = blk: {
        data.lock_shared(self.io);
        defer data.unlock_shared(self.io);

        const world_name = self.worker_world_name(data);
        @memcpy(world_name_buf[0..world_name.len], world_name);
        break :blk .{
            .dims = data.dims,
            .seed = data.seed,
            .tick_count = data.tick_count,
            .world = data,
            .io = self.io,
            .name = world_name_buf[0..world_name.len],
            .uuid = data.uuid,
            .spawn = data.find_spawn(self.io),
            .time_created = data.time_created,
            .last_modified = last_modified_ms,
        };
    };
    const total_bytes = write_and_promote(
        self.io,
        self.save_dir,
        save_file_name,
        temp_name,
        previous_name,
        SaveBody{ .format = self.format_for_worker, .context = ctx },
    ) catch |err| {
        log.err("Failed to save world to '{s}': {}", .{ save_file_name, err });
        return;
    };
    const end = std.Io.Clock.Timestamp.now(self.io, .boot);

    const elapsed_ns: i64 = @truncate(end.raw.nanoseconds - start.raw.nanoseconds);
    const elapsed_us: i64 = @max(1, @divTrunc(elapsed_ns, std.time.ns_per_us));
    const kib_per_s: u64 = (total_bytes * std.time.us_per_s) /
        (@as(u64, @intCast(elapsed_us)) * 1024);
    log.info("Saved world to {s} ({d} bytes in {d}us, {d} KiB/s)", .{
        save_file_name, total_bytes, elapsed_us, kib_per_s,
    });
}

const SaveBody = struct {
    format: SaveFormat,
    context: SaveContext,

    fn write(self: SaveBody, writer: *std.Io.Writer) !void {
        try self.format.save_world(self.context, writer);
    }
};

fn sibling_name(target: []const u8, suffix: []const u8, out: []u8) ![]const u8 {
    return std.fmt.bufPrint(out, "{s}{s}", .{ target, suffix });
}

fn write_and_promote(
    io: std.Io,
    dir: std.Io.Dir,
    target: []const u8,
    temp_name: []const u8,
    previous_name: []const u8,
    body: anytype,
) !u64 {
    dir.deleteFile(io, temp_name) catch {};
    errdefer dir.deleteFile(io, temp_name) catch {};

    const total_bytes = blk: {
        const file = try dir.createFile(io, temp_name, .{});
        defer file.close(io);

        var write_buf: [BLOCK_SIZE]u8 = undefined;
        var writer = file.writer(io, &write_buf);
        try body.write(&writer.interface);
        try writer.interface.flush();
        break :blk (try file.stat(io)).size;
    };

    try promote_temp(io, dir, temp_name, target, previous_name);
    return total_bytes;
}

fn promote_temp(
    io: std.Io,
    dir: std.Io.Dir,
    temp_name: []const u8,
    target: []const u8,
    previous_name: []const u8,
) !void {
    if (comptime builtin.os.tag != .psp) {
        return dir.rename(temp_name, dir, target, io);
    }

    // PSP cannot replace an existing destination. Keep the old save available
    // for rollback while moving the completed temporary file into place.
    if (!file_exists(io, dir, target)) return dir.rename(temp_name, dir, target, io);
    dir.deleteFile(io, previous_name) catch {};
    try dir.rename(target, dir, previous_name, io);
    dir.rename(temp_name, dir, target, io) catch |err| {
        dir.rename(previous_name, dir, target, io) catch |restore_err| {
            log.err("Failed to restore previous save '{s}': {}", .{ previous_name, restore_err });
        };
        return err;
    };
    dir.deleteFile(io, previous_name) catch |err| {
        log.warn("Failed to remove previous save '{s}': {}", .{ previous_name, err });
    };
}

fn file_exists(io: std.Io, dir: std.Io.Dir, name: []const u8) bool {
    const file = dir.openFile(io, name, .{}) catch return false;
    file.close(io);
    return true;
}

fn worker_save_file_name(self: *const WorldSaver) []const u8 {
    if (!self.save_override_active) return self.save_file_name;
    return self.save_override_file_name[0..self.save_override_file_name_len];
}

fn worker_world_name(self: *const WorldSaver, data: *const WorldData) []const u8 {
    if (!self.save_override_active) return data.name[0..data.name_len];
    return self.save_override_world_name[0..self.save_override_world_name_len];
}

/// Load a valid save, returning false when the caller should generate a world.
pub fn try_load(self: *WorldSaver, data: *WorldData, scratch: std.mem.Allocator) bool {
    const file = self.save_dir.openFile(self.io, self.save_file_name, .{}) catch {
        return false;
    };
    defer file.close(self.io);

    const read_buf = scratch.alloc(u8, BLOCK_SIZE) catch |err| {
        log.err("Failed to allocate save read buffer: {}", .{err});
        return false;
    };
    defer scratch.free(read_buf);

    var reader = file.reader(self.io, read_buf);

    // A gzip stream may need roughly 1 KiB before yielding its first inflated
    // byte, so prefer the largest available prefix when detecting the format.
    const peek_sizes = [_]usize{ BLOCK_SIZE, 8192, 4096, 1024, 256, 64, 12 };
    var prefix: []const u8 = &.{};
    inline for (peek_sizes) |sz| {
        if (reader.interface.peek(sz)) |s| {
            prefix = s;
            break;
        } else |_| {}
    }
    const sniff = SaveFormat.detect(prefix) orelse self.format;
    const load_format: SaveFormat = blk: {
        if (std.meta.activeTag(sniff) == .classic_cw and !SaveFormat.verify_classic_cw(prefix, scratch)) {
            log.warn("save file is gzip but not ClassicWorld NBT; ignoring sniff", .{});
            break :blk self.format;
        }
        break :blk sniff;
    };

    const outcome = load_format.load_world(scratch, data.dims, data.blocks, &reader.interface) catch |err| {
        log.err("Failed to load world from {s} as {s}: {}", .{
            self.save_file_name, @tagName(load_format), err,
        });
        return false;
    };

    data.seed = outcome.seed;
    data.tick_count = outcome.tick_count;
    if (outcome.name_len > 0) {
        data.name = outcome.name;
        data.name_len = outcome.name_len;
    }
    data.uuid = outcome.uuid;
    data.time_created = outcome.time_created;
    log.info("Loaded world from {s}", .{self.save_file_name});

    if (std.meta.activeTag(load_format) != std.meta.activeTag(self.format)) {
        self.needs_format_upgrade = true;
        log.info("Save format upgrade scheduled: {s} -> {s}", .{
            @tagName(load_format), @tagName(self.format),
        });
    }
    return true;
}

test "save promotion preserves the previous file on write failure" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const Body = struct {
        bytes: []const u8,
        fail: bool = false,

        fn write(self: @This(), writer: *std.Io.Writer) !void {
            try writer.writeAll(self.bytes);
            if (self.fail) return error.ForcedFailure;
        }
    };

    {
        const file = try tmp.dir.createFile(io, "world.dat", .{});
        defer file.close(io);

        try file.writeStreamingAll(io, "old");
    }

    _ = try write_and_promote(
        io,
        tmp.dir,
        "world.dat",
        "world.dat.saving.tmp",
        "world.dat.previous.tmp",
        Body{ .bytes = "new" },
    );

    var read_buf: [16]u8 = undefined;
    {
        const file = try tmp.dir.openFile(io, "world.dat", .{});
        defer file.close(io);

        const len = try file.readPositionalAll(io, &read_buf, 0);
        try std.testing.expectEqualStrings("new", read_buf[0..len]);
    }

    try std.testing.expectError(error.ForcedFailure, write_and_promote(
        io,
        tmp.dir,
        "world.dat",
        "world.dat.saving.tmp",
        "world.dat.previous.tmp",
        Body{ .bytes = "partial", .fail = true },
    ));
    try std.testing.expect(!file_exists(io, tmp.dir, "world.dat.saving.tmp"));

    const file = try tmp.dir.openFile(io, "world.dat", .{});
    defer file.close(io);

    const len = try file.readPositionalAll(io, &read_buf, 0);
    try std.testing.expectEqualStrings("new", read_buf[0..len]);
}
