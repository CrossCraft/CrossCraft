//! Persisted user preferences.

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
const max_json_size: usize = 4096;

pub const SENS_MIN: f32 = 0.1;
pub const SENS_MAX: f32 = 10.0;

pub var current: Options = .{};

/// Consoles accept only `auto` and `off`; unsupported styles reset on load.
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
    /// Relative to the data directory; empty selects the built-in pack.
    active_texturepack_buf: [max_pack_path]u8 = [_]u8{0} ** max_pack_path,
    active_texturepack_len: u8 = 0,

    /// Consumers must use `capped_render_distance` to honor the runtime profile.
    render_distance: u8 = if (ae.platform == .psp) 4 else 8,

    sound_volume: f32 = 1.0,

    music_volume: f32 = 0.5,

    fov: f32 = 70.0,

    /// Profiles with no near-LOD radius cannot render fancy leaves.
    fancy_leaves: bool = ae.platform != .psp,

    sensitivity: f32 = 3.0,

    ambient_occlusion: bool = false,

    /// Animate only a section's first mesh build.
    bouncy_chunks: bool = false,

    vsync: bool = ae.platform != .psp and ae.platform != .nintendo_3ds,

    controller_tooltips: ControllerTooltips = .auto,

    rain: bool = false,

    /// The sky retains its own fog when world fog is disabled.
    fog: bool = true,

    key_forward: input.Key = .W,
    key_back: input.Key = .S,
    key_left: input.Key = .A,
    key_right: input.Key = .D,
    key_inventory: input.Key = .B,

    psp_analog_mode: PspAnalogMode = .look,
    psp_jump_mode: PspJumpMode = .up,

    new_3ds_use_old_controls: bool = false,

    pub fn active_texturepack(self: *const Options) []const u8 {
        return self.active_texturepack_buf[0..self.active_texturepack_len];
    }

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

    pub fn reset_new_3ds_controls(self: *Options) void {
        self.new_3ds_use_old_controls = false;
        self.reset_psp_controls();
    }
};

/// Cap render distance to the renderer's allocated section capacity.
pub fn capped_render_distance() u8 {
    const max: u8 = @intCast(@min(@as(u32, 255), cfg.current().chunk_radius));
    return @min(current.render_distance, max);
}

/// A zero near-LOD radius forces opaque leaves on constrained profiles.
pub fn fancy_leaves_supported() bool {
    return cfg.current().lod_near_radius_blocks > 0;
}

pub fn fixed_controller_glyph_style() bool {
    return ae.platform == .psp or ae.platform == .nintendo_3ds or ae.platform == .nintendo_switch;
}

pub fn uses_old_3ds_controls() bool {
    return uses_old_3ds_controls_for(ae.platform, cfg.current().hardware, current.new_3ds_use_old_controls);
}

pub fn controls_rebinding_supported() bool {
    return controls_rebinding_supported_for(ae.platform, cfg.current().hardware);
}

fn controls_rebinding_supported_for(platform: ae.Platform, hardware: cfg.HardwareClass) bool {
    return switch (platform) {
        .nintendo_3ds => hardware == .old_3ds or hardware == .new_3ds,
        .nintendo_switch => false,
        else => true,
    };
}

pub fn new_3ds_old_controls_supported() bool {
    return new_3ds_old_controls_supported_for(ae.platform, cfg.current().hardware);
}

fn new_3ds_old_controls_supported_for(platform: ae.Platform, hardware: cfg.HardwareClass) bool {
    return platform == .nintendo_3ds and hardware == .new_3ds;
}

fn uses_old_3ds_controls_for(platform: ae.Platform, hardware: cfg.HardwareClass, new_3ds_use_old_controls: bool) bool {
    return platform == .nintendo_3ds and (hardware == .old_3ds or (hardware == .new_3ds and new_3ds_use_old_controls));
}

test "Old 3DS controls follow the runtime hardware class and N3DS fallback" {
    try std.testing.expect(!uses_old_3ds_controls_for(.psp, .psp_phat, false));
    try std.testing.expect(!uses_old_3ds_controls_for(.psp, .psp_phat, true));
    try std.testing.expect(uses_old_3ds_controls_for(.nintendo_3ds, .old_3ds, false));
    try std.testing.expect(uses_old_3ds_controls_for(.nintendo_3ds, .old_3ds, true));
    try std.testing.expect(!uses_old_3ds_controls_for(.nintendo_3ds, .new_3ds, false));
    try std.testing.expect(uses_old_3ds_controls_for(.nintendo_3ds, .new_3ds, true));
    try std.testing.expect(!uses_old_3ds_controls_for(.nintendo_switch, .nintendo_switch, true));
    try std.testing.expect(!uses_old_3ds_controls_for(.linux, .desktop, true));

    try std.testing.expect(!new_3ds_old_controls_supported_for(.psp, .psp_phat));
    try std.testing.expect(!new_3ds_old_controls_supported_for(.nintendo_3ds, .old_3ds));
    try std.testing.expect(new_3ds_old_controls_supported_for(.nintendo_3ds, .new_3ds));
    try std.testing.expect(!new_3ds_old_controls_supported_for(.nintendo_switch, .nintendo_switch));

    try std.testing.expect(controls_rebinding_supported_for(.psp, .psp_phat));
    try std.testing.expect(controls_rebinding_supported_for(.nintendo_3ds, .old_3ds));
    try std.testing.expect(controls_rebinding_supported_for(.nintendo_3ds, .new_3ds));
    try std.testing.expect(!controls_rebinding_supported_for(.nintendo_switch, .nintendo_switch));
    try std.testing.expect(controls_rebinding_supported_for(.linux, .desktop));
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

const JsonNumber = struct {
    value: f64 = 0.0,

    fn from_int(value: i64) JsonNumber {
        return .{ .value = @as(f64, @floatFromInt(value)) };
    }

    pub const jsonParse = json_parse;

    fn json_parse(
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

    pub const jsonParseFromValue = json_parse_from_value;

    fn json_parse_from_value(
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
    new_3ds_use_old_controls: bool = false,
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
    new_3ds_use_old_controls: bool,
};

/// Invalid or missing files leave defaults intact.
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
        json_percent_to_unit(j.sound_volume orelse JsonNumber.from_int(100))
    else
        json_float_f32(j.sound_volume orelse .{ .value = 1.0 }, 0.0, 1.0);
    current.music_volume = if (integer_json)
        json_percent_to_unit(j.music_volume orelse JsonNumber.from_int(50))
    else
        json_float_f32(j.music_volume orelse .{ .value = 0.5 }, 0.0, 1.0);
    current.fov = if (integer_json)
        json_rounded_f32(j.fov orelse JsonNumber.from_int(70), 10.0, 170.0)
    else
        json_float_f32(j.fov orelse .{ .value = 70.0 }, 10.0, 170.0);
    current.fancy_leaves = j.fancy_leaves and fancy_leaves_supported();
    current.sensitivity = if (integer_json)
        sensitivity_from_percent(json_percent(j.sensitivity orelse JsonNumber.from_int(sensitivity_percent(3.0))))
    else
        json_float_f32(j.sensitivity orelse .{ .value = 3.0 }, SENS_MIN, 20.0);
    current.ambient_occlusion = j.ambient_occlusion;
    current.bouncy_chunks = j.bouncy_chunks;
    current.vsync = j.vsync;
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
    current.new_3ds_use_old_controls = j.new_3ds_use_old_controls;
}

/// PSP lacks atomic replacement; torn writes fall back to defaults on load.
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
        .vsync = current.vsync,
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
        .new_3ds_use_old_controls = current.new_3ds_use_old_controls,
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
    inline for (std.meta.fields(PcControl)) |control| {
        const field = "key_" ++ control.name;
        @field(current, field) = std.meta.stringToEnum(input.Key, @field(j, field)) orelse {
            current.reset_pc_controls();
            return;
        };
    }
    if (!pc_controls_valid(&current)) current.reset_pc_controls();
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

test "invalid saved controls reset all bindings" {
    const previous = current;
    defer current = previous;

    current = .{ .fov = 90 };
    const valid: LoadJsonOptions = .{ .key_forward = "Up", .key_back = "Down", .key_inventory = "I" };
    load_pc_controls(valid);
    try std.testing.expectEqual(input.Key.Up, current.key_forward);
    try std.testing.expectEqual(input.Key.Down, current.key_back);
    try std.testing.expectEqual(input.Key.I, current.key_inventory);

    for ([_][]const u8{ "Up", "Escape", "not-a-key" }) |invalid| {
        var saved = valid;
        saved.key_inventory = invalid;
        load_pc_controls(saved);
        inline for (std.meta.fields(PcControl)) |control| {
            const field = "key_" ++ control.name;
            try std.testing.expectEqual(@field(Options{}, field), @field(current, field));
        }
        try std.testing.expectEqual(@as(f32, 90), current.fov);
    }
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
    try std.testing.expect(!legacy.value.new_3ds_use_old_controls);

    const integer_json =
        \\{"version":2,"sound_volume":100,"music_volume":50,"fov":71,"sensitivity":65,"new_3ds_use_old_controls":true}
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
    try std.testing.expect(integer.value.new_3ds_use_old_controls);
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
        .new_3ds_use_old_controls = false,
    };

    var json_buf: [512]u8 = undefined;
    var out = std.Io.Writer.fixed(&json_buf);
    try std.json.Stringify.value(j, .{}, &out);
    const written = out.buffered();

    try std.testing.expect(std.mem.indexOf(u8, written, "\"version\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"sound_volume\":100") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"music_volume\":50") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"fov\":71") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"new_3ds_use_old_controls\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, ".") == null);
}
