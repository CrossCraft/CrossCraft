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

const FORMAT_VERSION: i8 = 1;
const CREATED_BY_SERVICE = "CrossCraft";
const CREATED_BY_USERNAME = "Server";
const MAP_GENERATOR_SOFTWARE = "CrossCraft";
const MAP_GENERATOR_NAME = "Classic";

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

    /// Dimensions announced by the ClassicWorld NBT header, sniffed from an
    /// inflated prefix. Null when the prefix is not a ClassicWorld compound,
    /// the X/Y/Z shorts do not all appear before BlockArray, or the dims
    /// fall outside the supported lattice.
    pub fn sniff_dims(_: ClassicCw, prefix: []const u8, scratch: std.mem.Allocator) ?WorldDims {
        if (!fmt_mod.SaveFormat.verify_classic_cw(prefix, scratch)) return null;
        const window_buf = scratch.alloc(u8, std.compress.flate.max_window_len) catch return null;
        defer scratch.free(window_buf);

        var src = std.Io.Reader.fixed(prefix);
        var decompress = std.compress.flate.Decompress.init(&src, .gzip, window_buf);
        return peek_classic_world_dims(&decompress.reader);
    }
};

fn write_classic_world_compound(ctx: SaveContext, out: *std.Io.Writer) !void {
    try out.writeInt(u8, @intFromEnum(nbt.Tag.compound), .big);
    try write_string_payload(out, "ClassicWorld");

    const spawn_children = [_]nbt.NBT{
        leaf_short("X", @intCast(@as(i32, ctx.spawn[0]) >> 5)),
        leaf_short("Y", @intCast(@as(i32, ctx.spawn[1]) >> 5)),
        leaf_short("Z", @intCast(@as(i32, ctx.spawn[2]) >> 5)),
        leaf_byte("H", 0),
        leaf_byte("P", 0),
    };
    const created_by_children = [_]nbt.NBT{
        leaf_string("Service", CREATED_BY_SERVICE),
        leaf_string("Username", CREATED_BY_USERNAME),
    };
    const map_gen_children = [_]nbt.NBT{
        leaf_string("Software", MAP_GENERATOR_SOFTWARE),
        leaf_string("MapGeneratorName", MAP_GENERATOR_NAME),
    };

    var uuid_copy = ctx.uuid;
    const meta_children = [_]nbt.NBT{
        leaf_byte("FormatVersion", FORMAT_VERSION),
        leaf_string("Name", ctx.name),
        named("UUID", .{ .byte_array = &uuid_copy }),
        leaf_short("X", @intCast(ctx.dims.length)),
        leaf_short("Y", @intCast(ctx.dims.height)),
        leaf_short("Z", @intCast(ctx.dims.depth)),
        named("CreatedBy", .{ .compound = &created_by_children }),
        named("MapGenerator", .{ .compound = &map_gen_children }),
        leaf_long("TimeCreated", ctx.time_created),
        leaf_long("LastAccessed", ctx.last_modified),
        leaf_long("LastModified", ctx.last_modified),
        named("Spawn", .{ .compound = &spawn_children }),
    };

    for (meta_children) |child| {
        try child.write(out);
    }

    // Stream BlockArray in spec-correct YZX order. Each band is copied while
    // the world is read-locked, then compressed after releasing the lock.
    const total_len: u32 = @intCast(ctx.dims.volume());
    const BlockBody = struct {
        world: *WorldData,
        io: std.Io,

        pub fn write_into(self: @This(), w: *std.Io.Writer) nbt.WriteError!void {
            try self.world.write_blocks_yzx(self.io, w);
        }
    };
    try nbt.write_named_byte_array_stream(out, "BlockArray", total_len, BlockBody{ .world = ctx.world, .io = ctx.io });

    try out.writeInt(u8, @intFromEnum(nbt.Tag.compound), .big);
    try write_string_payload(out, "Metadata");
    try out.writeInt(u8, @intFromEnum(nbt.Tag.end), .big);

    try out.writeInt(u8, @intFromEnum(nbt.Tag.end), .big);
}

fn write_string_payload(writer: *std.Io.Writer, s: []const u8) !void {
    try writer.writeInt(u16, @intCast(s.len), .big);
    try writer.writeAll(s);
}

fn named(name: []const u8, value: nbt.NBT.Value) nbt.NBT {
    return .{ .name = name, .value = value };
}

fn leaf_byte(name: []const u8, value: i8) nbt.NBT {
    return named(name, .{ .byte = value });
}

fn leaf_short(name: []const u8, value: i16) nbt.NBT {
    return named(name, .{ .short = value });
}

fn leaf_long(name: []const u8, value: i64) nbt.NBT {
    return named(name, .{ .long = value });
}

fn leaf_string(name: []const u8, value: []const u8) nbt.NBT {
    return named(name, .{ .string = value });
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
            // We've already consumed the tag + name. The streaming helper
            // would re-consume them, so call its body inline here: read
            // i32 length and stream into the chunk-major layout.
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

/// Walk the outer compound capturing the X/Y/Z shorts. Stops at BlockArray:
/// its payload is the bulk of the file, and a header that places it before
/// the dims gives the sniff nothing to read.
fn peek_classic_world_dims(reader: *std.Io.Reader) ?WorldDims {
    if ((nbt.read_tag(reader) catch return null) != .compound) return null;
    var name_buf: [64]u8 = undefined;
    const name = take_string(reader, &name_buf) catch return null;
    if (!std.mem.eql(u8, name, "ClassicWorld")) return null;

    var dims: [3]u16 = undefined;
    var seen_x = false;
    var seen_y = false;
    var seen_z = false;
    while (!(seen_x and seen_y and seen_z)) {
        const t = nbt.read_tag(reader) catch return null;
        if (t == .end) return null;
        const child_name = take_string(reader, &name_buf) catch return null;

        if (std.mem.eql(u8, child_name, "BlockArray")) return null;
        // Bitcast keeps a hostile negative short from panicking; an
        // implausible value simply fails the from_array validation below.
        if (std.mem.eql(u8, child_name, "X") and t == .short and !seen_x) {
            dims[0] = @bitCast(reader.takeInt(i16, .big) catch return null);
            seen_x = true;
        } else if (std.mem.eql(u8, child_name, "Y") and t == .short and !seen_y) {
            dims[1] = @bitCast(reader.takeInt(i16, .big) catch return null);
            seen_y = true;
        } else if (std.mem.eql(u8, child_name, "Z") and t == .short and !seen_z) {
            dims[2] = @bitCast(reader.takeInt(i16, .big) catch return null);
            seen_z = true;
        } else {
            skip_payload(reader, t) catch return null;
        }
    }
    return WorldDims.from_array(dims);
}

/// Skip the payload of any NBT tag we don't care about, leaving the
/// reader positioned on the next sibling tag byte.
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
        .list => try skip_list(reader),
        .compound => try skip_compound(reader),
    }
}

fn skip_list(reader: *std.Io.Reader) SkipError!void {
    const elem_tag = try nbt.read_tag(reader);
    const len = try reader.takeInt(i32, .big);
    if (len <= 0) return;
    var i: i32 = 0;
    while (i < len) : (i += 1) {
        try skip_payload(reader, elem_tag);
    }
}

fn skip_compound(reader: *std.Io.Reader) SkipError!void {
    while (true) {
        const tag = try nbt.read_tag(reader);
        if (tag == .end) return;
        const name_len = try reader.takeInt(u16, .big);
        try reader.discardAll64(name_len);
        try skip_payload(reader, tag);
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
    try w.writeByte(@intFromEnum(nbt.Tag.compound));
    try write_string_payload(&w, "ClassicWorld");
    try leaf_short("Z", 128).write(&w);
    try leaf_short("X", 128).write(&w);
    try leaf_short("Y", 64).write(&w);
    try w.writeByte(@intFromEnum(nbt.Tag.byte_array));
    try write_string_payload(&w, "BlockArray");
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
    try duplicate.writeByte(@intFromEnum(nbt.Tag.byte_array));
    try write_string_payload(&duplicate, "BlockArray");
    var duplicate_reader = std.Io.Reader.fixed(encoded[0 .. duplicate_start + duplicate.buffered().len]);
    try std.testing.expectError(error.DuplicateBlockArray, read_classic_world_compound(&duplicate_reader, dims, blocks));
}

test "loader rejects malformed dimensions before writing blocks" {
    const Fixture = struct {
        fn run(expected_error: anyerror, children: []const nbt.NBT, block_array_after: bool) !void {
            var buf: [256]u8 = undefined;
            var w = std.Io.Writer.fixed(&buf);
            try w.writeByte(@intFromEnum(nbt.Tag.compound));
            try write_string_payload(&w, "ClassicWorld");
            for (children) |child| try child.write(&w);
            if (block_array_after) {
                try w.writeByte(@intFromEnum(nbt.Tag.byte_array));
                try write_string_payload(&w, "BlockArray");
            } else {
                try w.writeByte(@intFromEnum(nbt.Tag.end));
            }

            var blocks = [1]Block{.stone};
            var r = std.Io.Reader.fixed(w.buffered());
            try std.testing.expectError(expected_error, read_classic_world_compound(&r, wd.default, &blocks));
            try std.testing.expectEqual(Block.stone, blocks[0]);
        }
    };

    try Fixture.run(error.InvalidDimensions, &.{leaf_short("X", -1)}, false);
    try Fixture.run(error.InvalidDimensions, &.{leaf_short("X", 192)}, false);
    try Fixture.run(error.DimensionMismatch, &.{leaf_short("X", 128)}, false);
    try Fixture.run(error.DuplicateDimension, &.{ leaf_short("X", 256), leaf_short("X", 256) }, false);
    try Fixture.run(error.MissingDimensions, &.{ leaf_short("X", 256), leaf_short("Y", 64) }, false);
    try Fixture.run(error.MissingDimensions, &.{ leaf_short("X", 256), leaf_short("Y", 64) }, true);
    try Fixture.run(error.MissingBlockArray, &.{ leaf_short("X", 256), leaf_short("Y", 64), leaf_short("Z", 256) }, false);
}

test "sniff_dims reads X/Y/Z shorts past earlier tags" {
    var buf: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try w.writeInt(u8, @intFromEnum(nbt.Tag.compound), .big);
    try write_string_payload(&w, "ClassicWorld");
    try leaf_byte("FormatVersion", FORMAT_VERSION).write(&w);
    try leaf_string("Name", "test world").write(&w);
    try named("Spawn", .{ .compound = &.{} }).write(&w);
    try leaf_short("X", 512).write(&w);
    try leaf_short("Y", 128).write(&w);
    try leaf_short("Z", 512).write(&w);
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
        try w.writeInt(u8, @intFromEnum(nbt.Tag.compound), .big);
        try write_string_payload(&w, "MinecraftLevel");
        var r = std.Io.Reader.fixed(w.buffered());
        try std.testing.expect(peek_classic_world_dims(&r) == null);
    }

    {
        // A foreign writer may place BlockArray before the dims; there is
        // nothing to sniff without inflating the whole payload.
        var w = std.Io.Writer.fixed(&buf);
        try w.writeInt(u8, @intFromEnum(nbt.Tag.compound), .big);
        try write_string_payload(&w, "ClassicWorld");
        try named("BlockArray", .{ .byte_array = &.{} }).write(&w);
        try leaf_short("X", 256).write(&w);
        try leaf_short("Y", 64).write(&w);
        try leaf_short("Z", 256).write(&w);
        var r = std.Io.Reader.fixed(w.buffered());
        try std.testing.expect(peek_classic_world_dims(&r) == null);
    }

    {
        var w = std.Io.Writer.fixed(&buf);
        try w.writeByte(@intFromEnum(nbt.Tag.compound));
        try write_string_payload(&w, "ClassicWorld");
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
