// Process-wide state shared by standalone, embedded, and multiplayer worlds.
// Local worlds use `init`; network clients populate `data` after `init_empty`.
// Both paths finish through `finalize_loaded`.

const std = @import("std");
const assert = std.debug.assert;
const worldgen = @import("worldgen");
const wd = @import("world_dims.zig");
const blocks = @import("blocks.zig");

pub const WorldData = @import("world/WorldData.zig");
pub const WorldDims = wd.WorldDims;
pub const WorldSimulation = @import("world/WorldSimulation.zig");
pub const WorldSaver = @import("world/WorldSaver.zig");
const SaveName = @import("world/SaveName.zig");
pub const DumpName = SaveName.Dump;
pub const CreateName = SaveName.Create;
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

pub const default_format: SaveFormat = .{ .classic_cw = .{} };

pub var data: WorldData = undefined;
var sim: ?WorldSimulation = null;
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
    const encoded = load_status_atomic.load(.acquire);
    if (encoded == load_status_complete) return .complete;
    if (encoded >= load_status_downloading_base) {
        return .{ .downloading = @intCast(@min(encoded - load_status_downloading_base, 100)) };
    }
    if (encoded >= load_status_generating_base) return .generating;
    return .loading;
}

pub fn set_load_status(status: LoadStatus) void {
    const encoded: u16 = switch (status) {
        .loading => load_status_loading,
        .complete => load_status_complete,
        .generating => load_status_generating_base,
        .downloading => |pct| load_status_downloading_base + @as(u16, pct),
    };
    load_status_atomic.store(encoded, .release);
}

/// Allocate empty world state. Multiplayer callers leave saving disabled.
pub fn init_empty(
    allocator: std.mem.Allocator,
    io: std.Io,
    save_dir: std.Io.Dir,
    save_file_name: []const u8,
    geometry: WorldDims,
    seed: u64,
    format: SaveFormat,
) !void {
    assert(sim == null);
    try data.init_in_place(allocator, geometry, seed);
    saver = WorldSaver.init(io, save_dir, save_file_name, format);
    set_load_status(.loading);
}

/// Load a local world or generate and save it when no valid save exists.
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
    // Saved geometry wins; configuration shapes only new worlds.
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
    sim = try WorldSimulation.init(allocator, seed);
    saver.owned_locally = true;

    try io.sleep(.fromMilliseconds(250), .real);

    if (!saver.try_load(&data, scratch)) {
        data.seed = seed;
        set_load_status(.generating);
        const start = std.Io.Clock.Timestamp.now(io, .boot);

        const visited_len = (data.dims.volume() / wd.chunk_size + 7) / 8;
        const visited = try scratch.alloc(u8, visited_len);
        @memset(visited, 0);

        data.release_blocks();
        const generated = try worldgen.generate(
            data.backing_allocator,
            scratch,
            @bitCast(data.seed),
            .{ .width = data.dims.length, .height = data.dims.height, .depth = data.dims.depth },
        );
        WorldData.remap_yzx_to_chunk_aware(data.dims, generated.blocks, visited);
        data.adopt_blocks(generated.blocks);

        const end = std.Io.Clock.Timestamp.now(io, .boot);
        const elapsed_ms = elapsed_ms_between(start, end);
        log.info("World generation took {d}ms", .{elapsed_ms});
        data.stamp_creation_metadata(io);
        saver.save(&data);
    } else if (saver.needs_format_upgrade) {
        // Queue the format rewrite. The host starts the compression worker
        // shortly after Server.init returns, so waiting here would deadlock.
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
    if (sim) |*simulation| simulation.deinit(data.backing_allocator);
    sim = null;
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

/// Rebuild derived data after either local loading or network download.
pub fn finalize_loaded() void {
    data.compute_chunk_counts();
    data.compute_light_map();
    set_load_status(.complete);
    log.info("World seed: {d}", .{data.seed});
}

pub fn tick(sink: BlockChangeSink) u32 {
    assert(saver.owned_locally);
    assert(get_load_status() == .complete);
    return sim.?.tick(&data, sink);
}

pub fn set_block(x: u16, y: u16, z: u16, block: Block) void {
    assert(saver.owned_locally);
    sim.?.set_block(&data, x, y, z, block);
}

pub fn enqueue_neighbors_of(x: u16, y: u16, z: u16) void {
    assert(saver.owned_locally);
    sim.?.enqueue_neighbors_of(&data, x, y, z);
}

pub fn sponge_absorb(sink: BlockChangeSink, cx: u16, cy: u16, cz: u16) void {
    sim.?.sponge_absorb(&data, sink, cx, cy, cz);
}

pub fn sponge_release(cx: u16, cy: u16, cz: u16) void {
    sim.?.sponge_release(&data, cx, cy, cz);
}

pub fn save() void {
    saver.save(&data);
}

pub fn dump_named(save_file_name: []const u8, world_name: []const u8) !void {
    saver.save_dir.createDir(saver.io, "saves", .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    try saver.dump(&data, save_file_name, world_name, default_format);
}

pub fn wait_for_save() void {
    saver.wait_for_save();
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

test "downloaded worlds need no simulation and clean up after local initialization fails" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const dims = WorldDims.init(128, 64, 128);
    var allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{});

    try init_empty(allocator.allocator(), std.testing.io, tmp.dir, "world.cw", dims, 0, default_format);
    const storage_allocations = allocator.allocations;
    {
        defer deinit();

        try std.testing.expect(sim == null);
        finalize_loaded();
        data.apply_block(1, 8, 1, .stone);
        try std.testing.expectEqual(Block.stone, get_block(1, 8, 1));
        try std.testing.expect(!is_sunlit(1, 7, 1));
    }
    try std.testing.expectEqual(allocator.allocated_bytes, allocator.freed_bytes);

    allocator = .init(std.testing.allocator, .{ .fail_index = storage_allocations });
    try std.testing.expectError(error.OutOfMemory, init(
        allocator.allocator(),
        std.testing.allocator,
        std.testing.io,
        tmp.dir,
        "world.cw",
        dims,
        0,
        default_format,
    ));
    try std.testing.expect(sim == null);
    try std.testing.expectEqual(allocator.allocated_bytes, allocator.freed_bytes);
}
