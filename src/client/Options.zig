//! Persisted user preferences.
//!
//! `Options.current` is the live singleton.  Call `load` on startup and
//! `save` whenever settings change.  Both operate on `options.json` in the
//! application data directory (`engine.dirs.data`).

const std = @import("std");
const builtin = @import("builtin");
const ae = @import("aether");
const Io = std.Io;
const File = std.Io.File;
const cfg = @import("config.zig");
const input = ae.Core.input;

const log = std.log.scoped(.options);

const options_file = "options.json";
const json_format_version: u8 = 2;
const max_pack_path: usize = 256;
/// Generous upper bound for the JSON file (typical size ~300 bytes).
const max_json_size: usize = 4096;

pub const SENS_MIN: f32 = 0.1;
pub const SENS_MAX: f32 = 10.0;

/// Live singleton.  Any system may read `Options.current`; only `load` and
/// the settings UI should write it.
pub var current: Options = .{};

/// In-game controller prompt style.  PSP and Nintendo consoles only support
/// `auto` / `off`; the other layouts are desktop-only and are corrected to
/// `auto` on load.
pub const ControllerTooltips = enum(u8) {
    auto = 0,
    xbox = 1,
    playstation = 2,
    nintendo = 3,
    off = 4,

    pub fn platform_supports(self: ControllerTooltips) bool {
        if (comptime fixed_controller_glyph_style()) {
            return self == .auto or self == .off;
        }
        return true;
    }
};

pub const PcControl = enum(u8) {
    forward,
    back,
    left,
    right,
    inventory,
};

pub const PspAnalogMode = enum(u8) {
    move = 0,
    look = 1,
};

pub const PspJumpMode = enum(u8) {
    select = 0,
    up = 1,
};

pub const Options = struct {
    /// Path of the active texture pack (relative to the data dir).
    /// Empty string means use the built-in default pack.
    active_texturepack_buf: [max_pack_path]u8 = [_]u8{0} ** max_pack_path,
    active_texturepack_len: u8 = 0,

    /// Chunk render radius. PSP defaults to 4; desktop defaults to 8.
    /// Capped to the active runtime profile via `capped_render_distance`.
    render_distance: u8 = if (@import("aether").platform == .psp)
        4
    else
        8,

    /// SFX volume multiplier (0.0 = silent, 1.0 = full).
    sound_volume: f32 = 1.0,

    /// Music volume multiplier (0.0 = silent, 1.0 = full).
    music_volume: f32 = 0.5,

    /// Vertical field of view in degrees.
    fov: f32 = 70.0,

    /// True = full leaf transparency (fancy); false = opaque leaves (fast).
    /// Defaults off on PSP to keep meshing within budget.  Profiles with
    /// `lod_near_radius_blocks == 0` cannot render fancy leaves at all.
    fancy_leaves: bool = @import("aether").platform != .psp,

    /// Mouse / analogue-stick look sensitivity multiplier.
    sensitivity: f32 = 3.0,

    /// Smooth ambient occlusion on block faces.
    ambient_occlusion: bool = false,

    /// Newly-meshed chunk sections rise from -16 blocks over 1 second.
    /// Rebuilt sections are unaffected.
    bouncy_chunks: bool = false,

    /// Cap frames to the display refresh rate.  Applied via
    /// `engine.set_vsync` on load and whenever the options menu is dismissed.
    /// PSP defaults to off; the 60 Hz cap costs more than it's worth given the
    /// platform's frame-time budget.
    vsync: bool = @import("aether").platform != .psp and @import("aether").platform != .nintendo_3ds,

    /// In-game controller prompt style.  `auto` picks glyphs from the
    /// connected controller on desktop, or the fixed platform layout on
    /// PSP / Nintendo consoles.
    controller_tooltips: ControllerTooltips = .auto,

    /// Weather: rain on/off.  Defaults off on every platform.
    rain: bool = false,

    /// Distance fog for world geometry.  The sky renderer keeps its own fog
    /// enabled so the horizon retains the intended look when this is off.
    fog: bool = true,

    /// Desktop keyboard controls. Gamepad bindings remain fixed.
    key_forward: input.Key = .W,
    key_back: input.Key = .S,
    key_left: input.Key = .A,
    key_right: input.Key = .D,
    key_inventory: input.Key = .B,

    /// PSP compact control swaps.
    psp_analog_mode: PspAnalogMode = .look,
    psp_jump_mode: PspJumpMode = .up,

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

    pub fn pc_key(self: *const Options, control: PcControl) input.Key {
        return switch (control) {
            .forward => self.key_forward,
            .back => self.key_back,
            .left => self.key_left,
            .right => self.key_right,
            .inventory => self.key_inventory,
        };
    }

    pub fn set_pc_key(self: *Options, control: PcControl, key: input.Key) bool {
        if (!pc_key_assignable(key)) return false;
        inline for (std.meta.fields(PcControl)) |field| {
            const other: PcControl = @enumFromInt(field.value);
            if (other != control and self.pc_key(other) == key) return false;
        }
        switch (control) {
            .forward => self.key_forward = key,
            .back => self.key_back = key,
            .left => self.key_left = key,
            .right => self.key_right = key,
            .inventory => self.key_inventory = key,
        }
        return true;
    }

    pub fn reset_pc_controls(self: *Options) void {
        self.key_forward = .W;
        self.key_back = .S;
        self.key_left = .A;
        self.key_right = .D;
        self.key_inventory = .B;
    }

    pub fn reset_psp_controls(self: *Options) void {
        self.psp_analog_mode = .look;
        self.psp_jump_mode = .up;
    }
};

/// Effective render distance, capped to the active runtime profile.
/// Always use this instead of `current.render_distance` directly so we
/// never ask the renderer to load more sections than its arrays can hold.
pub fn capped_render_distance() u8 {
    const max: u8 = @intCast(@min(@as(u32, 255), cfg.current().chunk_radius));
    return @min(current.render_distance, max);
}

/// True when the build can render fancy (transparent) leaves at all.
/// PSP-1000 forces opaque leaves via `lod_near_radius_blocks = 0`; this
/// helper centralises the detection so the UI and load path agree.
pub fn fancy_leaves_supported() bool {
    return cfg.current().lod_near_radius_blocks > 0;
}

/// True when VSync can be changed by the options UI.
pub fn vsync_toggle_supported() bool {
    return true;
}

pub fn effective_vsync(vsync: bool) bool {
    return if (vsync_toggle_supported()) vsync else true;
}

/// True when the platform has one built-in controller glyph family.
/// The options menu treats this as an on/off choice.
pub fn fixed_controller_glyph_style() bool {
    return ae.platform == .psp or ae.platform == .nintendo_3ds or ae.platform == .nintendo_switch;
}

/// True when the controls screen can edit bindings on this platform.
/// Nintendo console bindings are fixed for now.
pub fn controls_rebinding_supported() bool {
    return ae.platform != .nintendo_3ds and ae.platform != .nintendo_switch;
}

pub fn pc_key_assignable(key: input.Key) bool {
    switch (key) {
        .Escape,
        .T,
        .Slash,
        .Space,
        .LeftShift,
        .Tab,
        .Num1,
        .Num2,
        .Num3,
        .Num4,
        .Num5,
        .Num6,
        .Num7,
        .Num8,
        .Num9,
        => return false,
        else => {},
    }

    if (ae.platform != .psp) {
        switch (key) {
            .F1,
            .F5,
            => return false,
            else => {},
        }
        if (builtin.mode == .Debug and key == .X) return false;
    }

    return true;
}

pub fn pc_key_label(key: input.Key) []const u8 {
    return switch (key) {
        .Space => "Space",
        .LeftShift => "Left Shift",
        .RightShift => "Right Shift",
        .LeftControl => "Left Ctrl",
        .RightControl => "Right Ctrl",
        .LeftAlt => "Left Alt",
        .RightAlt => "Right Alt",
        .LeftSuper => "Left Super",
        .RightSuper => "Right Super",
        .KpEnter => "Keypad Enter",
        .KpDecimal => "Keypad Decimal",
        .KpDivide => "Keypad Divide",
        .KpMultiply => "Keypad Multiply",
        .KpSubtract => "Keypad Minus",
        .KpAdd => "Keypad Plus",
        .KpEqual => "Keypad Equal",
        else => @tagName(key),
    };
}

pub fn pc_key_prompt_label(key: input.Key) []const u8 {
    return switch (key) {
        .Space => "SPC",
        .LeftShift => "LSH",
        .RightShift => "RSH",
        .LeftControl => "LCT",
        .RightControl => "RCT",
        .LeftAlt => "ALT",
        .RightAlt => "ALT",
        .Tab => "TAB",
        .Backspace => "BSP",
        .Enter => "ENT",
        else => @tagName(key),
    };
}

pub fn sensitivity_percent(v: f32) u32 {
    const cl = std.math.clamp(v, SENS_MIN, SENS_MAX);
    const lmin = std.math.log10(SENS_MIN);
    const lmax = std.math.log10(SENS_MAX);
    return @intFromFloat(@round((std.math.log10(cl) - lmin) / (lmax - lmin) * 100));
}

pub fn sensitivity_from_percent(percent: u32) f32 {
    const pct = @as(f32, @floatFromInt(@min(percent, 100))) / 100.0;
    const lmin = std.math.log10(SENS_MIN);
    const lmax = std.math.log10(SENS_MAX);
    return std.math.pow(f32, 10.0, lmin + (lmax - lmin) * pct);
}

// --- JSON shadow types ---
// Field names match the JSON keys.  `active_texturepack` is a `[]const u8`
// so the JSON parser can allocate it into the per-call arena; the caller
// copies the value into the fixed buffer before the arena is freed.

const JsonNumber = struct {
    value: f64 = 0.0,

    fn fromInt(value: i64) JsonNumber {
        return .{ .value = @as(f64, @floatFromInt(value)) };
    }

    pub fn jsonParse(
        allocator: std.mem.Allocator,
        source: anytype,
        options: std.json.ParseOptions,
    ) std.json.ParseError(@TypeOf(source.*))!JsonNumber {
        const token = try source.nextAllocMax(allocator, .alloc_if_needed, options.max_value_len.?);
        const slice = switch (token) {
            inline .number, .allocated_number, .string, .allocated_string => |s| s,
            else => return error.UnexpectedToken,
        };
        const value = try std.fmt.parseFloat(f64, slice);
        if (!std.math.isFinite(value)) return error.InvalidNumber;
        return .{ .value = value };
    }

    pub fn jsonParseFromValue(
        allocator: std.mem.Allocator,
        source: std.json.Value,
        options: std.json.ParseOptions,
    ) std.json.ParseFromValueError!JsonNumber {
        _ = allocator;
        _ = options;
        const value = switch (source) {
            .integer => |i| @as(f64, @floatFromInt(i)),
            .float => |f| f,
            .number_string, .string => |s| try std.fmt.parseFloat(f64, s),
            else => return error.UnexpectedToken,
        };
        if (!std.math.isFinite(value)) return error.InvalidNumber;
        return .{ .value = value };
    }
};

const LoadJsonOptions = struct {
    /// Version 1 stored runtime float units/multipliers. Version 2 stores
    /// integer menu values in the same keys: volume and sensitivity percent,
    /// and FOV degrees.
    version: u8 = 1,
    active_texturepack: []const u8 = "",
    render_distance: u8 = if (@import("aether").platform == .psp) 4 else 8,
    sound_volume: ?JsonNumber = null,
    music_volume: ?JsonNumber = null,
    fov: ?JsonNumber = null,
    fancy_leaves: bool = @import("aether").platform != .psp,
    sensitivity: ?JsonNumber = null,
    ambient_occlusion: bool = false,
    bouncy_chunks: bool = false,
    vsync: bool = @import("aether").platform != .psp,
    controller_tooltips: u8 = 0,
    rain: bool = false,
    fog: bool = true,
    key_forward: []const u8 = "W",
    key_back: []const u8 = "S",
    key_left: []const u8 = "A",
    key_right: []const u8 = "D",
    key_inventory: []const u8 = "B",
    psp_analog_mode: u8 = @intFromEnum(PspAnalogMode.look),
    psp_jump_mode: u8 = @intFromEnum(PspJumpMode.up),
};

const SaveJsonOptions = struct {
    version: u8 = json_format_version,
    active_texturepack: []const u8 = "",
    render_distance: u8,
    sound_volume: u8,
    music_volume: u8,
    fov: u16,
    fancy_leaves: bool,
    sensitivity: u8,
    ambient_occlusion: bool,
    bouncy_chunks: bool,
    vsync: bool,
    controller_tooltips: u8,
    rain: bool,
    fog: bool,
    key_forward: []const u8,
    key_back: []const u8,
    key_left: []const u8,
    key_right: []const u8,
    key_inventory: []const u8,
    psp_analog_mode: u8,
    psp_jump_mode: u8,
};

// --- public API ---

/// Load options from `options.json` in `dir`.  Falls back to defaults when
/// the file does not exist or cannot be parsed.
pub fn load(io: Io, dir: std.Io.Dir) void {
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

    // A tiny stack arena for the JSON parser.  The heap allocations it makes
    // for JsonOptions are the small string fields.
    var arena_buf: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&arena_buf);
    const parsed = std.json.parseFromSlice(
        LoadJsonOptions,
        fba.allocator(),
        json_buf[0..n],
        .{ .ignore_unknown_fields = true },
    ) catch |err| {
        log.warn("parse options.json failed: {} -- using defaults", .{err});
        return;
    };
    defer parsed.deinit();

    const j = parsed.value;
    const integer_json = j.version >= 2;
    current.set_active_texturepack(j.active_texturepack);
    current.render_distance = j.render_distance;
    current.sound_volume = if (integer_json)
        json_percent_to_unit(j.sound_volume orelse JsonNumber.fromInt(100))
    else
        json_float_f32(j.sound_volume orelse .{ .value = 1.0 }, 0.0, 1.0);
    current.music_volume = if (integer_json)
        json_percent_to_unit(j.music_volume orelse JsonNumber.fromInt(50))
    else
        json_float_f32(j.music_volume orelse .{ .value = 0.5 }, 0.0, 1.0);
    current.fov = if (integer_json)
        json_rounded_f32(j.fov orelse JsonNumber.fromInt(70), 10.0, 170.0)
    else
        json_float_f32(j.fov orelse .{ .value = 70.0 }, 10.0, 170.0);
    current.fancy_leaves = j.fancy_leaves and fancy_leaves_supported();
    current.sensitivity = if (integer_json)
        sensitivity_from_percent(json_percent(j.sensitivity orelse JsonNumber.fromInt(sensitivity_percent(3.0))))
    else
        json_float_f32(j.sensitivity orelse .{ .value = 3.0 }, SENS_MIN, 20.0);
    current.ambient_occlusion = j.ambient_occlusion;
    current.bouncy_chunks = j.bouncy_chunks;
    current.vsync = effective_vsync(j.vsync);
    current.controller_tooltips = blk: {
        const mode: ControllerTooltips = switch (j.controller_tooltips) {
            0 => .auto,
            1 => .xbox,
            2 => .playstation,
            3 => .nintendo,
            4 => .off,
            else => break :blk .auto,
        };
        if (!mode.platform_supports()) break :blk .auto;
        break :blk mode;
    };
    current.rain = j.rain;
    current.fog = j.fog;
    load_pc_controls(j);
    current.psp_analog_mode = switch (j.psp_analog_mode) {
        0 => .move,
        1 => .look,
        else => .look,
    };
    current.psp_jump_mode = switch (j.psp_jump_mode) {
        0 => .select,
        1 => .up,
        else => .up,
    };
}

/// Write current options to `options.json` in `dir`.
/// Uses a direct `createFile` on every platform.  Atomic temp-file replace
/// is unimplemented on PSP and the partial-write risk is negligible here:
/// options.json is ~300 bytes, and `load`'s parse-error fallback to
/// defaults already covers a torn write.
pub fn save(io: Io, dir: std.Io.Dir) void {
    const j = SaveJsonOptions{
        .active_texturepack = current.active_texturepack(),
        .render_distance = current.render_distance,
        .sound_volume = unit_to_json_percent(current.sound_volume),
        .music_volume = unit_to_json_percent(current.music_volume),
        .fov = float_to_json_int(current.fov),
        .fancy_leaves = current.fancy_leaves,
        .sensitivity = @intCast(sensitivity_percent(current.sensitivity)),
        .ambient_occlusion = current.ambient_occlusion,
        .bouncy_chunks = current.bouncy_chunks,
        .vsync = effective_vsync(current.vsync),
        .controller_tooltips = @intFromEnum(current.controller_tooltips),
        .rain = current.rain,
        .fog = current.fog,
        .key_forward = @tagName(current.key_forward),
        .key_back = @tagName(current.key_back),
        .key_left = @tagName(current.key_left),
        .key_right = @tagName(current.key_right),
        .key_inventory = @tagName(current.key_inventory),
        .psp_analog_mode = @intFromEnum(current.psp_analog_mode),
        .psp_jump_mode = @intFromEnum(current.psp_jump_mode),
    };

    var json_buf: [max_json_size]u8 = undefined;
    var out = std.Io.Writer.fixed(&json_buf);
    std.json.Stringify.value(j, .{ .whitespace = .indent_2 }, &out) catch |err| {
        log.err("serialize options failed: {}", .{err});
        return;
    };
    const slice = out.buffered();

    const file = dir.createFile(io, options_file, .{}) catch |err| {
        log.err("create options.json failed: {}", .{err});
        return;
    };
    defer file.close(io);
    file.writeStreamingAll(io, slice) catch |err| {
        log.err("write options.json failed: {}", .{err});
    };
}

fn json_float_f32(n: JsonNumber, min: f32, max: f32) f32 {
    return std.math.clamp(@as(f32, @floatCast(n.value)), min, max);
}

fn json_rounded_f32(n: JsonNumber, min: f32, max: f32) f32 {
    return std.math.clamp(@as(f32, @floatCast(@round(n.value))), min, max);
}

fn json_percent(n: JsonNumber) u32 {
    const clamped = std.math.clamp(@round(n.value), 0.0, 100.0);
    return @intFromFloat(clamped);
}

fn json_percent_to_unit(n: JsonNumber) f32 {
    return @as(f32, @floatFromInt(json_percent(n))) / 100.0;
}

fn unit_to_json_percent(v: f32) u8 {
    return @intFromFloat(@round(std.math.clamp(v, 0.0, 1.0) * 100.0));
}

fn float_to_json_int(v: f32) u16 {
    return @intFromFloat(@round(v));
}

fn load_pc_controls(j: LoadJsonOptions) void {
    var invalid = false;
    const forward = parse_key(j.key_forward) orelse blk: {
        invalid = true;
        break :blk input.Key.W;
    };
    const back = parse_key(j.key_back) orelse blk: {
        invalid = true;
        break :blk input.Key.S;
    };
    const left = parse_key(j.key_left) orelse blk: {
        invalid = true;
        break :blk input.Key.A;
    };
    const right = parse_key(j.key_right) orelse blk: {
        invalid = true;
        break :blk input.Key.D;
    };
    const inventory = parse_key(j.key_inventory) orelse blk: {
        invalid = true;
        break :blk input.Key.B;
    };

    current.key_forward = forward;
    current.key_back = back;
    current.key_left = left;
    current.key_right = right;
    current.key_inventory = inventory;
    if (invalid or !pc_controls_valid(&current)) current.reset_pc_controls();
}

fn parse_key(name: []const u8) ?input.Key {
    return std.meta.stringToEnum(input.Key, name);
}

fn pc_controls_valid(opt: *const Options) bool {
    const keys = [_]input.Key{
        opt.key_forward,
        opt.key_back,
        opt.key_left,
        opt.key_right,
        opt.key_inventory,
    };
    for (keys, 0..) |key, i| {
        if (!pc_key_assignable(key)) return false;
        for (keys[i + 1 ..]) |other| {
            if (key == other) return false;
        }
    }
    return true;
}

test "versioned options json accepts legacy floats and new integer values" {
    const legacy_json =
        \\{"sound_volume":1,"music_volume":0.5,"fov":70.5,"sensitivity":3}
    ;
    const legacy = try std.json.parseFromSlice(
        LoadJsonOptions,
        std.testing.allocator,
        legacy_json,
        .{ .ignore_unknown_fields = true },
    );
    defer legacy.deinit();
    try std.testing.expectEqual(@as(u8, 1), legacy.value.version);
    try std.testing.expectEqual(@as(f32, 1.0), json_float_f32(legacy.value.sound_volume.?, 0.0, 1.0));
    try std.testing.expectEqual(@as(f32, 0.5), json_float_f32(legacy.value.music_volume.?, 0.0, 1.0));
    try std.testing.expectEqual(@as(f32, 70.5), json_float_f32(legacy.value.fov.?, 10.0, 170.0));
    try std.testing.expectEqual(@as(f32, 3.0), json_float_f32(legacy.value.sensitivity.?, SENS_MIN, 20.0));

    const integer_json =
        \\{"version":2,"sound_volume":100,"music_volume":50,"fov":71,"sensitivity":65}
    ;
    const integer = try std.json.parseFromSlice(
        LoadJsonOptions,
        std.testing.allocator,
        integer_json,
        .{ .ignore_unknown_fields = true },
    );
    defer integer.deinit();
    try std.testing.expectEqual(@as(u8, 2), integer.value.version);
    try std.testing.expectEqual(@as(f32, 1.0), json_percent_to_unit(integer.value.sound_volume.?));
    try std.testing.expectEqual(@as(f32, 0.5), json_percent_to_unit(integer.value.music_volume.?));
    try std.testing.expectEqual(@as(f32, 71.0), json_rounded_f32(integer.value.fov.?, 10.0, 170.0));
    try std.testing.expectApproxEqAbs(sensitivity_from_percent(65), sensitivity_from_percent(json_percent(integer.value.sensitivity.?)), 0.0001);
}

test "current options json writes menu numbers as integers" {
    const j = SaveJsonOptions{
        .sound_volume = unit_to_json_percent(1.0),
        .music_volume = unit_to_json_percent(0.5),
        .fov = float_to_json_int(70.5),
        .sensitivity = @intCast(sensitivity_percent(3.0)),
        .render_distance = 8,
        .fancy_leaves = true,
        .ambient_occlusion = false,
        .bouncy_chunks = false,
        .vsync = true,
        .controller_tooltips = 0,
        .rain = false,
        .fog = true,
        .key_forward = "W",
        .key_back = "S",
        .key_left = "A",
        .key_right = "D",
        .key_inventory = "B",
        .psp_analog_mode = @intFromEnum(PspAnalogMode.look),
        .psp_jump_mode = @intFromEnum(PspJumpMode.up),
    };

    var json_buf: [512]u8 = undefined;
    var out = std.Io.Writer.fixed(&json_buf);
    try std.json.Stringify.value(j, .{}, &out);
    const written = out.buffered();

    try std.testing.expect(std.mem.indexOf(u8, written, "\"version\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"sound_volume\":100") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"music_volume\":50") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"fov\":71") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, ".") == null);
}
