/// Streams all audio directly from pack.zip - no PCM buffers in RAM.
///
/// Each active sound uses a dedicated file reader positioned at the
/// pre-computed PCM data offset within the archive. The pack uses
/// store-only compression, so reads are plain sequential I/O. File
/// readers use positional mode (pread) for thread safety with the
/// audio callback.
const SoundManager = @This();

const std = @import("std");
const ae = @import("aether");
const Audio = ae.Audio;
const Math = ae.Math;
const c = @import("common").consts;
const B = c.Block;
const Zip = @import("util/Zip.zig");

const Io = std.Io;
const File = Io.File;

const log = std.log.scoped(.audio);

// -- material classification ------------------------------------------------

pub const Material = enum(u3) { stone, grass, gravel, wood, glass };

const material_count = 5;
const max_variants = 4;
const music_count: u8 = 7;

pub fn block_material(id: u8) Material {
    return switch (id) {
        B.Stone,
        B.Cobblestone,
        B.Bedrock,
        B.Gold_Ore,
        B.Iron_Ore,
        B.Coal_Ore,
        B.Gold,
        B.Iron,
        B.Double_Slab,
        B.Slab,
        B.Brick,
        B.Mossy_Rocks,
        B.Obsidian,
        => .stone,
        B.Planks, B.Log, B.Bookshelf => .wood,
        B.Dirt, B.Sand, B.Gravel => .gravel,
        B.Glass => .glass,
        else => .grass,
    };
}

// -- sound entry (location of PCM data inside pack.zip) ---------------------

const SoundEntry = struct {
    pcm_offset: u64 = 0,
    pcm_size: u64 = 0,
    format: Audio.PcmFormat = .{ .sample_rate = 44100, .channels = 1, .bit_depth = 16 },
    valid: bool = false,
};

fn init_entry_grid() [material_count][max_variants]SoundEntry {
    var grid: [material_count][max_variants]SoundEntry = undefined;
    for (&grid) |*row| for (row) |*cell| {
        cell.* = .{};
    };
    return grid;
}

fn init_entry_row() [music_count]SoundEntry {
    var row: [music_count]SoundEntry = undefined;
    for (&row) |*cell| cell.* = .{};
    return row;
}

var dig_entries: [material_count][max_variants]SoundEntry = init_entry_grid();
var dig_counts: [material_count]u8 = .{ 0, 0, 0, 0, 0 };
var step_entries: [material_count][max_variants]SoundEntry = init_entry_grid();
var step_counts: [material_count]u8 = .{ 0, 0, 0, 0, 0 };
var music_entries: [music_count]SoundEntry = init_entry_row();

// -- streaming voice pool ---------------------------------------------------

const max_voices: u32 = if (ae.platform == .psp) 8 else 17;
const music_slot: u32 = if (ae.platform == .psp) 7 else 16;

const StreamVoice = struct {
    read_buf: [4096]u8,
    file_reader: File.Reader,
    limited: Io.Reader.Limited,
    handle: Audio.SoundHandle,
    active: bool,
};

fn init_voices() [max_voices]StreamVoice {
    var v: [max_voices]StreamVoice = undefined;
    for (&v) |*slot| {
        slot.active = false;
        slot.handle = 0;
    }
    return v;
}

var voices: [max_voices]StreamVoice = init_voices();

// -- shared state -----------------------------------------------------------

var stored_file: File = undefined;
var stored_io: Io = undefined;
var initialised: bool = false;

// Music state machine
const MusicState = enum { idle, playing, delay };
var music_state: MusicState = .idle;
var music_delay_timer: f32 = 0;
var music_index: u8 = 0;

const min_music_delay: f32 = 60.0;
const max_music_delay: f32 = 300.0;

// -- RNG (variant & delay selection) ----------------------------------------

var rng: u64 = 0xDEAD_BEEF_CAFE_BABE;

fn xorshift(state: *u64) u64 {
    var x = state.*;
    x ^= x << 13;
    x ^= x >> 7;
    x ^= x << 17;
    state.* = x;
    return x;
}

fn rand_u32(max: u32) u32 {
    return @intCast(xorshift(&rng) % max);
}

fn rand_f32() f32 {
    return @as(f32, @floatFromInt(xorshift(&rng) & 0xFFFF)) / 65536.0;
}

// -- resource paths ---------------------------------------------------------

const mat_names: [material_count][]const u8 = .{ "stone", "grass", "gravel", "wood", "glass" };
const dig_max: [material_count]u8 = .{ 4, 4, 4, 4, 3 };
const step_max: [material_count]u8 = .{ 4, 4, 4, 4, 0 };

const music_paths: [music_count][]const u8 = .{
    "assets/minecraft/music/calm1.wav",
    "assets/minecraft/music/calm2.wav",
    "assets/minecraft/music/calm3.wav",
    "assets/minecraft/music/hal1.wav",
    "assets/minecraft/music/hal2.wav",
    "assets/minecraft/music/hal3.wav",
    "assets/minecraft/music/hal4.wav",
};

// -- init / deinit ----------------------------------------------------------

pub fn init(pack: *Zip, path: []const u8) void {
    stored_io = pack.io;
    stored_file = Io.Dir.cwd().openFile(stored_io, path, .{}) catch |err| {
        log.warn("cannot open '{s}' for audio: {}", .{ path, err });
        return;
    };

    scan_entries(pack, "dig", &dig_entries, &dig_counts, &dig_max);
    scan_entries(pack, "step", &step_entries, &step_counts, &step_max);
    scan_music(pack);

    for (&voices) |*v| {
        v.active = false;
        v.handle = 0;
    }

    music_state = .delay;
    music_delay_timer = 5.0 + rand_f32() * 15.0;
    music_index = @intCast(rand_u32(music_count));
    initialised = true;

    log.info("sound manager ready", .{});
}

pub fn deinit() void {
    if (!initialised) return;
    for (&voices) |*v| {
        if (v.active) {
            Audio.stop(v.handle);
            v.active = false;
        }
    }
    stored_file.close(stored_io);
    initialised = false;

    stored_file = undefined;
    stored_io = undefined;

    music_state = .idle;
    music_index = 0;
    music_delay_timer = 0;
    voices = undefined;

    dig_entries = init_entry_grid();
    dig_counts = .{ 0, 0, 0, 0, 0 };
    step_entries = init_entry_grid();
    step_counts = .{ 0, 0, 0, 0, 0 };
    music_entries = init_entry_row();
}

fn scan_entries(
    pack: *Zip,
    kind: []const u8,
    entries: *[material_count][max_variants]SoundEntry,
    counts: *[material_count]u8,
    limits: *const [material_count]u8,
) void {
    for (0..material_count) |mi| {
        var loaded: u8 = 0;
        for (0..@as(usize, limits[mi])) |vi| {
            var buf: [128]u8 = undefined;
            const path = std.fmt.bufPrint(&buf, "assets/minecraft/sounds/{s}/{s}{d}.wav", .{
                kind, mat_names[mi], vi + 1,
            }) catch continue;
            entries[mi][vi] = resolve_wav(pack, path) catch |err| {
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

/// Open a WAV from the zip, parse its header, and record where the PCM
/// data lives in the archive so we can seek straight to it at play time.
/// Playback reads raw bytes directly from the archive file handle, so the
/// entry must be stored (not deflated) -- user-supplied texturepacks often
/// use deflate, in which case we fail the resolve and the sound silently
/// drops rather than playing compressed bytes as PCM (static noise).
fn resolve_wav(pack: *Zip, path: []const u8) !SoundEntry {
    var stream = try pack.open(path);
    defer pack.closeStream(&stream);

    if (stream.compression_method != .store) return error.UnsupportedCompression;

    const wav = try Audio.wav.open(stream.reader);
    const pcm_size = wav.byte_length orelse return error.UnknownLength;
    const header_bytes = stream.uncompressed_size - pcm_size;

    return .{
        .pcm_offset = stream.data_offset + header_bytes,
        .pcm_size = pcm_size,
        .format = wav.format,
        .valid = true,
    };
}

// -- per-frame update -------------------------------------------------------

pub fn update(dt: f32, cam_x: f32, cam_y: f32, cam_z: f32, yaw: f32, pitch: f32) void {
    if (!initialised) return;

    // Listener
    const sy = @sin(yaw);
    const cy = @cos(yaw);
    const cp = @cos(pitch);
    const sp = @sin(pitch);
    Audio.set_listener(
        Math.Vec3.new(cam_x, cam_y, cam_z),
        Math.Vec3.new(-sy * cp, sp, -cy * cp),
        Math.Vec3.new(0, 1, 0),
    );

    // Reap finished SFX voices (not music slot)
    for (voices[0..music_slot]) |*v| {
        if (v.active and !Audio.is_playing(v.handle)) v.active = false;
    }

    // Music state machine
    switch (music_state) {
        .playing => {
            if (!Audio.is_playing(voices[music_slot].handle)) {
                voices[music_slot].active = false;
                music_state = .delay;
                music_delay_timer = min_music_delay +
                    rand_f32() * (max_music_delay - min_music_delay);
            }
        },
        .delay => {
            music_delay_timer -= dt;
            if (music_delay_timer <= 0) {
                advance_and_play_music();
            }
        },
        .idle => {},
    }
}

fn advance_and_play_music() void {
    // Pick a different track than the one that just played
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
        .volume = 0.5,
        .priority = .critical,
    }) catch {
        music_state = .delay;
        music_delay_timer = 30.0;
        return;
    };
    music_state = .playing;
}

// -- play API ---------------------------------------------------------------

pub fn play_dig(block: u8, bx: u16, by: u16, bz: u16) void {
    play_material_sound(&dig_entries, &dig_counts, block, bx, by, bz, 1.0);
}

pub fn play_step(block: u8) void {
    if (!initialised) return;
    var mat = @intFromEnum(block_material(block));
    var count = step_counts[mat];
    if (count == 0) {
        mat = @intFromEnum(Material.stone);
        count = step_counts[mat];
    }
    if (count == 0) return;
    const entry = step_entries[mat][rand_u32(count)];
    if (!entry.valid) return;
    const slot = find_free_sfx() orelse return;
    start_voice(slot, entry, null, .{ .volume = 0.15, .priority = .low }) catch return;
}

fn play_material_sound(
    entries: *const [material_count][max_variants]SoundEntry,
    counts: *const [material_count]u8,
    block: u8,
    bx: u16,
    by: u16,
    bz: u16,
    volume: f32,
) void {
    if (!initialised) return;
    const mat = @intFromEnum(block_material(block));
    const count = counts[mat];
    if (count == 0) return;
    const entry = entries[mat][rand_u32(count)];
    if (!entry.valid) return;
    const pos = Math.Vec3.new(
        @as(f32, @floatFromInt(bx)) + 0.5,
        @as(f32, @floatFromInt(by)) + 0.5,
        @as(f32, @floatFromInt(bz)) + 0.5,
    );
    const slot = find_free_sfx() orelse return;
    start_voice(slot, entry, pos, .{
        .volume = volume,
        .priority = .normal,
        .ref_distance = 1.0,
        .max_distance = 16.0,
    }) catch return;
}

// -- internals --------------------------------------------------------------

fn find_free_sfx() ?*StreamVoice {
    for (voices[0..music_slot]) |*v| {
        if (!v.active) return v;
    }
    return null;
}

fn start_voice(
    v: *StreamVoice,
    entry: SoundEntry,
    pos: ?Math.Vec3,
    opts: Audio.PlayOptions,
) !void {
    v.file_reader = File.Reader.init(stored_file, stored_io, &v.read_buf);
    try v.file_reader.seekTo(entry.pcm_offset);

    v.limited = Io.Reader.Limited.init(
        &v.file_reader.interface,
        Io.Limit.limited64(entry.pcm_size),
        &.{},
    );

    const stream: Audio.Stream = .{
        .reader = &v.limited.interface,
        .format = entry.format,
        .byte_length = entry.pcm_size,
    };

    if (pos) |p| {
        v.handle = try Audio.play_at(stream, p, opts);
    } else {
        v.handle = try Audio.play(stream, opts);
    }
    v.active = true;
}
