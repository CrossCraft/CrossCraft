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

        const prefix = reader.interface.peek(sniff_prefix_len) catch reader.interface.buffered();

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
