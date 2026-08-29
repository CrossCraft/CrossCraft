/// Save conversion/editing tool.
///
/// Usage:
///   savetool <input.ccc> convert <output.cw>
///
/// `save.ccc` is a gzip stream containing Classic 256x64x256 block data.
/// Version 1 and version 2 saves use XZY order, while version 3 saves carry a
/// three-u32 dimensions header and use direct YZX world-data order. Headerless
/// XZY data is also accepted. Output is written through the game module's
/// ClassicWorld writer so generated `.cw` files stay format-compatible with
/// CrossCraft.
const std = @import("std");
const common = @import("common");
const game = @import("game");

const c = common.consts;
const World = game.World;
const WorldData = World.WorldData;
const SaveFormat = World.SaveFormat;
const CompressWorker = game.CompressWorker;

const WORLD_VOLUME: usize = c.WorldLength * c.WorldHeight * c.WorldDepth;
const LEGACY_VERSION_BYTES: usize = @sizeOf(u32);
const LEGACY_DIMENSIONS_BYTES: usize = 3 * @sizeOf(u32);
const LEGACY_V1_BYTES: usize = WORLD_VOLUME + LEGACY_VERSION_BYTES;
const LEGACY_V2_V3_BYTES: usize = WORLD_VOLUME + LEGACY_VERSION_BYTES + LEGACY_DIMENSIONS_BYTES;
const LEGACY_MAX_BYTES: usize = LEGACY_V2_V3_BYTES;
const DEFAULT_WORLD_NAME = "Converted World";

const Command = enum {
    convert,

    fn parse(raw: []const u8) ?Command {
        if (std.mem.eql(u8, raw, "convert")) return .convert;
        if (std.mem.eql(u8, raw, "ccc-to-cw")) return .convert;
        return null;
    }
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 4) {
        usage();
        std.process.exit(1);
    }

    const input_path = args[1];
    const command = Command.parse(args[2]) orelse {
        usage();
        std.process.exit(1);
    };
    const output_path = args[3];

    common.BlockRegistry.init();
    try CompressWorker.init(gpa, io);
    defer CompressWorker.deinit();

    var data: WorldData = undefined;
    try data.init_in_place(gpa, 0);
    defer data.deinit();

    try load_legacy_ccc(io, gpa, input_path, &data);
    data.compute_chunk_counts();
    data.compute_light_map();
    data.stamp_creation_metadata(io);
    set_world_name(&data, output_path);

    switch (command) {
        .convert => try save_classic_world(io, output_path, &data),
    }
}

fn usage() void {
    std.debug.print(
        \\usage: savetool <input.ccc> <command> <output.cw>
        \\
        \\commands:
        \\  convert    convert legacy save.ccc block data to ClassicWorld .cw
        \\
    , .{});
}

fn load_legacy_ccc(
    io: std.Io,
    allocator: std.mem.Allocator,
    input_path: []const u8,
    data: *WorldData,
) !void {
    const file = try std.Io.Dir.cwd().openFile(io, input_path, .{});
    defer file.close(io);

    var file_buf: [8192]u8 = undefined;
    var file_reader = file.reader(io, &file_buf);

    const window_buf = try allocator.alloc(u8, std.compress.flate.max_window_len);
    defer allocator.free(window_buf);
    var decompress = std.compress.flate.Decompress.init(&file_reader.interface, .gzip, window_buf);

    const legacy_bytes = try allocator.alloc(u8, LEGACY_MAX_BYTES);
    defer allocator.free(legacy_bytes);

    const decoded_len = try decompress.reader.readSliceShort(legacy_bytes);
    var extra: [1]u8 = undefined;
    if (try decompress.reader.readSliceShort(&extra) != 0) {
        return error.LegacyPayloadTooLong;
    }

    const block_bytes = switch (decoded_len) {
        WORLD_VOLUME => legacy_bytes[0..WORLD_VOLUME],
        LEGACY_V1_BYTES => blk: {
            const version = std.mem.readInt(u32, legacy_bytes[0..LEGACY_VERSION_BYTES], .little);
            if (version != 1) return error.UnsupportedLegacyVersion;
            break :blk legacy_bytes[LEGACY_VERSION_BYTES..][0..WORLD_VOLUME];
        },
        LEGACY_V2_V3_BYTES => blk: {
            const version = std.mem.readInt(u32, legacy_bytes[0..LEGACY_VERSION_BYTES], .little);
            if (version != 2 and version != 3) return error.UnsupportedLegacyVersion;
            try validate_legacy_dimensions(legacy_bytes[LEGACY_VERSION_BYTES..][0..LEGACY_DIMENSIONS_BYTES]);

            const blocks = legacy_bytes[LEGACY_VERSION_BYTES + LEGACY_DIMENSIONS_BYTES ..][0..WORLD_VOLUME];
            if (version == 3) {
                scatter_yzx_blocks(blocks, data);
                return;
            }
            break :blk blocks;
        },
        else => return error.InvalidLegacyPayloadLength,
    };

    scatter_legacy_blocks(block_bytes, data);
}

fn validate_legacy_dimensions(raw_dimensions: []const u8) !void {
    std.debug.assert(raw_dimensions.len == LEGACY_DIMENSIONS_BYTES);
    const length = std.mem.readInt(u32, raw_dimensions[0..4], .little);
    const height = std.mem.readInt(u32, raw_dimensions[4..8], .little);
    const depth = std.mem.readInt(u32, raw_dimensions[8..12], .little);
    if (length != c.WorldLength or height != c.WorldHeight or depth != c.WorldDepth) {
        return error.UnsupportedLegacyDimensions;
    }
}

fn scatter_legacy_blocks(legacy_blocks: []const u8, data: *WorldData) void {
    std.debug.assert(legacy_blocks.len == WORLD_VOLUME);
    for (0..c.WorldLength) |x| {
        for (0..c.WorldHeight) |y| {
            for (0..c.WorldDepth) |z| {
                const source_idx = (x * c.WorldDepth * c.WorldHeight) + (z * c.WorldHeight) + y;
                const dest_idx = c.block_index(@intCast(x), @intCast(y), @intCast(z));
                data.blocks[dest_idx] = .{ .id = @enumFromInt(legacy_blocks[source_idx]) };
            }
        }
    }
}

/// Version 3 wrote `World::worldData` directly, whose contiguous layout was
/// YZX: x varies fastest, then z, then y.
fn scatter_yzx_blocks(legacy_blocks: []const u8, data: *WorldData) void {
    std.debug.assert(legacy_blocks.len == WORLD_VOLUME);
    var source_idx: usize = 0;
    for (0..c.WorldHeight) |y| {
        for (0..c.WorldDepth) |z| {
            for (0..c.WorldLength) |x| {
                const dest_idx = c.block_index(@intCast(x), @intCast(y), @intCast(z));
                data.blocks[dest_idx] = .{ .id = @enumFromInt(legacy_blocks[source_idx]) };
                source_idx += 1;
            }
        }
    }
}

fn set_world_name(data: *WorldData, output_path: []const u8) void {
    @memset(&data.name, 0);

    const base = path_basename(output_path);
    const stem = strip_extension(base);
    const source_name = if (stem.len == 0) DEFAULT_WORLD_NAME else stem;
    const name_len = @min(source_name.len, data.name.len);

    @memcpy(data.name[0..name_len], source_name[0..name_len]);
    data.name_len = @intCast(name_len);
}

fn path_basename(path: []const u8) []const u8 {
    var start: usize = 0;
    for (path, 0..) |ch, i| {
        if (ch == '/' or ch == '\\') start = i + 1;
    }
    return path[start..];
}

fn strip_extension(name: []const u8) []const u8 {
    var i = name.len;
    while (i > 0) {
        i -= 1;
        if (name[i] == '.') return name[0..i];
    }
    return name;
}

fn save_classic_world(io: std.Io, output_path: []const u8, data: *const WorldData) !void {
    const file = try std.Io.Dir.cwd().createFile(io, output_path, .{});
    defer file.close(io);

    var write_buf: [8192]u8 = undefined;
    var writer = file.writer(io, &write_buf);

    const now_ns: i64 = @truncate(std.Io.Clock.Timestamp.now(io, .real).raw.nanoseconds);
    const now_ms = @divTrunc(now_ns, std.time.ns_per_ms);
    const format: SaveFormat = .{ .classic_cw = .{} };

    try format.save_world(.{
        .world_size = data.world_size,
        .seed = data.seed,
        .tick_count = data.tick_count,
        .blocks = data.blocks,
        .name = data.name[0..data.name_len],
        .uuid = data.uuid,
        .spawn = data.find_spawn(io),
        .time_created = data.time_created,
        .last_modified = now_ms,
    }, &writer.interface);
}
