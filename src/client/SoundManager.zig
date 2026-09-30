/// Game sound policy over Aether-owned streaming WAV voices. The active pack
/// remains borrowed until every voice is stopped during deinit.
const std = @import("std");
const ae = @import("aether");
const blocks = @import("core").blocks;
const capabilities = @import("capabilities");
const Options = @import("Options.zig");

const assert = std.debug.assert;
const caps = capabilities.ClientType(ae);
const Audio = ae.Audio;
const Math = ae.Math;
const Block = blocks.Block;
const Zip = ae.Util.Zip;

const log = std.log.scoped(.audio);

pub const Material = blocks.Material;

const material_count = @typeInfo(Material).@"enum".fields.len;
const max_variants = 4;
const music_count: u8 = 7;

const SoundEntry = struct {
    path_bytes: [128]u8 = undefined,
    path_len: usize = 0,
    valid: bool = false,
    compressed: bool = false,

    fn path(self: *const SoundEntry) []const u8 {
        return self.path_bytes[0..self.path_len];
    }
};

var dig_entries: [material_count][max_variants]SoundEntry = .{[_]SoundEntry{.{}} ** max_variants} ** material_count;
var dig_counts: [material_count]u8 = .{0} ** material_count;
var step_entries: [material_count][max_variants]SoundEntry = .{[_]SoundEntry{.{}} ** max_variants} ** material_count;
var step_counts: [material_count]u8 = .{0} ** material_count;
var music_entries: [music_count]SoundEntry = .{SoundEntry{}} ** music_count;

const max_voices: u32 = caps.audio.max_voices;
const music_slot: u32 = max_voices - 1;

const Voice = struct {
    handle: Audio.SoundHandle = .none,
    active: bool = false,
    compressed: bool = false,
};

var voices: [max_voices]Voice = @splat(.{});
var active_pack: *Zip = undefined;
var initialised: bool = false;

const MusicState = enum { idle, playing, delay };
var music_state: MusicState = .idle;
var music_delay_timer: f32 = 0;
var music_index: u8 = 0;

const min_music_delay: f32 = 60.0;
const max_music_delay: f32 = 300.0;

var rng: u64 = 0xDEAD_BEEF_CAFE_BABE;

fn xorshift(state: *u64) u64 {
    assert(state.* != 0); // Zero is an absorbing state for this generator.
    var x = state.*;
    x ^= x << 13;
    x ^= x >> 7;
    x ^= x << 17;
    state.* = x;
    return x;
}

fn rand_u32(max: u32) u32 {
    assert(max > 0);
    return @intCast(xorshift(&rng) % max);
}

fn rand_f32() f32 {
    return @as(f32, @floatFromInt(xorshift(&rng) & 0xFFFF)) / 65536.0;
}

const mat_names: [material_count][]const u8 = .{ "stone", "grass", "gravel", "wood", "glass", "cloth", "sand" };
const dig_max: [material_count]u8 = .{ 4, 4, 4, 4, 3, 4, 4 };
const step_max: [material_count]u8 = .{ 4, 4, 4, 4, 0, 4, 4 };

const music_paths: [music_count][]const u8 = .{
    "assets/minecraft/music/calm1.wav",
    "assets/minecraft/music/calm2.wav",
    "assets/minecraft/music/calm3.wav",
    "assets/minecraft/music/hal1.wav",
    "assets/minecraft/music/hal2.wav",
    "assets/minecraft/music/hal3.wav",
    "assets/minecraft/music/hal4.wav",
};

/// Archive slots have independent reader state; Aether owns and releases each
/// active WAV source. ResourcePack must call deinit before closing this archive.
pub fn init(pack: *Zip) void {
    assert(!initialised);
    active_pack = pack;
    scan_entries(pack, "dig", &dig_entries, &dig_counts, &dig_max);
    scan_entries(pack, "step", &step_entries, &step_counts, &step_max);
    scan_music(pack);
    voices = @splat(.{});

    music_state = .delay;
    music_delay_timer = 5.0 + rand_f32() * 15.0;
    music_index = @intCast(rand_u32(music_count));
    initialised = true;

    log.info("sound manager ready", .{});
}

pub fn deinit() void {
    if (!initialised) return;

    for (&voices) |*v| {
        if (v.active) release_voice(v);
    }
    initialised = false;

    active_pack = undefined;

    music_state = .idle;
    music_index = 0;
    music_delay_timer = 0;
    voices = undefined;

    dig_entries = .{[_]SoundEntry{.{}} ** max_variants} ** material_count;
    dig_counts = .{0} ** material_count;
    step_entries = .{[_]SoundEntry{.{}} ** max_variants} ** material_count;
    step_counts = .{0} ** material_count;
    music_entries = .{SoundEntry{}} ** music_count;
}

/// Cancel menu audio before loading and give the world a fresh music delay.
/// LoadState does not call update, so the countdown starts in gameplay.
pub fn begin_world_load() void {
    if (!initialised) return;

    for (&voices) |*v| {
        if (v.active) release_voice(v);
    }
    music_state = .delay;
    music_delay_timer = min_music_delay + rand_f32() * (max_music_delay - min_music_delay);
}

fn scan_entries(
    pack: *Zip,
    kind: []const u8,
    entries: *[material_count][max_variants]SoundEntry,
    counts: *[material_count]u8,
    limits: *const [material_count]u8,
) void {
    for (0..material_count) |mi| {
        assert(limits[mi] <= max_variants);
        var loaded: u8 = 0;
        for (0..@as(usize, limits[mi])) |vi| {
            var buf: [128]u8 = undefined;
            const path = std.fmt.bufPrint(&buf, "assets/minecraft/sounds/{s}/{s}{d}.wav", .{
                kind, mat_names[mi], vi + 1,
            }) catch continue;
            entries[mi][loaded] = resolve_wav(pack, path) catch |err| {
                log.warn("skip {s}: {}", .{ path, err });
                continue;
            };
            loaded += 1;
        }
        counts[mi] = loaded;
    }
}

fn scan_music(pack: *Zip) void {
    for (0..music_count) |i| {
        music_entries[i] = resolve_wav(pack, music_paths[i]) catch |err| {
            log.warn("skip {s}: {}", .{ music_paths[i], err });
            continue;
        };
    }
}

/// Validate the WAV once during pack scanning; playback reopens its independent
/// owned source. Store only the game resource path, not archive byte offsets.
fn resolve_wav(pack: *Zip, path: []const u8) !SoundEntry {
    const input = try pack.open(path);
    defer pack.close_stream(&input);

    _ = try Audio.wav.parse_stream(input.reader);
    if (path.len > 128) return error.SoundPathTooLong;
    var entry: SoundEntry = .{ .path_len = path.len, .valid = true, .compressed = input.compression_method == .deflate };
    @memcpy(entry.path_bytes[0..path.len], path);
    return entry;
}

pub fn update(dt: f32, cam_x: f32, cam_y: f32, cam_z: f32, yaw: f32, pitch: f32) void {
    assert(std.math.isFinite(dt) and dt >= 0.0);
    if (!initialised) return;

    const sy = @sin(yaw);
    const cy = @cos(yaw);
    const cp = @cos(pitch);
    const sp = @sin(pitch);
    Audio.set_listener(
        Math.Vec3.new(cam_x, cam_y, cam_z),
        Math.Vec3.new(-sy * cp, sp, -cy * cp),
        Math.Vec3.new(0, 1, 0),
    );

    // Muting stops active streams rather than continuing background I/O.
    for (voices[0..music_slot]) |*v| {
        if (!v.active) continue;
        if (Options.current.sound_volume == 0.0) {
            release_voice(v);
        } else if (!Audio.is_playing(v.handle)) {
            release_voice(v);
        }
    }

    switch (music_state) {
        .playing => {
            if (Options.current.music_volume == 0.0) {
                release_voice(&voices[music_slot]);
                music_state = .delay;
                music_delay_timer = 1.0;
            } else if (!Audio.is_playing(voices[music_slot].handle)) {
                release_voice(&voices[music_slot]);
                music_state = .delay;
                music_delay_timer = min_music_delay +
                    rand_f32() * (max_music_delay - min_music_delay);
            } else {
                Audio.set_volume(voices[music_slot].handle, music_volume());
            }
        },
        .delay => {
            music_delay_timer -= dt;
            if (music_delay_timer <= 0) {
                if (Options.current.music_volume > 0.0) {
                    advance_and_play_music();
                } else {
                    music_delay_timer = 1.0;
                }
            }
        },
        .idle => {},
    }
}

fn advance_and_play_music() void {
    if (music_count > 1) {
        music_index = @intCast((@as(u32, music_index) + 1 + rand_u32(music_count - 1)) % music_count);
    }
    const entry = music_entries[music_index];
    if (!entry.valid) {
        music_state = .delay;
        music_delay_timer = 30.0;
        return;
    }
    start_voice(&voices[music_slot], entry, null, .{
        .volume = music_volume(),
        .priority = .critical,
    }) catch {
        music_state = .delay;
        music_delay_timer = 30.0;
        return;
    };
    music_state = .playing;
}

fn music_volume() f32 {
    return 0.5 * Options.current.music_volume;
}

pub fn play_step(block: Block) void {
    if (!initialised) return;
    if (Options.current.sound_volume == 0.0) return;
    if (!block.has_step_sound()) return;
    var mat = @intFromEnum(block.material());
    var count = step_counts[mat];
    if (count == 0) {
        mat = @intFromEnum(Material.stone);
        count = step_counts[mat];
    }
    if (count == 0) return;
    const entry = step_entries[mat][rand_u32(count)];
    if (!entry.valid) return;
    const slot = find_free_sfx() orelse return;
    start_voice(slot, entry, null, .{
        .volume = 0.15 * Options.current.sound_volume,
        .priority = .low,
    }) catch return;
}

pub fn play_dig(block: Block, bx: u16, by: u16, bz: u16) void {
    if (!initialised) return;
    if (Options.current.sound_volume == 0.0) return;
    const mat = @intFromEnum(block.material());
    const count = dig_counts[mat];
    if (count == 0) return;
    const entry = dig_entries[mat][rand_u32(count)];
    if (!entry.valid) return;
    const pos = Math.Vec3.new(
        @as(f32, @floatFromInt(bx)) + 0.5,
        @as(f32, @floatFromInt(by)) + 0.5,
        @as(f32, @floatFromInt(bz)) + 0.5,
    );
    const slot = find_free_sfx() orelse return;
    start_voice(slot, entry, pos, .{
        .volume = Options.current.sound_volume,
        .priority = .normal,
        .ref_distance = 1.0,
        .max_distance = 16.0,
    }) catch return;
}

fn find_free_sfx() ?*Voice {
    for (voices[0..music_slot]) |*v| {
        if (!v.active) return v;
    }
    return null;
}

fn release_voice(v: *Voice) void {
    // Owned streams close on stop or completion; a completed handle is harmless.
    Audio.stop(v.handle);
    v.handle = .none;
    v.active = false;
    v.compressed = false;
}

fn start_voice(
    v: *Voice,
    entry: SoundEntry,
    pos: ?Math.Vec3,
    opts: Audio.PlayOptions,
) !void {
    assert(initialised);
    assert(!v.active);
    if (entry.compressed) {
        var compressed_voices: usize = 0;
        for (voices) |voice| if (voice.active and voice.compressed) {
            compressed_voices += 1;
        };
        // Retain the game's two compressed-voice budget and leave the archive's
        // third decompression window available to texture/animation loaders.
        if (compressed_voices >= 2) return error.OutOfDeflateSlots;
    }
    const stream = try Audio.create_wav_stream(active_pack.allocator, active_pack.source(), entry.path());
    errdefer Audio.destroy_stream(stream);

    v.handle = try Audio.play_stream(stream, &opts);
    if (pos) |p| Audio.set_position(v.handle, p);
    v.active = true;
    v.compressed = entry.compressed;
}
