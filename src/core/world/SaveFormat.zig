const std = @import("std");
const b = @import("../blocks.zig");
const WorldDims = @import("../world_dims.zig").WorldDims;
const WorldData = @import("WorldData.zig");

const Block = b.Block;

const classic_dat_mod = @import("formats/classic_dat.zig");
const classic_cw_mod = @import("formats/classic_cw.zig");

const ClassicDat = classic_dat_mod.ClassicDat;
const ClassicCw = classic_cw_mod.ClassicCw;

pub const SaveContext = struct {
    dims: WorldDims,
    seed: u64,
    tick_count: u64,
    world: *WorldData,
    io: std.Io,
    name: []const u8,
    uuid: [16]u8,
    spawn: [3]u16,
    time_created: i64,
    last_modified: i64,
};

pub const LoadOutcome = struct {
    dimensions: [3]u16,
    seed: u64,
    tick_count: u64,
    name: [64]u8 = @splat(0),
    name_len: u8 = 0,
    uuid: [16]u8 = @splat(0),
    time_created: i64 = 0,
};

pub const SaveFormat = union(enum) {
    classic_dat: ClassicDat,
    classic_cw: ClassicCw,

    pub fn parse(name: []const u8) ?SaveFormat {
        if (std.mem.eql(u8, name, "classic_dat")) return .{ .classic_dat = .{} };
        if (std.mem.eql(u8, name, "classic_cw")) return .{ .classic_cw = .{} };
        return null;
    }

    /// Gzip identifies a ClassicWorld candidate; callers must verify it because
    /// legacy Java-serialized levels also use gzip.
    pub fn detect(prefix: []const u8) ?SaveFormat {
        if (prefix.len < 2) return null;
        if (prefix[0] == 0x1f and prefix[1] == 0x8b) return .{ .classic_cw = .{} };
        return .{ .classic_dat = .{} };
    }

    /// Check that a gzip candidate inflates to an NBT compound.
    pub fn verify_classic_cw(prefix: []const u8, scratch: std.mem.Allocator) bool {
        if (prefix.len < 12) return false;
        var src = std.Io.Reader.fixed(prefix);
        const window_buf = scratch.alloc(u8, std.compress.flate.max_window_len) catch return false;
        defer scratch.free(window_buf);
        var decompress = std.compress.flate.Decompress.init(&src, .gzip, window_buf);
        const first = decompress.reader.takeByte() catch return false;
        return first == 0x0A;
    }

    const sniff_prefix_len: usize = 16384;

    /// Read dimensions from a save header without touching its block payload.
    pub fn sniff_dims(
        io: std.Io,
        dir: std.Io.Dir,
        file_name: []const u8,
        scratch: std.mem.Allocator,
    ) ?WorldDims {
        const file = dir.openFile(io, file_name, .{}) catch return null;
        defer file.close(io);

        const read_buf = scratch.alloc(u8, sniff_prefix_len) catch return null;
        defer scratch.free(read_buf);
        var reader = file.reader(io, read_buf);

        const peek_sizes = [_]usize{ sniff_prefix_len, 8192, 4096, 1024, 256, 64, 12, 6 };
        var prefix: []const u8 = &.{};
        inline for (peek_sizes) |sz| {
            if (reader.interface.peek(sz)) |s| {
                prefix = s;
                break;
            } else |_| {}
        }

        const sniff = detect(prefix) orelse return null;
        return switch (sniff) {
            inline else => |arm| arm.sniff_dims(prefix, scratch),
        };
    }

    pub fn save_world(
        self: SaveFormat,
        ctx: SaveContext,
        writer: *std.Io.Writer,
    ) !void {
        switch (self) {
            inline else => |arm| try arm.save_world(ctx, writer),
        }
    }

    /// Formats must validate their dimensions before writing into `blocks`.
    pub fn load_world(
        self: SaveFormat,
        scratch: std.mem.Allocator,
        dims: WorldDims,
        blocks: []Block,
        reader: *std.Io.Reader,
    ) !LoadOutcome {
        return switch (self) {
            inline else => |arm| try arm.load_world(scratch, dims, blocks, reader),
        };
    }
};

const test_header_nbt = [_]u8{
    0x0A,
    0x00,
    0x0C,
    'C',
    'l',
    'a',
    's',
    's',
    'i',
    'c',
    'W',
    'o',
    'r',
    'l',
    'd',
    0x02, 0x00, 0x01, 'X', 0x02, 0x00, // TAG_Short 512
    0x02, 0x00, 0x01, 'Y', 0x00, 0x80, // TAG_Short 128
    0x02, 0x00, 0x01, 'Z', 0x02, 0x00, // TAG_Short 512
};

test "sniff_dims reads the announced geometry from both formats" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        var dat: [8]u8 = @splat(0);
        std.mem.writeInt(u16, dat[0..2], 128, .little);
        std.mem.writeInt(u16, dat[2..4], 64, .little);
        std.mem.writeInt(u16, dat[4..6], 128, .little);
        const file = try tmp.dir.createFile(io, "world.dat", .{});
        defer file.close(io);
        try file.writeStreamingAll(io, &dat);

        const dims = SaveFormat.sniff_dims(io, tmp.dir, "world.dat", std.testing.allocator).?;
        try std.testing.expectEqual(@as(u32, 128), dims.length);
        try std.testing.expectEqual(@as(u32, 64), dims.height);
        try std.testing.expectEqual(@as(u32, 128), dims.depth);
    }

    {
        var gz_buf: [512]u8 = undefined;
        var out = std.Io.Writer.fixed(&gz_buf);
        var window: [std.compress.flate.max_window_len]u8 = undefined;
        var comp = try std.compress.flate.Compress.init(&out, &window, .gzip, .fastest);
        try comp.writer.writeAll(&test_header_nbt);
        try comp.finish();

        // Match the full prefix available from a real world file.
        var file_bytes: [16384 + 256]u8 = @splat(0);
        @memcpy(file_bytes[0..out.buffered().len], out.buffered());

        const file = try tmp.dir.createFile(io, "world.cw", .{});
        defer file.close(io);
        try file.writeStreamingAll(io, &file_bytes);

        const dims = SaveFormat.sniff_dims(io, tmp.dir, "world.cw", std.testing.allocator).?;
        try std.testing.expectEqual(@as(u32, 512), dims.length);
        try std.testing.expectEqual(@as(u32, 128), dims.height);
        try std.testing.expectEqual(@as(u32, 512), dims.depth);
    }
}

test "sniff_dims returns null for missing and unrecognized files" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try std.testing.expect(SaveFormat.sniff_dims(io, tmp.dir, "missing.cw", std.testing.allocator) == null);

    const file = try tmp.dir.createFile(io, "garbage.dat", .{});
    defer file.close(io);
    try file.writeStreamingAll(io, "not a save at all");
    try std.testing.expect(SaveFormat.sniff_dims(io, tmp.dir, "garbage.dat", std.testing.allocator) == null);
}
