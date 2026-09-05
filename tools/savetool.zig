/// Convert legacy gzip `.ccc` saves to ClassicWorld.
///
/// Usage: `savetool <input.ccc> convert <output.cw>`
/// Headerless and version 1 payloads use XZY order. Version 2 adds a dimensions
/// header; version 3 keeps that header and stores blocks in YZX order.
const std = @import("std");
const assert = std.debug.assert;
const core = @import("core");

const World = core.World;
const WorldData = World.WorldData;
const SaveFormat = World.SaveFormat;
const CompressWorker = core.CompressWorker;

/// Legacy `.ccc` saves always use Classic's 256x64x256 geometry.
const legacy_dims = core.world_dims.default;
const WorldVolume = legacy_dims.volume();
const LegacyVersionBytes: usize = @sizeOf(u32);
const LegacyDimensionsBytes: usize = 3 * @sizeOf(u32);
const LegacyV1Bytes: usize = WorldVolume + LegacyVersionBytes;
const LegacyV2V3Bytes: usize = WorldVolume + LegacyVersionBytes + LegacyDimensionsBytes;
const LegacyMaxBytes: usize = LegacyV2V3Bytes;
const DefaultWorldName = "Converted World";

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 4) {
        usage();
        std.process.exit(1);
    }

    const input_path = args[1];
    if (!std.mem.eql(u8, args[2], "convert") and !std.mem.eql(u8, args[2], "ccc-to-cw")) {
        usage();
        std.process.exit(1);
    }
    const output_path = args[3];

    try CompressWorker.init(gpa, io);
    defer CompressWorker.deinit();

    var data: WorldData = undefined;
    try data.init_in_place(gpa, legacy_dims, 0);
    defer data.deinit();

    try load_legacy_ccc(io, gpa, input_path, &data);
    data.compute_chunk_counts();
    data.compute_light_map();
    data.stamp_creation_metadata(io);
    set_world_name(&data, output_path);

    try save_classic_world(io, output_path, &data);
}

fn usage() void {
    std.debug.print("usage: savetool <input.ccc> convert <output.cw>\n", .{});
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

    const legacy_bytes = try allocator.alloc(u8, LegacyMaxBytes);
    defer allocator.free(legacy_bytes);

    const decoded_len = try decompress.reader.readSliceShort(legacy_bytes);
    var extra: [1]u8 = undefined;
    if (try decompress.reader.readSliceShort(&extra) != 0) {
        return error.LegacyPayloadTooLong;
    }

    const block_bytes = switch (decoded_len) {
        WorldVolume => legacy_bytes[0..WorldVolume],
        LegacyV1Bytes => blk: {
            const version = std.mem.readInt(u32, legacy_bytes[0..LegacyVersionBytes], .little);
            if (version != 1) return error.UnsupportedLegacyVersion;
            break :blk legacy_bytes[LegacyVersionBytes..][0..WorldVolume];
        },
        LegacyV2V3Bytes => blk: {
            const version = std.mem.readInt(u32, legacy_bytes[0..LegacyVersionBytes], .little);
            if (version != 2 and version != 3) return error.UnsupportedLegacyVersion;
            try validate_legacy_dimensions(legacy_bytes[LegacyVersionBytes..][0..LegacyDimensionsBytes]);

            const blocks = legacy_bytes[LegacyVersionBytes + LegacyDimensionsBytes ..][0..WorldVolume];
            if (version == 3) {
                var reader = std.Io.Reader.fixed(blocks);
                try data.read_blocks_yzx(&reader);
                return;
            }
            break :blk blocks;
        },
        else => return error.InvalidLegacyPayloadLength,
    };

    scatter_legacy_blocks(block_bytes, data);
}

fn validate_legacy_dimensions(raw_dimensions: []const u8) !void {
    assert(raw_dimensions.len == LegacyDimensionsBytes);
    const length = std.mem.readInt(u32, raw_dimensions[0..4], .little);
    const height = std.mem.readInt(u32, raw_dimensions[4..8], .little);
    const depth = std.mem.readInt(u32, raw_dimensions[8..12], .little);
    if (length != legacy_dims.length or height != legacy_dims.height or depth != legacy_dims.depth) {
        return error.UnsupportedLegacyDimensions;
    }
}

fn scatter_legacy_blocks(legacy_blocks: []const u8, data: *WorldData) void {
    assert(legacy_blocks.len == WorldVolume);
    for (0..data.dims.length) |x| {
        for (0..data.dims.height) |y| {
            for (0..data.dims.depth) |z| {
                const source_idx = (x * data.dims.depth * data.dims.height) + (z * data.dims.height) + y;
                const dest_idx = data.dims.block_index(@intCast(x), @intCast(y), @intCast(z));
                data.blocks[dest_idx] = @enumFromInt(legacy_blocks[source_idx]);
            }
        }
    }
}

fn set_world_name(data: *WorldData, output_path: []const u8) void {
    @memset(&data.name, 0);

    const base = std.fs.path.basenameWindows(output_path);
    const stem = base[0 .. std.mem.lastIndexOfScalar(u8, base, '.') orelse base.len];
    const source_name = if (stem.len == 0) DefaultWorldName else stem;
    const name_len = @min(source_name.len, data.name.len);

    @memcpy(data.name[0..name_len], source_name[0..name_len]);
    data.name_len = @intCast(name_len);
}

fn save_classic_world(io: std.Io, output_path: []const u8, data: *WorldData) !void {
    const file = try std.Io.Dir.cwd().createFile(io, output_path, .{});
    defer file.close(io);

    var write_buf: [8192]u8 = undefined;
    var writer = file.writer(io, &write_buf);

    const now_ns: i64 = @truncate(std.Io.Clock.Timestamp.now(io, .real).raw.nanoseconds);
    const now_ms = @divTrunc(now_ns, std.time.ns_per_ms);
    const format: SaveFormat = .{ .classic_cw = .{} };

    try format.save_world(.{
        .dims = data.dims,
        .seed = data.seed,
        .tick_count = data.tick_count,
        .world = data,
        .io = io,
        .name = data.name[0..data.name_len],
        .uuid = data.uuid,
        .spawn = data.find_spawn(io),
        .time_created = data.time_created,
        .last_modified = now_ms,
    }, &writer.interface);
}
