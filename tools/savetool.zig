/// Save conversion/editing tool.
///
/// Usage:
///   savetool <input.ccc> convert <output.cw>
///
/// `save.ccc` is a gzip stream containing Classic 256x64x256 block data in
/// XZY order. Some old tool outputs prepend a 32-bit version before the block
/// bytes; both layouts are accepted. Output is written through the game
/// module's ClassicWorld writer so generated `.cw` files stay format-compatible
/// with CrossCraft.
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
const LEGACY_MAX_BYTES: usize = WORLD_VOLUME + LEGACY_VERSION_BYTES;
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
    if (decoded_len != WORLD_VOLUME and decoded_len != LEGACY_MAX_BYTES) {
        return error.InvalidLegacyPayloadLength;
    }

    var extra: [1]u8 = undefined;
    if (try decompress.reader.readSliceShort(&extra) != 0) {
        return error.LegacyPayloadTooLong;
    }

    const block_bytes = if (decoded_len == LEGACY_MAX_BYTES) blk: {
        const version = std.mem.readInt(u32, legacy_bytes[0..LEGACY_VERSION_BYTES], .little);
        if (version != 1) return error.UnsupportedLegacyVersion;
        break :blk legacy_bytes[LEGACY_VERSION_BYTES..][0..WORLD_VOLUME];
    } else legacy_bytes[0..WORLD_VOLUME];

    scatter_legacy_blocks(block_bytes, data);
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
        .raw_blocks = data.raw_blocks,
        .blocks = data.blocks,
        .name = data.name[0..data.name_len],
        .uuid = data.uuid,
        .spawn = data.find_spawn(io),
        .time_created = data.time_created,
        .last_modified = now_ms,
    }, &writer.interface);
}
