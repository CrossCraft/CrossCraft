// --- Save-format dispatch ---
//
// Tagged union over per-format state. `inline switch` gives comptime
// dispatch with zero allocation; arms can carry per-format scratch state
// (NBT tag stack, gzip ring) without growing the call signature.
//
// Adding a format: add an arm here, add a file under `formats/`. Both arms
// must expose `save_world(...)`, `load_world(...)` and `sniff_dims(...)`
// with matching signatures.

const std = @import("std");
const b = @import("../blocks.zig");
const WorldDims = @import("../world_dims.zig").WorldDims;

const Block = b.Block;

const classic_dat_mod = @import("formats/classic_dat.zig");
const classic_cw_mod = @import("formats/classic_cw.zig");

pub const ClassicDat = classic_dat_mod.ClassicDat;
pub const ClassicCw = classic_cw_mod.ClassicCw;

/// Everything a format may need to write a save. Formats are free to
/// ignore the metadata fields they don't carry on disk -- classic_dat
/// uses only dims/seed/tick_count/blocks; classic_cw consumes all
/// of them.
pub const SaveContext = struct {
    dims: WorldDims,
    seed: u64,
    tick_count: u64,
    blocks: []const Block,
    name: []const u8,
    uuid: [16]u8,
    spawn: [3]u16,
    time_created: i64,
    last_modified: i64,
};

/// Everything a format returns from a successful load. Formats that don't
/// carry a field on disk fill it with a sensible default (zero / empty).
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

    /// Parse a `save-format` string from server.properties. Unknown values
    /// fall back to classic_dat. Empty string = caller-side default.
    pub fn parse(name: []const u8) ?SaveFormat {
        if (std.mem.eql(u8, name, "classic_dat")) return .{ .classic_dat = .{} };
        if (std.mem.eql(u8, name, "classic_cw")) return .{ .classic_cw = .{} };
        return null;
    }

    /// Sniff the on-disk format from a file's leading bytes. classic_cw
    /// files start with the gzip magic 1f 8b; anything else is treated as
    /// classic_dat (whose header begins with the little-endian world
    /// length, which never collides with the gzip magic for any sane
    /// world dimension). The gzip arm is a *candidate* -- callers should
    /// confirm with `verify_classic_cw` before committing, because legacy
    /// formats (notably Minecraft Classic .mclevel) also use gzip but
    /// carry a Java-serialized payload rather than NBT. Returns null when
    /// the prefix is too short to classify.
    pub fn detect(prefix: []const u8) ?SaveFormat {
        if (prefix.len < 2) return null;
        if (prefix[0] == 0x1f and prefix[1] == 0x8b) return .{ .classic_cw = .{} };
        return .{ .classic_dat = .{} };
    }

    /// Confirm that a gzip-prefixed file is actually classic_cw by
    /// inflating just enough to inspect the first NBT tag byte. Returns
    /// true only when the inflated stream begins with TAG_Compound (0x0A),
    /// matching the ClassicWorld outer compound. False on any decode
    /// failure, short prefix, or non-NBT payload (e.g. Java serialization
    /// magic ac ed in legacy .mclevel files). The caller-supplied prefix
    /// must include the gzip header plus enough deflate bytes to yield
    /// one inflated byte -- 256 bytes covers every real-world classic_cw
    /// save by a wide margin.
    pub fn verify_classic_cw(prefix: []const u8, scratch: std.mem.Allocator) bool {
        // Gzip header alone is 10 bytes; need at least one deflated byte
        // beyond it to yield an inflated tag.
        if (prefix.len < 12) return false;
        var src = std.Io.Reader.fixed(prefix);
        const window_buf = scratch.alloc(u8, std.compress.flate.max_window_len) catch return false;
        defer scratch.free(window_buf);
        var decompress = std.compress.flate.Decompress.init(&src, .gzip, window_buf);
        const first = decompress.reader.takeByte() catch return false;
        // 0x0A == nbt.Tag.compound; named here as a literal so this module
        // doesn't pull in nbt for a single comparison.
        return first == 0x0A;
    }

    /// Prefix length a sniff needs. Covers the gzip header plus enough
    /// deflate output to inflate past the classic_cw X/Y/Z header tags;
    /// short files fall back to shorter peeks.
    const sniff_prefix_len: usize = 16384;

    /// Read the dimensions a save file announces in its header, without
    /// touching the block payload. Existing saves boot at their own
    /// geometry regardless of the configured world size, so `world.init`
    /// and the backup validator call this before any buffer is allocated.
    /// Returns null when the file is missing, unrecognized, or announces
    /// dims outside the supported lattice.
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

        // Walk down the peek size on failure, mirroring WorldSaver.try_load:
        // a shorter file only yields a shorter peek. The 6-byte floor is the
        // classic_dat dimension header.
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

    /// Load a save into `blocks`, which the caller allocated for `dims`. A
    /// format must reject a file whose recorded dimensions differ before
    /// writing into that buffer.
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

/// Minimal ClassicWorld NBT header: compound + X/Y/Z short leaves, no
/// payload tags. Written as raw bytes so this module stays nbt-free.
const test_header_nbt = [_]u8{
    0x0A, // TAG_Compound
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

    // classic_dat: dims are the raw little-endian header.
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

    // classic_cw: gzip the header NBT with std flate directly (the real
    // writer goes through the shared compress worker). The file is padded
    // past the sniff prefix because the peek walk must be able to hand the
    // sniffer its full window, as it can for every real (megabyte) save.
    {
        var gz_buf: [512]u8 = undefined;
        var out = std.Io.Writer.fixed(&gz_buf);
        var window: [std.compress.flate.max_window_len]u8 = undefined;
        var comp = try std.compress.flate.Compress.init(&out, &window, .gzip, .fastest);
        try comp.writer.writeAll(&test_header_nbt);
        try comp.finish();

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
