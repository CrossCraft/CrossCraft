// --- ClassicWorld .cw save format (NBT + gzip) ---
//
// Wraps the level data in the ClassicWorld NBT compound (FormatVersion,
// Name, UUID, X/Y/Z, CreatedBy, MapGenerator, timestamps, Spawn, BlockArray,
// Metadata) and gzip-compresses the result. Metadata is built in a stack
// FixedBufferAllocator (~2 KB). The 4 MB BlockArray is streamed through
// `nbt.write_named_byte_array_stream` so we never materialise the YZX byte
// layout in memory -- it goes chunk-row by chunk-row from the chunk-major
// in-memory blocks straight into the gzip stream.
//
// Runs on the shared compressor worker thread (see `compress_worker.zig`)
// because `flate.Compress.finish()` overflows the per-task IO async stack
// on PSP.

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
        // Wrap the file writer in gzip via the shared compressor.
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

// --- Save: NBT writer ---

fn write_classic_world_compound(ctx: SaveContext, out: *std.Io.Writer) !void {
    // Outer compound header: tag + name "ClassicWorld". The TAG_End that
    // closes the compound is written at the bottom of this function.
    try out.writeInt(u8, @intFromEnum(nbt.Tag.compound), .big);
    try write_string_payload(out, "ClassicWorld");

    // Build the metadata children in a stack arena. Each leaf is a slice
    // reference -- no copies of `ctx.name` or `ctx.uuid`.
    var scratch: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&scratch);
    const a = fba.allocator();

    const spawn_children = try a.alloc(nbt.NBT, 5);
    spawn_children[0] = leaf_short("X", @intCast(@as(i32, ctx.spawn[0]) >> 5));
    spawn_children[1] = leaf_short("Y", @intCast(@as(i32, ctx.spawn[1]) >> 5));
    spawn_children[2] = leaf_short("Z", @intCast(@as(i32, ctx.spawn[2]) >> 5));
    spawn_children[3] = leaf_byte("H", 0);
    spawn_children[4] = leaf_byte("P", 0);

    const created_by_children = try a.alloc(nbt.NBT, 2);
    created_by_children[0] = leaf_string("Service", CREATED_BY_SERVICE);
    created_by_children[1] = leaf_string("Username", CREATED_BY_USERNAME);

    const map_gen_children = try a.alloc(nbt.NBT, 2);
    map_gen_children[0] = leaf_string("Software", MAP_GENERATOR_SOFTWARE);
    map_gen_children[1] = leaf_string("MapGeneratorName", MAP_GENERATOR_NAME);

    var uuid_copy = ctx.uuid;
    const meta_children = [_]nbt.NBT{
        leaf_byte("FormatVersion", FORMAT_VERSION),
        leaf_string("Name", ctx.name),
        named("UUID", .{ .byte_array = .{ .value = &uuid_copy } }),
        leaf_short("X", @intCast(ctx.dims.length)),
        leaf_short("Y", @intCast(ctx.dims.height)),
        leaf_short("Z", @intCast(ctx.dims.depth)),
        named("CreatedBy", .{ .compound = .{ .value = created_by_children } }),
        named("MapGenerator", .{ .compound = .{ .value = map_gen_children } }),
        leaf_long("TimeCreated", ctx.time_created),
        leaf_long("LastAccessed", ctx.last_modified),
        leaf_long("LastModified", ctx.last_modified),
        named("Spawn", .{ .compound = .{ .value = spawn_children } }),
    };

    for (meta_children) |child| {
        try child.write(out);
    }

    // Stream the BlockArray body in spec-correct YZX order. The NBT
    // helper writes the tag/name/length header; BlockBody streams the
    // bytes via WorldData.write_blocks_yzx so no contiguous scratch
    // is needed.
    const total_len: u32 = @intCast(ctx.dims.volume());
    const BlockBody = struct {
        dims: WorldDims,
        blocks: []const Block,
        pub fn write_into(self: @This(), w: *std.Io.Writer) nbt.WriteError!void {
            // Mirror of WorldData.write_blocks_yzx, inlined to avoid the
            // dependency on a *WorldData (we have a flat slice from ctx).
            for (0..self.dims.height) |yi| {
                for (0..self.dims.depth) |zi| {
                    for (0..self.dims.chunks_x) |cxi| {
                        const base = self.dims.block_index(@intCast(cxi * wd.chunk_size), @intCast(yi), @intCast(zi));
                        const slice: *const [wd.chunk_size]u8 = @ptrCast(self.blocks[base..][0..wd.chunk_size]);
                        try w.writeAll(slice);
                    }
                }
            }
        }
    };
    try nbt.write_named_byte_array_stream(out, "BlockArray", total_len, BlockBody{ .dims = ctx.dims, .blocks = ctx.blocks });

    // Empty Metadata compound: tag + name + immediate TAG_End.
    try out.writeInt(u8, @intFromEnum(nbt.Tag.compound), .big);
    try write_string_payload(out, "Metadata");
    try out.writeInt(u8, @intFromEnum(nbt.Tag.end), .big);

    // Close outer ClassicWorld compound.
    try out.writeInt(u8, @intFromEnum(nbt.Tag.end), .big);
}

fn write_string_payload(writer: *std.Io.Writer, s: []const u8) !void {
    try writer.writeInt(u16, @intCast(s.len), .big);
    try writer.writeAll(s);
}

fn named(name: []const u8, value: nbt.NBT.Value) nbt.NBT {
    return .{ .name = .{ .value = @constCast(name) }, .value = value };
}

fn leaf_byte(name: []const u8, value: i8) nbt.NBT {
    return named(name, .{ .byte = .{ .value = value } });
}

fn leaf_short(name: []const u8, value: i16) nbt.NBT {
    return named(name, .{ .short = .{ .value = value } });
}

fn leaf_long(name: []const u8, value: i64) nbt.NBT {
    return named(name, .{ .long = .{ .value = value } });
}

fn leaf_string(name: []const u8, value: []const u8) nbt.NBT {
    return named(name, .{ .string = .{ .value = @constCast(value) } });
}

// --- Load: NBT reader ---

fn read_classic_world_compound(
    reader: *std.Io.Reader,
    dims: WorldDims,
    blocks: []Block,
) !LoadOutcome {
    // Outer tag must be a compound named "ClassicWorld".
    const tag = try reader.takeInt(u8, .big);
    if (tag != @intFromEnum(nbt.Tag.compound)) return error.InvalidTag;
    var name_buf: [64]u8 = undefined;
    const name = try take_string(reader, &name_buf);
    if (!std.mem.eql(u8, name, "ClassicWorld")) return error.UnexpectedName;

    var outcome: LoadOutcome = .{
        .dimensions = dims.to_array(),
        .seed = 0,
        .tick_count = 0,
    };

    // Walk children until TAG_End. Recognise known names; skip unknown.
    while (true) {
        const child_tag = try reader.takeInt(u8, .big);
        if (child_tag == @intFromEnum(nbt.Tag.end)) break;
        const child_name = try take_string(reader, &name_buf);
        const t: nbt.Tag = @enumFromInt(child_tag);

        if (std.mem.eql(u8, child_name, "BlockArray")) {
            // We've already consumed the tag + name. The streaming helper
            // would re-consume them, so call its body inline here: read
            // i32 length and stream into the chunk-major layout.
            if (t != .byte_array) return error.InvalidTag;
            const len = try reader.takeInt(i32, .big);
            if (!dims.matches(outcome.dimensions)) return error.DimensionMismatch;
            const expected: u32 = @intCast(dims.volume());
            if (len < 0 or @as(u32, @intCast(len)) != expected) return error.UnexpectedByteArrayLength;
            try read_blocks_yzx_into(dims, blocks, reader);
        } else if (std.mem.eql(u8, child_name, "X") and t == .short) {
            outcome.dimensions[0] = @intCast(try reader.takeInt(i16, .big));
        } else if (std.mem.eql(u8, child_name, "Y") and t == .short) {
            outcome.dimensions[1] = @intCast(try reader.takeInt(i16, .big));
        } else if (std.mem.eql(u8, child_name, "Z") and t == .short) {
            outcome.dimensions[2] = @intCast(try reader.takeInt(i16, .big));
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

    return outcome;
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
    const tag = reader.takeInt(u8, .big) catch return null;
    if (tag != @intFromEnum(nbt.Tag.compound)) return null;
    var name_buf: [64]u8 = undefined;
    const name = take_string(reader, &name_buf) catch return null;
    if (!std.mem.eql(u8, name, "ClassicWorld")) return null;

    var dims: [3]u16 = undefined;
    var seen_x = false;
    var seen_y = false;
    var seen_z = false;
    while (!(seen_x and seen_y and seen_z)) {
        const child_tag = reader.takeInt(u8, .big) catch return null;
        if (child_tag == @intFromEnum(nbt.Tag.end)) return null;
        const child_name = take_string(reader, &name_buf) catch return null;
        const t: nbt.Tag = @enumFromInt(child_tag);

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

fn read_blocks_yzx_into(dims: WorldDims, blocks: []Block, reader: *std.Io.Reader) !void {
    for (0..dims.height) |yi| {
        for (0..dims.depth) |zi| {
            for (0..dims.chunks_x) |cxi| {
                const base = dims.block_index(@intCast(cxi * wd.chunk_size), @intCast(yi), @intCast(zi));
                const slice: *[wd.chunk_size]u8 = @ptrCast(blocks[base..][0..wd.chunk_size]);
                try reader.readSliceAll(slice);
            }
        }
    }
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
    const elem_tag_byte = try reader.takeInt(u8, .big);
    if (elem_tag_byte > @intFromEnum(nbt.Tag.compound)) return error.InvalidTag;
    const elem_tag: nbt.Tag = @enumFromInt(elem_tag_byte);
    const len = try reader.takeInt(i32, .big);
    if (len <= 0) return;
    var i: i32 = 0;
    while (i < len) : (i += 1) {
        try skip_payload(reader, elem_tag);
    }
}

fn skip_compound(reader: *std.Io.Reader) SkipError!void {
    while (true) {
        const t_byte = try reader.takeInt(u8, .big);
        if (t_byte == @intFromEnum(nbt.Tag.end)) return;
        if (t_byte > @intFromEnum(nbt.Tag.compound)) return error.InvalidTag;
        const name_len = try reader.takeInt(u16, .big);
        try reader.discardAll64(name_len);
        try skip_payload(reader, @enumFromInt(t_byte));
    }
}

test "sniff_dims reads X/Y/Z shorts past earlier tags" {
    var buf: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try w.writeInt(u8, @intFromEnum(nbt.Tag.compound), .big);
    try write_string_payload(&w, "ClassicWorld");
    try leaf_byte("FormatVersion", FORMAT_VERSION).write(&w);
    try leaf_string("Name", "test world").write(&w);
    try named("Spawn", .{ .compound = .{ .value = &.{} } }).write(&w);
    try leaf_short("X", 512).write(&w);
    try leaf_short("Y", 128).write(&w);
    try leaf_short("Z", 512).write(&w);
    try named("CreatedBy", .{ .compound = .{ .value = &.{} } }).write(&w);

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
        try named("BlockArray", .{ .byte_array = .{ .value = &.{} } }).write(&w);
        try leaf_short("X", 256).write(&w);
        try leaf_short("Y", 64).write(&w);
        try leaf_short("Z", 256).write(&w);
        var r = std.Io.Reader.fixed(w.buffered());
        try std.testing.expect(peek_classic_world_dims(&r) == null);
    }
}
