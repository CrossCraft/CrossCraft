//! Persisted user preferences.
//!
//! `Options.current` is the live singleton.  Call `load` on startup and
//! `save` whenever settings change.  Both operate on `options.json` in the
//! application data directory (`engine.dirs.data`).

const std = @import("std");
const Io = std.Io;
const File = std.Io.File;
const cfg = @import("config.zig");

const log = std.log.scoped(.options);

const options_file = "options.json";
const max_pack_path: usize = 256;
/// Generous upper bound for the JSON file (typical size ~300 bytes).
const max_json_size: usize = 4096;

/// Live singleton.  Any system may read `Options.current`; only `load` and
/// the settings UI should write it.
pub var current: Options = .{};

pub const Options = struct {
    /// Path of the active texture pack (relative to the data dir).
    /// Empty string means use the built-in default pack.
    active_texturepack_buf: [max_pack_path]u8 = [_]u8{0} ** max_pack_path,
    active_texturepack_len: u8 = 0,

    /// Chunk render radius.  Defaults to the platform maximum so PSP builds
    /// do not write a value larger than they can ever use.
    render_distance: u8 = @intCast(@min(@as(u32, 8), cfg.current.chunk_radius)),

    /// SFX volume multiplier (0.0 = silent, 1.0 = full).
    sound_volume: f32 = 1.0,

    /// Music volume multiplier (0.0 = silent, 1.0 = full).
    music_volume: f32 = 0.5,

    /// Vertical field of view in degrees.
    fov: f32 = 70.0,

    /// True = full leaf transparency (fancy); false = opaque leaves (fast).
    fancy_leaves: bool = true,

    /// Mouse / analogue-stick look sensitivity multiplier.
    sensitivity: f32 = 3.0,

    /// Smooth ambient occlusion on block faces.
    ambient_occlusion: bool = true,

    /// Returns the active texture pack path as a slice (may be empty).
    pub fn active_texturepack(self: *const Options) []const u8 {
        return self.active_texturepack_buf[0..self.active_texturepack_len];
    }

    /// Stores `path` in the fixed buffer, truncating silently if needed.
    pub fn set_active_texturepack(self: *Options, path: []const u8) void {
        const len: u8 = @intCast(@min(path.len, max_pack_path - 1));
        @memcpy(self.active_texturepack_buf[0..len], path[0..len]);
        self.active_texturepack_len = len;
    }
};

/// Effective render distance, capped to the platform's compiled-in maximum.
/// Desktop = 8 chunks; PSP slim = 4; PSP phat = 3.
/// Always use this instead of `current.render_distance` directly so we
/// never ask the renderer to load more sections than its arrays can hold.
pub fn capped_render_distance() u8 {
    const max: u8 = @intCast(@min(@as(u32, 255), cfg.current.chunk_radius));
    return @min(current.render_distance, max);
}

// -- JSON shadow type --------------------------------------------------------
// Field names match the JSON keys.  `active_texturepack` is a `[]const u8`
// so the JSON parser can allocate it into the per-call arena; the caller
// copies the value into the fixed buffer before the arena is freed.

const JsonOptions = struct {
    active_texturepack: []const u8 = "",
    render_distance: u8 = 8,
    sound_volume: f32 = 1.0,
    music_volume: f32 = 0.5,
    fov: f32 = 70.0,
    fancy_leaves: bool = true,
    sensitivity: f32 = 3.0,
    ambient_occlusion: bool = true,
};

// -- public API --------------------------------------------------------------

/// Load options from `options.json` in `dir`.  Falls back to defaults when
/// the file does not exist or cannot be parsed.
pub fn load(io: Io, dir: Io.Dir) void {
    const file = dir.openFile(io, options_file, .{}) catch return;
    defer file.close(io);

    var json_buf: [max_json_size]u8 = undefined;
    var reader_scratch: [512]u8 = undefined;
    var file_reader = File.Reader.init(file, io, &reader_scratch);
    const n = file_reader.interface.readSliceShort(&json_buf) catch |err| {
        log.warn("read options.json failed: {}", .{err});
        return;
    };
    if (n == 0) return;

    // A tiny stack arena for the JSON parser.  The only heap allocation it
    // makes for JsonOptions is the `active_texturepack` string (≤255 bytes).
    var arena_buf: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&arena_buf);
    const parsed = std.json.parseFromSlice(
        JsonOptions,
        fba.allocator(),
        json_buf[0..n],
        .{ .ignore_unknown_fields = true },
    ) catch |err| {
        log.warn("parse options.json failed: {} -- using defaults", .{err});
        return;
    };
    defer parsed.deinit();

    const j = parsed.value;
    current.set_active_texturepack(j.active_texturepack);
    current.render_distance = j.render_distance;
    current.sound_volume = std.math.clamp(j.sound_volume, 0.0, 1.0);
    current.music_volume = std.math.clamp(j.music_volume, 0.0, 1.0);
    current.fov = std.math.clamp(j.fov, 10.0, 170.0);
    current.fancy_leaves = j.fancy_leaves;
    current.sensitivity = std.math.clamp(j.sensitivity, 0.1, 20.0);
    current.ambient_occlusion = j.ambient_occlusion;
}

/// Write current options to `options.json` in `dir`.
/// On non-PSP targets the write goes through an atomic temp-file replace so a
/// crash mid-write never leaves a truncated file.  On PSP, `dirCreateFileAtomic`
/// is unimplemented in the pspsdk Io vtable; fall back to a direct `createFile`
/// write instead.  options.json is ~300 bytes, so load()'s parse-error fallback
/// to defaults is sufficient protection against the negligible partial-write risk.
pub fn save(io: Io, dir: Io.Dir) void {
    const j = JsonOptions{
        .active_texturepack = current.active_texturepack(),
        .render_distance = current.render_distance,
        .sound_volume = current.sound_volume,
        .music_volume = current.music_volume,
        .fov = current.fov,
        .fancy_leaves = current.fancy_leaves,
        .sensitivity = current.sensitivity,
        .ambient_occlusion = current.ambient_occlusion,
    };

    var json_buf: [max_json_size]u8 = undefined;
    var out = std.Io.Writer.fixed(&json_buf);
    std.json.Stringify.value(j, .{ .whitespace = .indent_2 }, &out) catch |err| {
        log.err("serialize options failed: {}", .{err});
        return;
    };
    const slice = out.buffered();

    if (comptime @import("aether").platform == .psp) {
        const file = dir.createFile(io, options_file, .{}) catch |err| {
            log.err("create options.json failed: {}", .{err});
            return;
        };
        defer file.close(io);
        file.writeStreamingAll(io, slice) catch |err| {
            log.err("write options.json failed: {}", .{err});
        };
        return;
    }

    var atomic = dir.createFileAtomic(io, options_file, .{ .replace = true }) catch |err| {
        log.err("create options.json failed: {}", .{err});
        return;
    };
    defer atomic.deinit(io);

    atomic.file.writeStreamingAll(io, slice) catch |err| {
        log.err("write options.json failed: {}", .{err});
        return;
    };
    atomic.replace(io) catch |err| {
        log.err("finalize options.json failed: {}", .{err});
    };
}
