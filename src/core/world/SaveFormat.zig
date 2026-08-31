// --- Save-format dispatch ---
//
// Tagged union over per-format state. `inline switch` gives comptime
// dispatch with zero allocation; arms can carry per-format scratch state
// (NBT tag stack, gzip ring) without growing the call signature.
//
// Adding a format: add an arm here, add a file under `formats/`. Both arms
// must expose `save_world(...)` and `load_world(...)` with matching
// signatures.

const std = @import("std");
const c = @import("../consts.zig");
const b = @import("../blocks.zig");

const Block = b.Block;

const classic_dat_mod = @import("formats/classic_dat.zig");
const classic_cw_mod = @import("formats/classic_cw.zig");

pub const ClassicDat = classic_dat_mod.ClassicDat;
pub const ClassicCw = classic_cw_mod.ClassicCw;

/// Everything a format may need to write a save. Formats are free to
/// ignore the metadata fields they don't carry on disk -- classic_dat
/// uses only world_size/seed/tick_count/blocks; classic_cw consumes all
/// of them.
pub const SaveContext = struct {
    world_size: [3]u16,
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

    pub fn save_world(
        self: SaveFormat,
        ctx: SaveContext,
        writer: *std.Io.Writer,
    ) !void {
        switch (self) {
            inline else => |arm| try arm.save_world(ctx, writer),
        }
    }

    pub fn load_world(
        self: SaveFormat,
        scratch: std.mem.Allocator,
        blocks: []Block,
        reader: *std.Io.Reader,
    ) !LoadOutcome {
        return switch (self) {
            inline else => |arm| try arm.load_world(scratch, blocks, reader),
        };
    }
};
