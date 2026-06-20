// --- WorldSaver ---
//
// Save lifecycle: I/O context (save_dir, file name), `owned_locally` gate,
// async dispatch with single-flight, autosave cadence. Delegates byte
// layout to a `SaveFormat` -- adding a new format only adds a union arm
// in SaveFormat.zig and a file under formats/.
//
// Concurrency note (still present): the worker reads `data.raw_blocks`
// while the engine thread may mutate `data.blocks` via tick(). A save
// that overlaps tick activity can produce a per-byte-torn save file.
// Tracked as a follow-up; the fix is to snapshot raw_blocks into a
// saver-owned scratch buffer at dispatch time.

const std = @import("std");
const builtin = @import("builtin");

const WorldData = @import("WorldData.zig");
const fmt_mod = @import("SaveFormat.zig");
const SaveFormat = fmt_mod.SaveFormat;
const SaveContext = fmt_mod.SaveContext;
const LoadOutcome = fmt_mod.LoadOutcome;
const compress_worker = @import("../compress_worker.zig");
const common = @import("common");
const c = common.consts;

const log = std.log.scoped(.world);

const BLOCK_SIZE = 32768;
const DUMP_FILE_NAME_MAX = 256;
const DUMP_WORLD_NAME_MAX = 64;

const WorldSaver = @This();

io: std.Io,
save_dir: std.Io.Dir,
save_file_name: []const u8,

format: SaveFormat,
format_for_worker: SaveFormat,

/// False for worlds streamed from a remote server (multiplayer client).
/// All save/autosave paths early-return when this is false so an MP client
/// can never persist a snapshot of somebody else's world as its own.
owned_locally: bool,

/// Periodic in-tick autosave. Left on for the dedicated server (crash
/// insurance across long uptimes) and off for singleplayer, which saves
/// explicitly on worldgen completion and on shutdown.
autosave_enabled: bool,

save_counter: u32,
save_in_flight: std.atomic.Value(bool),

/// Explicit user-triggered save target used for multiplayer world dumps.
/// Copied into saver storage before dispatch so the async worker does not
/// borrow UI-owned text buffers.
save_override_active: bool,
save_override_file_name: [DUMP_FILE_NAME_MAX]u8,
save_override_file_name_len: u16,
save_override_world_name: [DUMP_WORLD_NAME_MAX]u8,
save_override_world_name_len: u8,

/// Set by `try_load` when the on-disk format differs from `format`. The
/// caller (world.init) fires one save afterwards so the file on disk is
/// rewritten under the configured format.
needs_format_upgrade: bool,

// The async worker captures these via the saver pointer; pinned by the
// caller (the World aggregate field) for the worker's lifetime.
data_for_worker: *const WorldData,

// Saves run on the shared compressor worker instead of std.Io.concurrent:
// some platforms do not expose std.Io task spawning, and compression needs
// more stack than small per-task IO stacks provide. One slot per saver
// matches the single-flight `save_in_flight` guard.
cw_job: compress_worker.Job,

pub fn init(io: std.Io, save_dir: std.Io.Dir, save_file_name: []const u8, format: SaveFormat) WorldSaver {
    return .{
        .io = io,
        .save_dir = save_dir,
        .save_file_name = save_file_name,
        .format = format,
        .format_for_worker = format,
        .owned_locally = false,
        .autosave_enabled = true,
        .save_counter = 0,
        .save_in_flight = .init(false),
        .save_override_active = false,
        .save_override_file_name = undefined,
        .save_override_file_name_len = 0,
        .save_override_world_name = undefined,
        .save_override_world_name_len = 0,
        .needs_format_upgrade = false,
        .data_for_worker = undefined,
        .cw_job = .{ .done = .init(true), .run = cw_save_run },
    };
}

pub fn deinit(self: *WorldSaver) void {
    self.* = undefined;
}

/// Dispatch an async world save. Returns immediately; the worker runs on
/// the shared compressor thread.
/// Logs its own errors. Single-flight: a second call while a save is
/// still running logs a warn and is dropped. Callers needing the save
/// to finish (e.g. shutdown) must follow with `wait_for_save()`.
pub fn save(self: *WorldSaver, data: *const WorldData) void {
    if (!self.owned_locally) return;
    if (self.save_in_flight.load(.acquire)) {
        log.warn("save already in flight; skipping", .{});
        return;
    }
    self.save_override_active = false;
    self.dispatch_save(data, self.format) catch |err| {
        log.err("Failed to dispatch save worker: {}", .{err});
    };
}

/// Save an explicit snapshot even when the world is not locally owned.
/// Intended for user-requested multiplayer world dumps only.
pub fn dump(
    self: *WorldSaver,
    data: *const WorldData,
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
    if (self.save_in_flight.load(.acquire)) {
        return error.SaveInFlight;
    }

    @memcpy(self.save_override_file_name[0..save_file_name.len], save_file_name);
    self.save_override_file_name_len = @intCast(save_file_name.len);
    @memcpy(self.save_override_world_name[0..world_name.len], world_name);
    self.save_override_world_name_len = @intCast(world_name.len);
    self.save_override_active = true;

    self.dispatch_save(data, format) catch |err| {
        self.save_override_active = false;
        return err;
    };
}

fn dispatch_save(self: *WorldSaver, data: *const WorldData, format: SaveFormat) !void {
    if (self.save_in_flight.load(.acquire)) {
        log.warn("save already in flight; skipping", .{});
        return error.SaveInFlight;
    }
    self.save_in_flight.store(true, .release);
    self.data_for_worker = data;
    self.format_for_worker = format;
    if (comptime builtin.os.tag == .wasi) {
        save_worker(self);
        return;
    }
    self.cw_job = .{ .run = cw_save_run };
    compress_worker.submit(&self.cw_job);
}

/// Block until any in-flight save finishes. Idempotent. Must run before
/// `data.raw_blocks` is freed -- the worker reads it directly.
pub fn wait_for_save(self: *WorldSaver) void {
    // Keep the embedded job storage alive until the compressor worker has
    // returned from `run` and published `done`.
    while (!self.cw_job.done.load(.acquire)) {
        std.Io.sleep(self.io, common.time.ms(20), .real) catch break;
    }
}

/// Drop a queued save before the compressor thread exists. This is
/// only for init error unwind; normal shutdown must call `wait_for_save`.
pub fn cancel_pending_before_compressor(self: *WorldSaver) void {
    if (self.cw_job.done.load(.acquire)) return;

    if (compress_worker.cancel_pending_before_worker(&self.cw_job)) {
        self.save_override_active = false;
        self.save_in_flight.store(false, .release);
    }
}

fn cw_save_run(base: *compress_worker.Job) anyerror!void {
    const self: *WorldSaver = @fieldParentPtr("cw_job", base);
    save_worker(self);
}

fn save_worker(self: *WorldSaver) void {
    defer {
        log.info("save worker publish begin", .{});
        self.save_override_active = false;
        self.save_in_flight.store(false, .release);
        log.info("save worker publish end", .{});
    }

    const save_file_name = self.worker_save_file_name();

    // PSP-only: drop the existing directory entry before recreating it.
    // After a rename or autosave, sceIoOpen with O_CREAT|O_TRUNC over a
    // freshly-created entry can fail with the catch-all SCE error that
    // pspsdk surfaces as `error.AccessDenied`. Removing first sidesteps
    // that window. dirDeleteFile on pspsdk maps the missing-file case
    // to `error.AccessDenied` too, so swallow that variant.
    if (comptime builtin.os.tag == .psp) {
        self.save_dir.deleteFile(self.io, save_file_name) catch |err| switch (err) {
            error.AccessDenied => {},
            else => log.warn("pre-delete '{s}' failed: {}", .{ save_file_name, err }),
        };
    }

    const file = self.save_dir.createFile(self.io, save_file_name, .{}) catch |err| {
        log.err("Failed to create save file '{s}': {}", .{ save_file_name, err });
        return;
    };
    var file_closed = false;
    defer if (!file_closed) file.close(self.io);

    var write_buf: [BLOCK_SIZE]u8 = undefined;
    var writer = file.writer(self.io, &write_buf);

    const start = std.Io.Clock.Timestamp.now(self.io, .boot);
    const data = self.data_for_worker;
    const real_ns: i64 = @truncate(std.Io.Clock.Timestamp.now(self.io, .real).raw.nanoseconds);
    const last_modified_ms = @divTrunc(real_ns, std.time.ns_per_ms);
    const spawn = data.find_spawn(self.io);
    const ctx: SaveContext = .{
        .world_size = data.world_size,
        .seed = data.seed,
        .tick_count = data.tick_count,
        .raw_blocks = data.raw_blocks,
        .blocks = data.blocks,
        .name = self.worker_world_name(data),
        .uuid = data.uuid,
        .spawn = spawn,
        .time_created = data.time_created,
        .last_modified = last_modified_ms,
    };
    const format = self.format_for_worker;
    format.save_world(ctx, &writer.interface) catch |err| {
        log.err("Failed to write save file: {}", .{err});
        return;
    };
    const end = std.Io.Clock.Timestamp.now(self.io, .boot);

    // Read the actual on-disk size after the format's flush. The previous
    // calculation hardcoded the classic_dat raw byte layout, which was
    // wildly wrong for classic_cw (gzipped NBT compresses 4 MB down to
    // ~10-30 KB) and produced bogus throughput figures.
    const total_bytes: u64 = if (file.stat(self.io)) |st| st.size else |_| 0;
    const elapsed_ns: i64 = @truncate(end.raw.nanoseconds - start.raw.nanoseconds);
    const elapsed_us: i64 = @max(1, @divTrunc(elapsed_ns, std.time.ns_per_us));
    const kib_per_s: u64 = (total_bytes * std.time.us_per_s) /
        (@as(u64, @intCast(elapsed_us)) * 1024);
    log.info("Saved world to {s} ({d} bytes in {d}us, {d} KiB/s)", .{
        save_file_name, total_bytes, elapsed_us, kib_per_s,
    });
    log.info("save worker close begin", .{});
    file.close(self.io);
    file_closed = true;
    log.info("save worker close end", .{});
}

fn worker_save_file_name(self: *const WorldSaver) []const u8 {
    if (!self.save_override_active) return self.save_file_name;
    return self.save_override_file_name[0..self.save_override_file_name_len];
}

fn worker_world_name(self: *const WorldSaver, data: *const WorldData) []const u8 {
    if (!self.save_override_active) return data.name[0..data.name_len];
    return self.save_override_world_name[0..self.save_override_world_name_len];
}

/// Try to load the save file into `data`. Returns true on a successful
/// load (data populated, dimensions match); false if the file is missing
/// or invalid (caller falls back to worldgen).
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

    // Sniff the on-disk format from the header so a misnamed or migrated
    // file (e.g. classic_dat content sitting at saves/world.cw after the
    // legacy migration) loads correctly. The gzip arm of detect needs
    // enough deflate bytes for verify_classic_cw to inflate one byte;
    // dynamic-Huffman streams (heavier compression than CrossCraft's own
    // .fastest) can require ~1 KB of deflate before the first inflated
    // byte materialises, so prefer a peek up to read_buf capacity and
    // walk down only when the file is shorter than that. Each failed
    // peek leaves the reader untouched.
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

    const outcome = load_format.load_world(scratch, data.raw_blocks, data.blocks, &reader.interface) catch |err| {
        // Surface the failure so a misnamed/foreign-size save doesn't
        // silently fall through to worldgen with no explanation.
        log.err("Failed to load world from {s} as {s}: {}", .{
            self.save_file_name, @tagName(load_format), err,
        });
        return false;
    };

    if (outcome.dimensions[0] != c.WorldLength or
        outcome.dimensions[1] != c.WorldHeight or
        outcome.dimensions[2] != c.WorldDepth)
    {
        log.err("World dimensions mismatch: expected {}x{}x{}, got {}x{}x{}", .{
            c.WorldLength,         c.WorldHeight,         c.WorldDepth,
            outcome.dimensions[0], outcome.dimensions[1], outcome.dimensions[2],
        });
        return false;
    }

    data.world_size = outcome.dimensions;
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

/// Bump the autosave counter; once per AUTOSAVE_INTERVAL ticks fire a
/// save. Caller should pass the current tick count so the cadence is
/// driven by simulation, not real time.
pub const AUTOSAVE_INTERVAL: u32 = 6000;

pub fn maybe_autosave(self: *WorldSaver, data: *const WorldData) void {
    if (!self.autosave_enabled) return;
    self.save_counter += 1;
    if (self.save_counter >= AUTOSAVE_INTERVAL) {
        self.save_counter = 0;
        self.save(data);
    }
}
