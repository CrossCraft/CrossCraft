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

const WorldData = @import("WorldData.zig");
const SaveFormat = @import("SaveFormat.zig").SaveFormat;
const LoadOutcome = @import("SaveFormat.zig").LoadOutcome;
const common = @import("common");
const c = common.consts;

const log = std.log.scoped(.world);

const BLOCK_SIZE = 32768;

const WorldSaver = @This();

io: std.Io,
save_dir: std.Io.Dir,
save_file_name: []const u8,

format: SaveFormat,

/// False for worlds streamed from a remote server (multiplayer client).
/// All save/autosave paths early-return when this is false so an MP client
/// can never persist a snapshot of somebody else's world as its own.
owned_locally: bool,

/// Periodic in-tick autosave. Left on for the dedicated server (crash
/// insurance across long uptimes) and off for singleplayer, which saves
/// explicitly on worldgen completion and on shutdown.
autosave_enabled: bool,

save_counter: u32,
save_group: std.Io.Group,
save_in_flight: std.atomic.Value(bool),

// The async worker captures these via the saver pointer; pinned by the
// caller (the World aggregate field) for the worker's lifetime.
data_for_worker: *const WorldData,

pub fn init(io: std.Io, save_dir: std.Io.Dir, save_file_name: []const u8, format: SaveFormat) WorldSaver {
    return .{
        .io = io,
        .save_dir = save_dir,
        .save_file_name = save_file_name,
        .format = format,
        .owned_locally = false,
        .autosave_enabled = true,
        .save_counter = 0,
        .save_group = .init,
        .save_in_flight = .init(false),
        .data_for_worker = undefined,
    };
}

pub fn deinit(self: *WorldSaver) void {
    self.* = undefined;
}

/// Dispatch an async world save. Returns immediately; the worker runs on
/// an io-managed task and logs its own errors. Single-flight: a second
/// call while a save is still running logs a warn and is dropped.
/// Callers needing the save to finish (e.g. shutdown) must follow with
/// `wait_for_save()`.
pub fn save(self: *WorldSaver, data: *const WorldData) void {
    if (!self.owned_locally) return;
    if (self.save_in_flight.load(.acquire)) {
        log.warn("save already in flight; skipping", .{});
        return;
    }
    self.save_in_flight.store(true, .release);
    self.data_for_worker = data;
    self.save_group.concurrent(self.io, save_worker, .{self}) catch |err| {
        log.err("Failed to dispatch save worker: {}", .{err});
        self.save_in_flight.store(false, .release);
        return;
    };
}

/// Block until any in-flight save finishes. Idempotent. Must run before
/// `data.raw_blocks` is freed -- the worker reads it directly.
pub fn wait_for_save(self: *WorldSaver) void {
    self.save_group.await(self.io) catch {};
}

fn save_worker(self: *WorldSaver) void {
    defer self.save_in_flight.store(false, .release);

    const file = self.save_dir.createFile(self.io, self.save_file_name, .{}) catch |err| {
        log.err("Failed to create save file: {}", .{err});
        return;
    };
    defer file.close(self.io);

    var write_buf: [BLOCK_SIZE]u8 = undefined;
    var writer = file.writer(self.io, &write_buf);

    const start = std.Io.Clock.Timestamp.now(self.io, .boot);
    const data = self.data_for_worker;
    self.format.save_world(
        data.world_size,
        data.seed,
        data.tick_count,
        data.raw_blocks,
        data.blocks,
        &writer.interface,
    ) catch |err| {
        log.err("Failed to write save file: {}", .{err});
        return;
    };
    const end = std.Io.Clock.Timestamp.now(self.io, .boot);

    const total_bytes: u64 = 6 + 8 + 8 + 4 +
        @as(u64, c.WorldLength) * @as(u64, c.WorldDepth) * @as(u64, c.WorldHeight);
    const elapsed_ns: i64 = @truncate(end.raw.nanoseconds - start.raw.nanoseconds);
    const elapsed_us: i64 = @max(1, @divTrunc(elapsed_ns, std.time.ns_per_us));
    const mib_per_s: u64 = (total_bytes * std.time.us_per_s) /
        (@as(u64, @intCast(elapsed_us)) * 1024 * 1024);
    log.info("Saved world to {s} ({d} bytes in {d}us, {d} MiB/s)", .{
        self.save_file_name, total_bytes, elapsed_us, mib_per_s,
    });
}

/// Try to load the save file into `data`. Returns true on a successful
/// load (data populated, dimensions match); false if the file is missing
/// or invalid (caller falls back to worldgen).
pub fn try_load(self: *WorldSaver, data: *WorldData) bool {
    const file = self.save_dir.openFile(self.io, self.save_file_name, .{}) catch {
        return false;
    };
    defer file.close(self.io);

    var read_buf: [BLOCK_SIZE]u8 = undefined;
    var reader = file.reader(self.io, &read_buf);

    const outcome = self.format.load_world(data.raw_blocks, data.blocks, &reader.interface) catch return false;

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
    log.info("Loaded world from {s}", .{self.save_file_name});
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
