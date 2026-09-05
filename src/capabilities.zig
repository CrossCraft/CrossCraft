//! CrossCraft target capabilities and policy. Keep target identity checks here.
//! Core and host tools use the std-only declarations. ClientType(ae) adds engine
//! capabilities without making Core depend on Aether. Runtime hardware probes
//! select a memory/input profile before the client allocates its pools.
const std = @import("std");
const builtin = @import("builtin");

pub const math = struct {
    // Avoid compiler_rt floor/ceil calls on MIPS for finite worldgen values.
    pub const integer_float_rounding = builtin.cpu.arch == .mipsel or builtin.cpu.arch == .mips;
};

pub const process = struct {
    pub const console_control_handler = builtin.os.tag == .windows;
};

/// Evaluated for the build host when imported by the resource pack tool.
pub const resource_pack = struct {
    pub const windows_paths = builtin.os.tag == .windows;
};

const MB: u32 = 1024 * 1024;
const KB: u32 = 1024;
const NINTENDO_3DS_TOTAL_MEMORY_MB: u32 = 32;
const SWITCH_TOTAL_MEMORY_MB: u32 = 224;

pub const HardwareClass = enum {
    desktop,
    psp_phat,
    psp_slim,
    old_3ds,
    new_3ds,
    nintendo_switch,
};

pub const MemoryProfile = struct {
    hardware: HardwareClass,
    total_memory_mb: u32,
    chunk_radius: u32,
    lod_near_radius_blocks: u32,

    init_render: u32,
    init_audio: u32,
    init_game: u32,
    init_user: u32,

    rt_render: u32,
    rt_audio: u32,
    rt_game: u32,
    rt_user: u32,
};

const desktop_profile: MemoryProfile = .{
    .hardware = .desktop,
    .total_memory_mb = 480,
    .chunk_radius = 16,
    .lod_near_radius_blocks = 96,
    .init_render = 8 * MB,
    .init_audio = 2 * MB,
    .init_game = 2 * MB,
    .init_user = 72 * MB,
    .rt_render = 384 * MB,
    .rt_audio = 512 * KB,
    .rt_game = 512 * KB,
    .rt_user = 4 * MB + 512 * KB,
};

const psp_phat_profile: MemoryProfile = .{
    .hardware = .psp_phat,
    .total_memory_mb = 18,
    .chunk_radius = 4,
    .lod_near_radius_blocks = 0, // Always opaque leaves
    .init_render = 2 * MB,
    .init_audio = 1 * MB,
    .init_game = 1 * MB,
    .init_user = 12 * MB,
    .rt_render = 13 * MB + 512 * KB,
    .rt_audio = 0,
    .rt_game = 1 * MB,
    .rt_user = 4 * MB + 512 * KB,
};

const psp_slim_profile: MemoryProfile = .{
    .hardware = .psp_slim,
    .total_memory_mb = 36,
    .chunk_radius = 6,
    .lod_near_radius_blocks = 28,
    .init_render = 4 * MB,
    .init_audio = 2 * MB,
    .init_game = 2 * MB,
    .init_user = 12 * MB,
    .rt_render = 29 * MB + 768 * KB,
    .rt_audio = 0 * KB,
    .rt_game = 1 * MB,
    .rt_user = 4 * MB + 512 * KB,
};

const old_3ds_profile: MemoryProfile = .{
    .hardware = .old_3ds,
    .total_memory_mb = NINTENDO_3DS_TOTAL_MEMORY_MB,
    .chunk_radius = 4,
    .lod_near_radius_blocks = 28,
    .init_render = 4 * MB,
    .init_audio = 2 * MB,
    .init_game = 2 * MB,
    .init_user = 12 * MB,
    .rt_render = 26 * MB,
    .rt_audio = 512 * KB,
    .rt_game = 1 * MB,
    .rt_user = 4 * MB + 512 * KB,
};

const new_3ds_profile: MemoryProfile = blk: {
    var profile = old_3ds_profile;
    profile.hardware = .new_3ds;
    break :blk profile;
};

const nintendo_switch_profile: MemoryProfile = .{
    .hardware = .nintendo_switch,
    .total_memory_mb = SWITCH_TOTAL_MEMORY_MB,
    .chunk_radius = 12,
    .lod_near_radius_blocks = 40,
    .init_audio = desktop_profile.init_audio,
    .init_game = desktop_profile.init_game,
    .init_user = desktop_profile.init_user,
    .init_render = render_remainder(
        SWITCH_TOTAL_MEMORY_MB,
        desktop_profile.init_audio,
        desktop_profile.init_game,
        desktop_profile.init_user,
    ),
    .rt_audio = desktop_profile.rt_audio,
    .rt_game = desktop_profile.rt_game,
    .rt_user = desktop_profile.rt_user,
    .rt_render = render_remainder(
        SWITCH_TOTAL_MEMORY_MB,
        desktop_profile.rt_audio,
        desktop_profile.rt_game,
        desktop_profile.rt_user,
    ),
};

fn render_remainder(
    comptime total_memory_mb: u32,
    comptime audio: u32,
    comptime game: u32,
    comptime user: u32,
) u32 {
    const total = total_memory_mb * MB;
    const reserved = audio + game + user;
    if (reserved > total) @compileError("non-render memory pools exceed total memory");
    return total - reserved;
}

/// Instantiate with the client's engine module; SDK paths remain lazy so
/// std-only consumers and builds for other targets do not need console SDKs.
pub fn ClientType(comptime ae: type) type {
    return struct {
        pub const defaults = struct {
            pub const render_distance: u8 = if (ae.platform == .psp) 4 else 8;
            pub const fancy_leaves = ae.platform != .psp;
            pub const vsync = ae.platform != .psp and ae.platform != .nintendo_3ds;
            // Preserve the historical fallback for JSON files missing vsync.
            pub const loaded_vsync = ae.platform != .psp;
        };

        pub const audio = struct {
            pub const max_voices: u32 = if (ae.platform == .psp) 8 else 17;
        };

        pub const render = struct {
            pub const headless = ae.gfx == .headless;
            pub const rain_splashes_per_second: f32 = if (ae.platform == .psp) 150.0 else 500.0;
            pub const selection_protrusion: i32 = if (ae.platform == .psp) 240 else 80;
            pub const near_plane: f32 = if (ae.platform == .psp) 0.3275 else 0.1;
            pub const far_plane: f32 = if (ae.platform == .psp) 132.0 else 256.0;
            pub const hand_near_plane: f32 = if (ae.platform == .psp) 0.3 else near_plane;
            pub const hand_far_plane: f32 = if (ae.platform == .nintendo_3ds) far_plane else 128.0;
            // Compensate for the fixed-point vertex format's quantization.
            pub const opaque_chunk_scale: f32 = if (ae.platform == .psp) 16.0 * 32768.0 / 32753.0 else 16.0;
            pub const translucent_chunk_scale: f32 = if (ae.platform == .psp) 16.0 * 32768.0 / 32763.0 else 16.0;
            pub const present_paces_loading = ae.platform == .nintendo_3ds or ae.platform == .nintendo_switch;
        };

        pub const controls = struct {
            pub const single_stick = ae.platform == .psp;
            pub const shoulder_action_chords = ae.platform == .psp;
            pub const trigger_block_actions = ae.platform != .psp;
            pub const view_toggle_shortcuts = ae.platform != .psp;
            pub const debug_noclip = builtin.mode == .Debug and ae.platform != .psp;
            pub const linear_look = ae.platform == .nintendo_3ds;
            pub const look_deadzone: f32 = if (ae.platform == .nintendo_3ds) 0.0 else ae.Core.input.config.default_axis_deadzone;

            pub fn uses_single_stick_fallback(hardware: HardwareClass, fallback: bool) bool {
                return ae.platform == .nintendo_3ds and
                    (hardware == .old_3ds or (hardware == .new_3ds and fallback));
            }

            pub fn supports_rebinding(hardware: HardwareClass) bool {
                return switch (ae.platform) {
                    .nintendo_3ds => hardware == .old_3ds or hardware == .new_3ds,
                    .nintendo_switch => false,
                    else => true,
                };
            }

            pub fn supports_single_stick_fallback(hardware: HardwareClass) bool {
                return ae.platform == .nintendo_3ds and hardware == .new_3ds;
            }
        };

        pub const ui = struct {
            pub const pointer = ae.gfx != .headless and ae.platform != .psp and ae.platform != .nintendo_3ds;
            pub const seed_controller_focus = ae.platform == .nintendo_3ds or ae.platform == .nintendo_switch;
            pub const title_exit_button = switch (ae.platform) {
                .psp, .nintendo_3ds, .nintendo_switch => true,
                else => false,
            };
            pub const system_text_entry = switch (ae.platform) {
                .psp, .nintendo_3ds, .nintendo_switch => true,
                else => false,
            };
            pub const fixed_controller_glyphs = switch (ae.platform) {
                .psp, .nintendo_3ds, .nintendo_switch => true,
                else => false,
            };
            pub const compact_controller_glyphs = ae.platform == .psp;
            pub const nintendo_controller_glyphs = ae.platform == .nintendo_3ds or ae.platform == .nintendo_switch;
            pub const prompt_strip_height: i16 = if (ae.platform == .psp) 32 else 28;
            pub const prompt_y: i16 = 23 - if (ae.platform == .psp) @as(i16, 8) else 16;
            pub const max_draw_commands: u16 = if (ae.platform == .psp) 96 else 192;
            pub const max_visible_players: u8 = if (ae.platform == .psp) 4 else 60;
        };

        pub const resources = struct {
            pub const default_pack_in_data_dir = ae.platform == .nintendo_3ds or ae.platform == .nintendo_switch;
            pub const texture_pack_selection = ae.platform != .wasm;
            pub const glyph_texture = if (ae.platform == .psp)
                "crosscraft/textures/interface/controller_glyphs/psp"
            else
                "crosscraft/textures/interface/controller_glyphs/pc";
            pub const app_name: ?[:0]const u8 = switch (ae.platform) {
                .nintendo_3ds => "CrossCraft-Classic-3DS",
                .nintendo_switch => "CrossCraft-Classic-Switch",
                else => null,
            };
        };

        pub const saves = struct {
            pub const download = ae.platform == .wasm;
            pub const legacy_migration = ae.platform != .wasm;
            pub fn download_file(path: []const u8) bool {
                ae.FileExport.download(path, .{ .filename = std.fs.path.basename(path) }) catch return false;
                return true;
            }
        };

        pub const memory = struct {
            pub const resize_user_pool_to_world = ae.platform != .psp and ae.platform != .nintendo_3ds;
            pub const separate_worldgen_scratch = ae.platform == .wasm;
            // Capacity must cover every runtime model supported by the binary.
            pub const max_chunk_radius: u32 = switch (ae.platform) {
                .psp => psp_slim_profile.chunk_radius,
                .nintendo_3ds => new_3ds_profile.chunk_radius,
                else => desktop_profile.chunk_radius,
            };
            pub const initial_profile: MemoryProfile = switch (ae.platform) {
                .psp => psp_phat_profile,
                .nintendo_3ds => old_3ds_profile,
                .nintendo_switch => nintendo_switch_profile,
                else => desktop_profile,
            };

            pub fn detect_profile() MemoryProfile {
                return switch (ae.System.info().hardware) {
                    .psp_phat => psp_phat_profile,
                    .psp_slim => psp_slim_profile,
                    .old_3ds => old_3ds_profile,
                    .new_3ds => new_3ds_profile,
                    else => initial_profile,
                };
            }
        };

        pub const networking = struct {
            pub const multiplayer = ae.platform != .wasm;

            var session: ?ae.Network.Session = null;
            var connect_priority: ?ae.Util.PriorityScope = null;

            pub fn prepare() bool {
                if (session != null) return true;
                session = ae.Network.Session.prepare() catch |err| {
                    std.log.scoped(.game).warn("Network preparation failed: {}", .{err});
                    return false;
                };
                return true;
            }

            pub fn release() void {
                if (session) |*active| active.release();
                session = null;
            }

            pub fn configure_stream(stream: std.Io.net.Stream) void {
                // Retain CrossCraft's PSP low-latency transport policy.
                if (ae.platform != .psp) return;
                if (session) |*active| active.configure_stream(stream, .{ .no_delay = true }) catch |err|
                    std.log.scoped(.game).warn("TCP_NODELAY failed: {}", .{err});
            }

            pub fn begin_connect_setup() !void {
                if (ae.platform == .psp) connect_priority = try ae.Util.PriorityScope.enter_relative(-10);
            }

            pub fn end_connect_setup() void {
                if (connect_priority) |*scope| scope.restore() catch |err| {
                    std.log.scoped(.game).err("Restore connection priority failed: {}", .{err});
                    return;
                };
                connect_priority = null;
            }
        };
    };
}

/// Build-time packaging and launch policy uses the requested target, never the
/// build runner's builtin target. Source modules inherit their consumer target.
pub const BuildPolicy = struct {
    client_dir: ?[]const u8,
    standalone_server: bool,
    embed_default_pack: bool,
    bundle_resources: bool,
    install_raw_executable: bool,
    install_package: bool,
    use_llvm_linker: bool,
    launch: enum { direct, app_bundle, network_3ds, network_switch },
    icon_png: ?[]const u8,
    windows_icon: ?[]const u8,
    icon0: ?[]const u8,
    pic1: ?[]const u8,
    nintendo_3ds_icon: ?[]const u8,
    switch_icon: ?[]const u8,
    description: []const u8,
    publisher: []const u8,
    author: []const u8,
    version: []const u8,
};

pub fn build_policy(config: anytype, target: std.Target) BuildPolicy {
    const is_psp = config.platform == .psp;
    const is_macos = config.platform == .macos;
    const is_3ds = config.platform == .nintendo_3ds;
    const is_switch = config.platform == .nintendo_switch;
    return .{
        .client_dir = switch (config.platform) {
            .psp => "CrossCraft-Classic-PSP",
            .nintendo_3ds => "CrossCraft-Classic-3DS",
            .nintendo_switch => "CrossCraft-Classic-Switch",
            else => null,
        },
        .standalone_server = switch (config.platform) {
            .windows, .linux, .macos => true,
            else => false,
        },
        .embed_default_pack = config.platform == .windows or config.platform == .linux,
        .bundle_resources = is_macos,
        .install_raw_executable = !is_macos and !is_3ds and !is_switch,
        .install_package = is_psp or is_macos or is_3ds or is_switch,
        .use_llvm_linker = target.os.tag == .linux and target.isGnuLibC(),
        .launch = if (is_3ds) .network_3ds else if (is_switch) .network_switch else if (is_macos) .app_bundle else .direct,
        .icon_png = if (is_macos) "assets/icon-osx.png" else null,
        .windows_icon = if (config.platform == .windows) "assets/icon-win32.ico" else null,
        .icon0 = if (is_psp) "assets/icon-psp.png" else null,
        .pic1 = if (is_psp) "assets/banner-psp-pic1.png" else null,
        .nintendo_3ds_icon = if (is_3ds) "assets/icon-3ds.png" else null,
        .switch_icon = if (is_switch) "assets/icon-switch.jpg" else null,
        .description = if (is_3ds) "Clean-room Minecraft Classic" else "",
        .publisher = if (is_3ds) "CrossCraft" else "",
        .author = if (is_switch) "CrossCraft" else "",
        .version = if (is_switch) "0.0.0" else "",
    };
}

const TestPlatform = enum { psp, nintendo_3ds, nintendo_switch, linux, windows, macos, wasm };

fn TestEngineType(comptime target_platform: TestPlatform, comptime headless: bool) type {
    return struct {
        pub const platform = target_platform;
        pub const gfx: enum { headless, rendered } = if (headless) .headless else .rendered;
        pub const System = struct {
            pub fn info() struct { hardware: HardwareClass } {
                return .{ .hardware = switch (target_platform) {
                    .psp => .psp_phat,
                    .nintendo_3ds => if (N3ds.new_hardware) .new_3ds else .old_3ds,
                    .nintendo_switch => .nintendo_switch,
                    else => .desktop,
                } };
            }
        };
        pub const N3ds = struct {
            pub var new_hardware = false;
            pub fn is_new() bool {
                return new_hardware;
            }
        };
    };
}

test "capabilities preserve runtime Old 3DS controls and New 3DS fallback" {
    const Psp = ClientType(TestEngineType(.psp, false));
    const N3ds = ClientType(TestEngineType(.nintendo_3ds, false));
    const Switch = ClientType(TestEngineType(.nintendo_switch, false));
    const Desktop = ClientType(TestEngineType(.linux, false));
    try std.testing.expect(!Psp.controls.uses_single_stick_fallback(.psp_phat, false));
    try std.testing.expect(!Psp.controls.uses_single_stick_fallback(.psp_phat, true));
    try std.testing.expect(N3ds.controls.uses_single_stick_fallback(.old_3ds, false));
    try std.testing.expect(N3ds.controls.uses_single_stick_fallback(.old_3ds, true));
    try std.testing.expect(!N3ds.controls.uses_single_stick_fallback(.new_3ds, false));
    try std.testing.expect(N3ds.controls.uses_single_stick_fallback(.new_3ds, true));
    try std.testing.expect(!Switch.controls.uses_single_stick_fallback(.nintendo_switch, true));
    try std.testing.expect(!Desktop.controls.uses_single_stick_fallback(.desktop, true));

    try std.testing.expect(!Psp.controls.supports_single_stick_fallback(.psp_phat));
    try std.testing.expect(!N3ds.controls.supports_single_stick_fallback(.old_3ds));
    try std.testing.expect(N3ds.controls.supports_single_stick_fallback(.new_3ds));
    try std.testing.expect(!Switch.controls.supports_single_stick_fallback(.nintendo_switch));
    try std.testing.expect(Psp.controls.supports_rebinding(.psp_phat));
    try std.testing.expect(N3ds.controls.supports_rebinding(.old_3ds));
    try std.testing.expect(N3ds.controls.supports_rebinding(.new_3ds));
    try std.testing.expect(!Switch.controls.supports_rebinding(.nintendo_switch));
    try std.testing.expect(Desktop.controls.supports_rebinding(.desktop));

    const Engine = TestEngineType(.nintendo_3ds, false);
    Engine.N3ds.new_hardware = false;
    try std.testing.expectEqual(HardwareClass.old_3ds, N3ds.memory.detect_profile().hardware);
    Engine.N3ds.new_hardware = true;
    defer Engine.N3ds.new_hardware = false;

    try std.testing.expectEqual(HardwareClass.new_3ds, N3ds.memory.detect_profile().hardware);
}

test "capabilities keep browser, pointer and console policies independent" {
    const Browser = ClientType(TestEngineType(.wasm, false));
    const Headless = ClientType(TestEngineType(.linux, true));
    const Psp = ClientType(TestEngineType(.psp, false));
    const N3ds = ClientType(TestEngineType(.nintendo_3ds, false));
    const Switch = ClientType(TestEngineType(.nintendo_switch, false));
    try std.testing.expect(Browser.saves.download);
    try std.testing.expect(!Browser.networking.multiplayer);
    try std.testing.expect(!Browser.resources.texture_pack_selection);
    try std.testing.expect(Browser.ui.pointer);
    try std.testing.expect(!Headless.ui.pointer);
    try std.testing.expect(!Psp.ui.pointer);
    try std.testing.expect(!N3ds.ui.pointer);
    try std.testing.expect(Switch.ui.pointer and Switch.ui.seed_controller_focus);
    try std.testing.expect(!Psp.defaults.vsync and !N3ds.defaults.vsync);
    try std.testing.expect(!Psp.defaults.loaded_vsync and N3ds.defaults.loaded_vsync);
    try std.testing.expect(Psp.memory.initial_profile.chunk_radius <= Psp.memory.max_chunk_radius);
    try std.testing.expect(psp_slim_profile.chunk_radius <= Psp.memory.max_chunk_radius);
    try std.testing.expect(new_3ds_profile.chunk_radius <= N3ds.memory.max_chunk_radius);
    try std.testing.expect(Switch.memory.initial_profile.chunk_radius <= Switch.memory.max_chunk_radius);
}

test "capabilities limit standalone server packaging to PC targets" {
    inline for (std.meta.tags(TestPlatform)) |platform| {
        const policy = build_policy(.{ .platform = platform }, builtin.target);
        const pc = platform == .linux or platform == .windows or platform == .macos;
        try std.testing.expectEqual(pc, policy.standalone_server);
        if (policy.client_dir != null) try std.testing.expect(policy.install_package);
    }
    const bundle = build_policy(.{ .platform = TestPlatform.macos }, builtin.target);
    try std.testing.expect(bundle.bundle_resources and !bundle.install_raw_executable);
    try std.testing.expectEqual(.app_bundle, bundle.launch);
    const browser = build_policy(.{ .platform = TestPlatform.wasm }, builtin.target);
    try std.testing.expect(!browser.embed_default_pack);
}
