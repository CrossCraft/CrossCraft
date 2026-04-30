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
const common = @import("common");
const c = common.consts;

const Block = c.Block;

const classic_dat_mod = @import("formats/classic_dat.zig");
const classic_cw_mod = @import("formats/classic_cw.zig");

pub const ClassicDat = classic_dat_mod.ClassicDat;
pub const ClassicCw = classic_cw_mod.ClassicCw;
pub const LoadOutcome = classic_dat_mod.LoadOutcome;

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

    pub fn save_world(
        self: SaveFormat,
        world_size: [3]u16,
        seed: u64,
        tick_count: u64,
        raw_blocks: []const u8,
        blocks: []const Block,
        writer: *std.Io.Writer,
    ) !void {
        switch (self) {
            inline else => |arm| try arm.save_world(
                world_size,
                seed,
                tick_count,
                raw_blocks,
                blocks,
                writer,
            ),
        }
    }

    pub fn load_world(
        self: SaveFormat,
        raw_blocks: []u8,
        blocks: []Block,
        reader: *std.Io.Reader,
    ) !LoadOutcome {
        return switch (self) {
            inline else => |arm| try arm.load_world(raw_blocks, blocks, reader),
        };
    }
};
