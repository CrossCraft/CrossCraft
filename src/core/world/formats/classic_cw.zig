// ClassicWorld NBT + gzip. BlockArray streams from chunk-aware storage in
// bounded bands instead of materialising a second full-world buffer.

const std = @import("std");
const b = @import("../../blocks.zig");
const wd = @import("../../world_dims.zig");

const Block = b.Block;
const WorldDims = wd.WorldDims;

const fmt_mod = @import("../SaveFormat.zig");
const SaveContext = fmt_mod.SaveContext;
const LoadOutcome = fmt_mod.LoadOutcome;
const WorldData = @import("../WorldData.zig");
const compress_worker = @import("../../compress_worker.zig");
const nbt = @import("../../nbt/nbt.zig");

const log = std.log.scoped(.world);

const FormatVersion: i8 = 1;
const CreatedByService = "CrossCraft";
const CreatedByUsername = "Server";
const MapGeneratorSoftware = "CrossCraft";
const MapGeneratorName = "Classic";

pub const ClassicCw = struct {
    pub fn save_world(
        _: ClassicCw,
        ctx: SaveContext,
        writer: *std.Io.Writer,
    ) !void {
        try compress_worker.reset(writer);
        const out = &compress_worker.compressor.writer;

        try write_classic_world_compound(ctx, out);

        try compress_worker.compressor.finish();
        try writer.flush();
    }

    pub fn load_world(
        _: ClassicCw,
        scratch: std.mem.Allocator,
        dims: WorldDims,
        blocks: []Block,
        reader: *std.Io.Reader,
    ) !LoadOutcome {
        const window_buf = try scratch.alloc(u8, std.compress.flate.max_window_len);
        defer scratch.free(window_buf);

        var decompress = std.compress.flate.Decompress.init(reader, .gzip, window_buf);
        return try read_classic_world_compound(&decompress.reader, dims, blocks);
    }

    /// Read supported dimensions before BlockArray without inflating the world.
    pub fn sniff_dims(_: ClassicCw, prefix: []const u8, scratch: std.mem.Allocator) ?WorldDims {
        const window_buf = scratch.alloc(u8, std.compress.flate.max_window_len) catch return null;
        defer scratch.free(window_buf);

        var src = std.Io.Reader.fixed(prefix);
        var decompress = std.compress.flate.Decompress.init(&src, .gzip, window_buf);
        return peek_classic_world_dims(&decompress.reader);
    }
};

fn write_classic_world_compound(ctx: SaveContext, out: *std.Io.Writer) !void {
    try nbt.write_header(out, .compound, "ClassicWorld");

    const spawn_children = [_]nbt.Nbt{
        named("X", .{ .short = @intCast(@as(i32, ctx.spawn[0]) >> 5) }),
        named("Y", .{ .short = @intCast(@as(i32, ctx.spawn[1]) >> 5) }),
        named("Z", .{ .short = @intCast(@as(i32, ctx.spawn[2]) >> 5) }),
        named("H", .{ .byte = 0 }),
        named("P", .{ .byte = 0 }),
    };
    const created_by_children = [_]nbt.Nbt{
        named("Service", .{ .string = CreatedByService }),
        named("Username", .{ .string = CreatedByUsername }),
    };
    const map_gen_children = [_]nbt.Nbt{
        named("Software", .{ .string = MapGeneratorSoftware }),
        named("MapGeneratorName", .{ .string = MapGeneratorName }),
    };

    const meta_children = [_]nbt.Nbt{
        named("FormatVersion", .{ .byte = FormatVersion }),
        named("Name", .{ .string = ctx.name }),
        named("UUID", .{ .byte_array = &ctx.uuid }),
        named("X", .{ .short = @intCast(ctx.dims.length) }),
        named("Y", .{ .short = @intCast(ctx.dims.height) }),
        named("Z", .{ .short = @intCast(ctx.dims.depth) }),
        named("CreatedBy", .{ .compound = &created_by_children }),
        named("MapGenerator", .{ .compound = &map_gen_children }),
        named("TimeCreated", .{ .long = ctx.time_created }),
        named("LastAccessed", .{ .long = ctx.last_modified }),
        named("LastModified", .{ .long = ctx.last_modified }),
        named("Spawn", .{ .compound = &spawn_children }),
    };

    for (meta_children) |child| try child.write(out);

    try nbt.write_header(out, .byte_array, "BlockArray");
    try out.writeInt(i32, @intCast(ctx.dims.volume()), .big);
    try ctx.world.write_blocks_yzx(ctx.io, out);

    try named("Metadata", .{ .compound = &.{} }).write(out);
    try out.writeByte(@intFromEnum(nbt.Tag.end));
}

fn named(name: []const u8, value: nbt.Nbt.Value) nbt.Nbt {
    return .{ .name = name, .value = value };
}

fn read_classic_world_compound(
    reader: *std.Io.Reader,
    dims: WorldDims,
    blocks: []Block,
) !LoadOutcome {
    if (try nbt.read_tag(reader) != .compound) return error.InvalidTag;
    var name_buf: [64]u8 = undefined;
    const name = try take_string(reader, &name_buf);
    if (!std.mem.eql(u8, name, "ClassicWorld")) return error.UnexpectedName;

    var outcome: LoadOutcome = .{
        .dimensions = .{ 0, 0, 0 },
        .seed = 0,
        .tick_count = 0,
    };
    const expected_dimensions = dims.to_array();
    var seen_dimensions: u3 = 0;
    var seen_block_array = false;

    while (true) {
        const t = try nbt.read_tag(reader);
        if (t == .end) break;
        const child_name = try take_string(reader, &name_buf);

        if (std.mem.eql(u8, child_name, "BlockArray")) {
            if (t != .byte_array) return error.InvalidTag;
            if (seen_block_array) return error.DuplicateBlockArray;
            if (seen_dimensions != 0b111) return error.MissingDimensions;
            const len = try reader.takeInt(i32, .big);
            const expected: u32 = @intCast(dims.volume());
            if (len < 0 or @as(u32, @intCast(len)) != expected) return error.UnexpectedByteArrayLength;
            try WorldData.read_blocks_yzx_into(dims, blocks, reader);
            seen_block_array = true;
        } else if (dimension_index(child_name)) |index| {
            if (t != .short) return error.InvalidTag;
            const bit = @as(u3, 1) << index;
            if (seen_dimensions & bit != 0) return error.DuplicateDimension;

            const raw = try reader.takeInt(i16, .big);
            if (raw <= 0) return error.InvalidDimensions;
            const value: u16 = @intCast(raw);
            if (!dimension_supported(index, value)) return error.InvalidDimensions;
            if (value != expected_dimensions[index]) return error.DimensionMismatch;

            outcome.dimensions[index] = value;
            seen_dimensions |= bit;
        } else if (std.mem.eql(u8, child_name, "Name") and t == .string) {
            const slen = try reader.takeInt(u16, .big);
            const take = @min(slen, outcome.name.len);
            try reader.readSliceAll(outcome.name[0..take]);
            outcome.name_len = @intCast(take);
            if (slen > take) try reader.discardAll64(slen - take);
        } else if (std.mem.eql(u8, child_name, "UUID") and t == .byte_array) {
            const ulen = try reader.takeInt(i32, .big);
            if (ulen == outcome.uuid.len) {
                try reader.readSliceAll(&outcome.uuid);
            } else if (ulen > 0) {
                try reader.discardAll64(@intCast(ulen));
            }
        } else if (std.mem.eql(u8, child_name, "TimeCreated") and t == .long) {
            outcome.time_created = try reader.takeInt(i64, .big);
        } else {
            try skip_payload(reader, t);
        }
    }

    if (seen_dimensions != 0b111) return error.MissingDimensions;
    if (!seen_block_array) return error.MissingBlockArray;
    return outcome;
}

fn dimension_index(name: []const u8) ?u2 {
    if (name.len != 1) return null;
    return switch (name[0]) {
        'X' => 0,
        'Y' => 1,
        'Z' => 2,
        else => null,
    };
}

fn dimension_supported(index: u2, value: u16) bool {
    const limits: struct { min: u32, max: u32 } = switch (index) {
        0 => .{ .min = wd.min_length, .max = wd.max_length },
        1 => .{ .min = wd.min_height, .max = wd.max_height },
        2 => .{ .min = wd.min_depth, .max = wd.max_depth },
        else => unreachable,
    };
    return limits.min <= value and value <= limits.max and std.math.isPowerOfTwo(value);
}

fn take_string(reader: *std.Io.Reader, buf: []u8) ![]u8 {
    const len = try reader.takeInt(u16, .big);
    if (len > buf.len) return error.NameTooLong;
    try reader.readSliceAll(buf[0..len]);
    return buf[0..len];
}

/// Stop at BlockArray to avoid reading the block payload.
fn peek_classic_world_dims(reader: *std.Io.Reader) ?WorldDims {
    if ((nbt.read_tag(reader) catch return null) != .compound) return null;
    var name_buf: [64]u8 = undefined;
    const name = take_string(reader, &name_buf) catch return null;
    if (!std.mem.eql(u8, name, "ClassicWorld")) return null;

    var dims: [3]u16 = undefined;
    var seen: u3 = 0;
    while (seen != 0b111) {
        const t = nbt.read_tag(reader) catch return null;
        if (t == .end) return null;
        const child_name = take_string(reader, &name_buf) catch return null;

        if (std.mem.eql(u8, child_name, "BlockArray")) return null;
        if (dimension_index(child_name)) |index| {
            const bit = @as(u3, 1) << index;
            if (t == .short and seen & bit == 0) {
                dims[index] = reader.takeInt(u16, .big) catch return null;
                seen |= bit;
                continue;
            }
        }
        skip_payload(reader, t) catch return null;
    }
    return WorldDims.from_array(dims);
}

const SkipError = std.Io.Reader.Error || error{InvalidTag};

fn skip_payload(reader: *std.Io.Reader, tag: nbt.Tag) SkipError!void {
    switch (tag) {
        .end => {},
        .byte => try reader.discardAll64(1),
        .short => try reader.discardAll64(2),
        .int, .float => try reader.discardAll64(4),
        .long, .double => try reader.discardAll64(8),
        .byte_array => {
            const len = try reader.takeInt(i32, .big);
            if (len > 0) try reader.discardAll64(@intCast(len));
        },
        .string => {
            const len = try reader.takeInt(u16, .big);
            try reader.discardAll64(len);
        },
        .list => {
            const elem_tag = try nbt.read_tag(reader);
            const len = try reader.takeInt(i32, .big);
            var i: i32 = 0;
            while (i < len) : (i += 1) try skip_payload(reader, elem_tag);
        },
        .compound => while (true) {
            const child_tag = try nbt.read_tag(reader);
            if (child_tag == .end) break;
            try reader.discardAll64(try reader.takeInt(u16, .big));
            try skip_payload(reader, child_tag);
        },
    }
}

test "loader accepts shuffled dimensions before BlockArray" {
    const dims = WorldDims.init(128, 64, 128);
    const encoded = try std.testing.allocator.alloc(u8, dims.volume() + 128);
    defer std.testing.allocator.free(encoded);

    const blocks = try std.testing.allocator.alloc(Block, dims.volume());
    defer std.testing.allocator.free(blocks);

    @memset(blocks, .stone);

    var w = std.Io.Writer.fixed(encoded);
    try nbt.write_header(&w, .compound, "ClassicWorld");
    try named("Z", .{ .short = 128 }).write(&w);
    try named("X", .{ .short = 128 }).write(&w);
    try named("Y", .{ .short = 64 }).write(&w);
    try nbt.write_header(&w, .byte_array, "BlockArray");
    try w.writeInt(i32, @intCast(dims.volume()), .big);
    try w.splatByteAll(0, dims.volume());
    try w.writeByte(@intFromEnum(nbt.Tag.end));

    var r = std.Io.Reader.fixed(w.buffered());
    const outcome = try read_classic_world_compound(&r, dims, blocks);
    try std.testing.expectEqual(dims.to_array(), outcome.dimensions);
    try std.testing.expectEqual(Block.air, blocks[0]);
    try std.testing.expectEqual(Block.air, blocks[blocks.len - 1]);

    const duplicate_start = w.buffered().len - 1;
    var duplicate = std.Io.Writer.fixed(encoded[duplicate_start..]);
    try nbt.write_header(&duplicate, .byte_array, "BlockArray");
    var duplicate_reader = std.Io.Reader.fixed(encoded[0 .. duplicate_start + duplicate.buffered().len]);
    try std.testing.expectError(error.DuplicateBlockArray, read_classic_world_compound(&duplicate_reader, dims, blocks));
}

test "loader rejects malformed dimensions before writing blocks" {
    const Fixture = struct {
        fn run(expected_error: anyerror, children: []const nbt.Nbt, block_array_after: bool) !void {
            var buf: [256]u8 = undefined;
            var w = std.Io.Writer.fixed(&buf);
            try nbt.write_header(&w, .compound, "ClassicWorld");
            for (children) |child| try child.write(&w);
            if (block_array_after) {
                try nbt.write_header(&w, .byte_array, "BlockArray");
            } else {
                try w.writeByte(@intFromEnum(nbt.Tag.end));
            }

            var blocks = [1]Block{.stone};
            var r = std.Io.Reader.fixed(w.buffered());
            try std.testing.expectError(expected_error, read_classic_world_compound(&r, wd.default, &blocks));
            try std.testing.expectEqual(Block.stone, blocks[0]);
        }
    };

    try Fixture.run(error.InvalidDimensions, &.{named("X", .{ .short = -1 })}, false);
    try Fixture.run(error.InvalidDimensions, &.{named("X", .{ .short = 192 })}, false);
    try Fixture.run(error.DimensionMismatch, &.{named("X", .{ .short = 128 })}, false);
    try Fixture.run(error.DuplicateDimension, &.{ named("X", .{ .short = 256 }), named("X", .{ .short = 256 }) }, false);
    try Fixture.run(error.MissingDimensions, &.{ named("X", .{ .short = 256 }), named("Y", .{ .short = 64 }) }, false);
    try Fixture.run(error.MissingDimensions, &.{ named("X", .{ .short = 256 }), named("Y", .{ .short = 64 }) }, true);
    try Fixture.run(error.MissingBlockArray, &.{ named("X", .{ .short = 256 }), named("Y", .{ .short = 64 }), named("Z", .{ .short = 256 }) }, false);
}

test "sniff_dims reads X/Y/Z shorts past earlier tags" {
    var buf: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try nbt.write_header(&w, .compound, "ClassicWorld");
    try named("FormatVersion", .{ .byte = FormatVersion }).write(&w);
    try named("Name", .{ .string = "test world" }).write(&w);
    try named("Spawn", .{ .compound = &.{} }).write(&w);
    try named("X", .{ .short = 512 }).write(&w);
    try named("Y", .{ .short = 128 }).write(&w);
    try named("Z", .{ .short = 512 }).write(&w);
    try named("CreatedBy", .{ .compound = &.{} }).write(&w);

    var r = std.Io.Reader.fixed(w.buffered());
    const dims = peek_classic_world_dims(&r).?;
    try std.testing.expectEqual(@as(u32, 512), dims.length);
    try std.testing.expectEqual(@as(u32, 128), dims.height);
    try std.testing.expectEqual(@as(u32, 512), dims.depth);
}

test "sniff_dims rejects non-ClassicWorld and dims after BlockArray" {
    var buf: [256]u8 = undefined;

    {
        var w = std.Io.Writer.fixed(&buf);
        try nbt.write_header(&w, .compound, "MinecraftLevel");
        var r = std.Io.Reader.fixed(w.buffered());
        try std.testing.expect(peek_classic_world_dims(&r) == null);
    }

    {
        // A foreign writer may place BlockArray before the dims; there is
        // nothing to sniff without inflating the whole payload.
        var w = std.Io.Writer.fixed(&buf);
        try nbt.write_header(&w, .compound, "ClassicWorld");
        try named("BlockArray", .{ .byte_array = &.{} }).write(&w);
        try named("X", .{ .short = 256 }).write(&w);
        try named("Y", .{ .short = 64 }).write(&w);
        try named("Z", .{ .short = 256 }).write(&w);
        var r = std.Io.Reader.fixed(w.buffered());
        try std.testing.expect(peek_classic_world_dims(&r) == null);
    }

    {
        var w = std.Io.Writer.fixed(&buf);
        try nbt.write_header(&w, .compound, "ClassicWorld");
        try w.writeByte(0xff);
        var r = std.Io.Reader.fixed(w.buffered());
        try std.testing.expect(peek_classic_world_dims(&r) == null);
    }
}

test "writer and loader round trip chunk-aware blocks and metadata" {
    const io = std.testing.io;
    const dims = WorldDims.init(128, 64, 128);
    var source: WorldData = undefined;
    try source.init_in_place(std.testing.allocator, dims, 1);
    defer source.deinit();

    const markers = [_]struct { x: u16, y: u16, z: u16, block: Block }{
        .{ .x = 0, .y = 0, .z = 0, .block = .stone },
        .{ .x = 15, .y = 7, .z = 15, .block = .glass },
        .{ .x = 16, .y = 7, .z = 15, .block = .flowing_water },
        .{ .x = 17, .y = 7, .z = 16, .block = .flowing_lava },
        .{ .x = 127, .y = 63, .z = 127, .block = .magenta_wool },
    };
    for (markers) |marker| {
        source.blocks[source.get_index(marker.x, marker.y, marker.z)] = marker.block;
    }

    const world_name = "round trip world";
    const uuid = [_]u8{ 0x10, 0x21, 0x32, 0x43, 0x54, 0x65, 0x76, 0x87, 0x98, 0xa9, 0xba, 0xcb, 0xdc, 0xed, 0xfe, 0x0f };
    const time_created: i64 = 1_725_000_123_456;
    const encoded = try std.testing.allocator.alloc(u8, 64 * 1024);
    defer std.testing.allocator.free(encoded);

    var writer = std.Io.Writer.fixed(encoded);

    try compress_worker.init(std.testing.allocator, io);
    defer compress_worker.deinit();

    try ClassicCw.save_world(.{}, .{
        .dims = dims,
        .seed = source.seed,
        .tick_count = source.tick_count,
        .world = &source,
        .io = io,
        .name = world_name,
        .uuid = uuid,
        .spawn = .{ 32, 64, 96 },
        .time_created = time_created,
        .last_modified = time_created + 1,
    }, &writer);

    const loaded = try std.testing.allocator.alloc(Block, dims.volume());
    defer std.testing.allocator.free(loaded);

    @memset(loaded, .bedrock);
    var reader = std.Io.Reader.fixed(writer.buffered());
    const outcome = try ClassicCw.load_world(.{}, std.testing.allocator, dims, loaded, &reader);

    try std.testing.expectEqual(dims.to_array(), outcome.dimensions);
    try std.testing.expectEqualStrings(world_name, outcome.name[0..outcome.name_len]);
    try std.testing.expectEqual(uuid, outcome.uuid);
    try std.testing.expectEqual(time_created, outcome.time_created);
    try std.testing.expectEqualSlices(Block, source.blocks, loaded);
    for (markers) |marker| {
        try std.testing.expectEqual(marker.block, loaded[source.get_index(marker.x, marker.y, marker.z)]);
    }
}
