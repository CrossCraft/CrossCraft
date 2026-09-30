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
