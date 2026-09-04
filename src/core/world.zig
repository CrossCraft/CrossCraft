// Process-wide world state.
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
// aggregate struct -- callers write `world.data.get_block(x,y,z)` or pass a
// block-change sink to `world.tick()` directly.

const std = @import("std");
const worldgen = @import("worldgen");
const wd = @import("world_dims.zig");
const blocks = @import("blocks.zig");

pub const WorldData = @import("world/WorldData.zig");
pub const WorldDims = wd.WorldDims;
pub const WorldSimulation = @import("world/WorldSimulation.zig");
pub const WorldSaver = @import("world/WorldSaver.zig");
pub const DumpName = @import("world/DumpName.zig");
pub const CreateName = @import("world/CreateName.zig");
const fmt_mod = @import("world/SaveFormat.zig");
pub const SaveFormat = fmt_mod.SaveFormat;
const BlockChangeSink = WorldSimulation.BlockChangeSink;

const Block = blocks.Block;
const log = std.log.scoped(.world);

pub const LoadStatus = union(enum) {
    loading,
    generating,
    downloading: u8,
    complete,
};

const load_status_loading: u16 = 0;
const load_status_complete: u16 = 1;
const load_status_generating_base: u16 = 16;
const load_status_downloading_base: u16 = 128;

// Default format for both init paths. Standalone overrides via
// server.properties; embedded singleplayer takes this value as-is.
pub const default_format: SaveFormat = .{ .classic_cw = .{} };

pub var data: WorldData = undefined;
pub var sim: WorldSimulation = undefined;
pub var saver: WorldSaver = undefined;
var load_status_atomic: std.atomic.Value(u16) = .init(load_status_loading);

pub fn lock_world() void {
    data.lock(saver.io);
}

pub fn unlock_world() void {
    data.unlock(saver.io);
}

pub fn lock_world_shared() void {
    data.lock_shared(saver.io);
}

pub fn unlock_world_shared() void {
    data.unlock_shared(saver.io);
}

pub fn get_load_status() LoadStatus {
    return decode_load_status(load_status_atomic.load(.acquire));
}

pub fn set_load_status(status: LoadStatus) void {
    load_status_atomic.store(encode_load_status(status), .release);
}

fn encode_load_status(status: LoadStatus) u16 {
    return switch (status) {
        .loading => load_status_loading,
        .complete => load_status_complete,
        .generating => load_status_generating_base,
        .downloading => |pct| load_status_downloading_base + @as(u16, pct),
    };
}

fn decode_load_status(encoded: u16) LoadStatus {
    if (encoded == load_status_complete) return .complete;
    if (encoded >= load_status_downloading_base) {
        return .{ .downloading = @intCast(@min(encoded - load_status_downloading_base, 100)) };
    }
    if (encoded >= load_status_generating_base) return .generating;
    return .loading;
}

/// Allocate scheduler + block storage without populating block data.
/// Used both by the full singleplayer init (which then generates or
/// loads and flips `saver.owned_locally` to true) and by the multiplayer
/// client (which fills `data.blocks` via the level-data-chunk
/// decompression path and leaves `owned_locally` false so save
/// paths are suppressed).
pub fn init_empty(
    allocator: std.mem.Allocator,
    io: std.Io,
    save_dir: std.Io.Dir,
    save_file_name: []const u8,
    geometry: WorldDims,
    seed: u64,
    format: SaveFormat,
) !void {
    try data.init_in_place(allocator, geometry, seed);
    errdefer data.deinit();
    sim = try WorldSimulation.init(allocator, seed);
    errdefer sim.deinit(allocator);
    saver = WorldSaver.init(io, save_dir, save_file_name, format);
    set_load_status(.loading);
}

/// Singleplayer init: allocate, try to load, fall back to worldgen,
/// finalize, save once on first generation.
pub fn init(
    allocator: std.mem.Allocator,
    scratch: std.mem.Allocator,
    io: std.Io,
    save_dir: std.Io.Dir,
    save_file_name: []const u8,
    geometry: WorldDims,
    seed: u64,
    format: SaveFormat,
) !void {
    // An existing save always boots at its own geometry: sniff the dims from
    // its header before allocating block storage. The configured geometry
    // (server.properties world-size/world-height, or the embedded default)
    // applies to first generation only -- the same contract as `seed`.
    const sniffed = SaveFormat.sniff_dims(io, save_dir, save_file_name, scratch);
    const load_geometry = sniffed orelse geometry;
    if (sniffed) |s| {
        if (s.length != geometry.length or s.height != geometry.height or s.depth != geometry.depth) {
            log.info("Save is {d}x{d}x{d}; configured {d}x{d}x{d} applies to new worlds only", .{
                s.length,        s.height,        s.depth,
                geometry.length, geometry.height, geometry.depth,
            });
        }
    }

    try init_empty(allocator, io, save_dir, save_file_name, load_geometry, seed, format);
    errdefer deinit_components();
    saver.owned_locally = true;

    try io.sleep(.fromMilliseconds(250), .real);

    if (!saver.try_load(&data, scratch)) {
        data.seed = seed;
        set_load_status(.generating);
        const start = std.Io.Clock.Timestamp.now(io, .boot);

        const visited_len = (data.dims.volume() / wd.chunk_size + 7) / 8;
        const lookaside = try scratch.alloc(u8, wd.chunk_volume);
        const visited = try scratch.alloc(u8, visited_len);
        @memset(visited, 0);

        data.release_blocks();
        const generated = try worldgen.generate(
            data.backing_allocator,
            scratch,
            @bitCast(data.seed),
            .{ .width = data.dims.length, .height = data.dims.height, .depth = data.dims.depth },
        );
        WorldData.remap_yzx_to_chunk_aware(data.dims, generated.blocks, lookaside[0..wd.chunk_volume], visited);
        data.adopt_blocks(generated.blocks);

        const end = std.Io.Clock.Timestamp.now(io, .boot);
        const elapsed_ms = elapsed_ms_between(start, end);
        log.info("World generation took {d}ms", .{elapsed_ms});
        data.stamp_creation_metadata(io);
        saver.save(&data);
    } else if (saver.needs_format_upgrade) {
        // Loaded an older on-disk format; rewrite it now under the
        // configured save format so subsequent boots take the fast path.
        // The job sits on the compress_worker LIFO until the host
        // (GameState / ServerState) spawns the worker thread shortly after
        // Server.init returns -- do not wait here.
        saver.save(&data);
    }
    finalize_loaded();
}

pub fn deinit() void {
    saver.wait_for_save();
    saver.save(&data);
    saver.wait_for_save();

    deinit_components();
}

pub fn deinit_after_init_error() void {
    saver.cancel_pending_before_compressor();

    deinit_components();
}

fn deinit_components() void {
    sim.deinit(data.backing_allocator);
    saver.deinit();
    data.deinit();
}

fn elapsed_ms_between(start: std.Io.Clock.Timestamp, end: std.Io.Clock.Timestamp) i64 {
    const elapsed_ns = end.raw.nanoseconds - start.raw.nanoseconds;
    const max_reasonable_ns: i96 = 30 * std.time.ns_per_s;
    if (elapsed_ns < 0 or elapsed_ns > max_reasonable_ns) return 0;
    const elapsed_ns_i64: i64 = @intCast(elapsed_ns);
    return @divTrunc(elapsed_ns_i64, std.time.ns_per_ms);
}

/// Compute the sunlight height map and per-chunk counts, then mark the
/// world fully loaded. Called by both the SP generate/load path and the
/// MP download path once `data.blocks` is populated.
pub fn finalize_loaded() void {
    data.compute_chunk_counts();
    data.compute_light_map();
    set_load_status(.complete);
    log.info("World seed: {d}", .{data.seed});
}

pub fn tick(sink: BlockChangeSink) u32 {
    return sim.tick(&data, sink);
}

pub fn set_block(x: u16, y: u16, z: u16, block: Block) void {
    sim.set_block(&data, x, y, z, block);
}

pub fn enqueue_neighbors_of(x: u16, y: u16, z: u16) void {
    sim.enqueue_neighbors_of(&data, x, y, z);
}

pub fn sponge_absorb(sink: BlockChangeSink, cx: u16, cy: u16, cz: u16) void {
    sim.sponge_absorb(&data, sink, cx, cy, cz);
}

pub fn sponge_release(cx: u16, cy: u16, cz: u16) void {
    sim.sponge_release(&data, cx, cy, cz);
}

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

pub fn get_block(x: u16, y: u16, z: u16) Block {
    return data.get_block(x, y, z);
}

pub fn is_sunlit(x: u16, y: u16, z: u16) bool {
    return data.is_sunlit(x, y, z);
}

pub fn find_spawn() [3]u16 {
    return data.find_spawn(saver.io);
}
