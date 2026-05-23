// --- world.zig -- process-wide world state ---
//
// CrossCraft has exactly one world per process: the standalone server,
// the embedded singleplayer server, and the multiplayer client all
// share these slots. Singleplayer flows go through `init` (allocate ->
// load or generate -> finalize). The multiplayer client uses
// `init_empty` -> network fill -> `finalize_loaded` over the same
// vars.
//
// The substructs (data, sim, saver) are split into separate files for
// readability, but exposed at module scope rather than wrapped in an
// aggregate struct -- callers write `world.data.get_block(x,y,z)` or
// `world.tick()` directly.

const std = @import("std");
const common = @import("common");
const c = common.consts;

pub const WorldData = @import("world/WorldData.zig");
pub const WorldSimulation = @import("world/WorldSimulation.zig");
pub const WorldSaver = @import("world/WorldSaver.zig");
pub const DumpName = @import("world/DumpName.zig");
pub const CreateName = @import("world/CreateName.zig");
const fmt_mod = @import("world/SaveFormat.zig");
pub const SaveFormat = fmt_mod.SaveFormat;
pub const LoadOutcome = fmt_mod.LoadOutcome;
pub const ClassicDat = fmt_mod.ClassicDat;
pub const BlockChange = WorldSimulation.BlockChange;

const worldgen = @import("worldgen.zig");
const Block = c.Block;
const log = std.log.scoped(.world);

pub const LoadStatus = union(enum) {
    loading,
    generating: worldgen.GenPhase,
    downloading: u8,
    complete,
};

// Default format for both init paths. Standalone overrides via
// server.properties; embedded singleplayer takes this value as-is.
pub const default_format: SaveFormat = .{ .classic_cw = .{} };

pub var data: WorldData = undefined;
pub var sim: WorldSimulation = undefined;
pub var saver: WorldSaver = undefined;
pub var load_status: LoadStatus = .loading;

// --- Lifecycle ---

/// Allocate scheduler + block storage without populating block data.
/// Used both by the full singleplayer init (which then generates or
/// loads and flips `saver.owned_locally` to true) and by the multiplayer
/// client (which fills `data.blocks` via the level-data-chunk
/// decompression path and leaves `owned_locally` false so save/autosave
/// paths are suppressed).
pub fn init_empty(
    allocator: std.mem.Allocator,
    io: std.Io,
    save_dir: std.Io.Dir,
    save_file_name: []const u8,
    seed: u64,
    format: SaveFormat,
) !void {
    common.BlockRegistry.init();
    data = try WorldData.init(allocator, seed);
    errdefer data.deinit();
    sim = try WorldSimulation.init(allocator, seed);
    errdefer sim.deinit(allocator);
    saver = WorldSaver.init(io, save_dir, save_file_name, format);
    load_status = .loading;
}

/// Singleplayer init: allocate, try to load, fall back to worldgen,
/// finalize, save once on first generation.
pub fn init(
    allocator: std.mem.Allocator,
    scratch: std.mem.Allocator,
    io: std.Io,
    save_dir: std.Io.Dir,
    save_file_name: []const u8,
    seed: u64,
    format: SaveFormat,
) !void {
    try init_empty(allocator, io, save_dir, save_file_name, seed, format);
    saver.owned_locally = true;

    // Let loadscreen catch up
    try io.sleep(.fromMilliseconds(250), .real);

    if (!saver.try_load(&data)) {
        data.seed = seed;
        load_status = .{ .generating = .raising };
        const start = std.Io.Clock.Timestamp.now(io, .boot);
        try worldgen.generate(scratch, data.blocks, data.seed, io, &load_status.generating);
        const end = std.Io.Clock.Timestamp.now(io, .boot);
        const elapsed_ns: i64 = @truncate(end.raw.nanoseconds - start.raw.nanoseconds);
        const elapsed_ms = @divTrunc(elapsed_ns, std.time.ns_per_ms);
        log.info("World generation took {d}ms", .{elapsed_ms});
        data.stamp_creation_metadata(io);
        saver.save(&data);
    } else if (saver.needs_format_upgrade) {
        // Loaded an older on-disk format; rewrite it now under the
        // configured save format so subsequent boots take the fast path.
        // For classic_cw the job sits on the compress_worker LIFO until
        // the host (GameState / ServerState) spawns the worker thread
        // shortly after Server.init returns -- do not wait here.
        saver.save(&data);
    }
    finalize_loaded();
}

pub fn deinit() void {
    saver.wait_for_save();
    saver.save(&data);
    saver.wait_for_save();

    const allocator = data.backing_allocator;
    sim.deinit(allocator);
    saver.deinit();
    data.deinit();
}

/// Compute the sunlight height map and per-chunk counts, then mark the
/// world fully loaded. Called by both the SP generate/load path and the
/// MP download path once `data.blocks` is populated.
pub fn finalize_loaded() void {
    data.compute_chunk_counts();
    data.compute_light_map();
    load_status = .complete;
    log.info("World seed: {d}", .{data.seed});
}

// --- Tick + simulation ---

pub fn tick() void {
    sim.tick(&data);
    saver.maybe_autosave(&data);
}

pub fn set_block(x: u16, y: u16, z: u16, block: Block) void {
    sim.set_block(&data, x, y, z, block);
}

pub fn enqueue_neighbors_of(x: u16, y: u16, z: u16) void {
    sim.enqueue_neighbors_of(&data, x, y, z);
}

pub fn sponge_absorb(cx: u16, cy: u16, cz: u16) void {
    sim.sponge_absorb(&data, cx, cy, cz);
}

pub fn sponge_release(cx: u16, cy: u16, cz: u16) void {
    sim.sponge_release(&data, cx, cy, cz);
}

// --- Save ---

pub fn save() void {
    saver.save(&data);
}

pub fn dump_named(save_file_name: []const u8, world_name: []const u8) !void {
    try ensure_dump_dir();
    try saver.dump(&data, save_file_name, world_name, default_format);
}

pub fn wait_for_save() void {
    saver.wait_for_save();
}

fn ensure_dump_dir() !void {
    saver.save_dir.access(saver.io, "saves", .{}) catch {
        saver.save_dir.createDir(saver.io, "saves", .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    };
}

// --- Read-through helpers (shorthand for the most common drills) ---

pub fn get_block(x: u16, y: u16, z: u16) Block {
    return data.get_block(x, y, z);
}

pub fn is_sunlit(x: u16, y: u16, z: u16) bool {
    return data.is_sunlit(x, y, z);
}

pub fn find_spawn() [3]u16 {
    return data.find_spawn(saver.io);
}
