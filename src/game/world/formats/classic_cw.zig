// --- ClassicWorld .cw save format (NBT + gzip) ---
//
// Stub. The seam is wired so server.properties can select this format,
// but neither direction is implemented yet. A follow-up PR will land the
// NBT writer + gzip stream + ClassicWorld schema + block-id remap.
//
// Until then both directions return `error.NotImplemented`. Callers
// (WorldSaver.try_load, save_worker) handle the error: load failure
// falls back to worldgen on the SP path; save failure logs and the
// file is left untouched.

const std = @import("std");
const common = @import("common");
const c = common.consts;

const Block = c.Block;

const LoadOutcome = @import("classic_dat.zig").LoadOutcome;

pub const ClassicCw = struct {
    pub fn save_world(
        _: ClassicCw,
        _: [3]u16,
        _: u64,
        _: u64,
        _: []const u8,
        _: []const Block,
        _: *std.Io.Writer,
    ) !void {
        return error.NotImplemented;
    }

    pub fn load_world(
        _: ClassicCw,
        _: []u8,
        _: []Block,
        _: *std.Io.Reader,
    ) !LoadOutcome {
        return error.NotImplemented;
    }
};
