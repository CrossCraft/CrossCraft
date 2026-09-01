/// Streams all audio directly from pack.zip. STORE entries (the default
/// for .wav files in the standard pack) are read straight from disk by
/// the audio callback with no intermediate buffers. Two shared DEFLATE
/// stream slots exist for backwards compatibility with compressed packs.
const SoundManager = @This();

const std = @import("std");
const ae = @import("aether");
const Audio = ae.Audio;
const Math = ae.Math;
const blocks = @import("core").blocks;
const Block = blocks.Block;
const Options = @import("Options.zig");
const ResourcePack = @import("ResourcePack.zig");
const Zip = @import("util/Zip.zig");

const flate = std.compress.flate;
const Io = std.Io;
const File = Io.File;

const log = std.log.scoped(.audio);

// --- material classification ---

pub const Material = blocks.Material;

const material_count = @typeInfo(Material).@"enum".fields.len;
const max_variants = 4;
const music_count: u8 = 7;

pub fn block_material(id: Block) Material {
    return id.material();
}

// --- sound entry (location of PCM data inside pack.zip) ---

const SoundEntry = struct {
    data_offset: u64 = 0,
    header_skip: u64 = 0,
    pcm_size: u64 = 0,
    format: Audio.PcmFormat = .{ .sample_rate = 44100, .channels = 1, .bit_depth = 16 },
    deflated: bool = false,
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
var dig_counts: [material_count]u8 = .{ 0, 0, 0, 0, 0, 0, 0 };
var step_entries: [material_count][max_variants]SoundEntry = init_entry_grid();
var step_counts: [material_count]u8 = .{ 0, 0, 0, 0, 0, 0, 0 };
var music_entries: [music_count]SoundEntry = init_entry_row();

// --- voice pool ---

const max_voices: u32 = if (ae.platform == .psp) 8 else 17;
const music_slot: u32 = if (ae.platform == .psp) 7 else 16;

const Voice = struct {
    read_buf: [8192]u8,
    file_reader: File.Reader,
    limited: Io.Reader.Limited,
    handle: Audio.SoundHandle,
    stream: Audio.StreamingSoundHandle,
    active: bool,
    deflate: ?*DeflateSlot,
};

fn init_voices() [max_voices]Voice {
    var v: [max_voices]Voice = undefined;
    for (&v) |*slot| {
        slot.active = false;
        slot.handle = .none;
        slot.stream = .none;
        slot.deflate = null;
    }
    return v;
}

var voices: [max_voices]Voice = init_voices();

// --- shared DEFLATE decompression streams ---
//
// Only two exist -- enough for the rare case where a custom resource pack
// ships compressed audio.  A voice that needs DEFLATE grabs a slot; the
// decompressor reads from the voice's own file_reader.

const DeflateSlot = struct {
    flate_buf: [flate.max_window_len]u8,
    decompressor: flate.Decompress,
    in_use: bool,
};

fn init_deflate_slots() [2]DeflateSlot {
    var s: [2]DeflateSlot = undefined;
    for (&s) |*slot| slot.in_use = false;
    return s;
}

var deflate_slots: [2]DeflateSlot = init_deflate_slots();

fn find_free_deflate_slot() ?*DeflateSlot {
    for (&deflate_slots) |*s| {
        if (!s.in_use) return s;
    }
    return null;
}

// --- shared state ---

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

// --- RNG (variant & delay selection) ---

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

// --- resource paths ---

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

// --- init / deinit ---

/// Opens a second handle to the pack archive so music / sfx can stream
/// PCM data without seek contention with texture reads.
pub fn init() void {
    const pack = ResourcePack.get_pack();
    const dir = ResourcePack.get_dir();
    const path = ResourcePack.get_pack_path();
    stored_io = pack.io;
    stored_file = dir.openFile(stored_io, path, .{}) catch |err| {
        log.warn("cannot open '{s}' for audio: {}", .{ path, err });
        return;
    };

    scan_entries(pack, "dig", &dig_entries, &dig_counts, &dig_max);
    scan_entries(pack, "step", &step_entries, &step_counts, &step_max);
    scan_music(pack);

    for (&voices) |*v| {
        v.active = false;
        v.handle = .none;
        v.stream = .none;
        v.deflate = null;
    }
    for (&deflate_slots) |*s| s.in_use = false;

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
    stored_file.close(stored_io);
    initialised = false;

    stored_file = undefined;
    stored_io = undefined;

    music_state = .idle;
    music_index = 0;
    music_delay_timer = 0;
    voices = undefined;
    deflate_slots = undefined;

    dig_entries = init_entry_grid();
    dig_counts = .{ 0, 0, 0, 0, 0, 0, 0 };
    step_entries = init_entry_grid();
    step_counts = .{ 0, 0, 0, 0, 0, 0, 0 };
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

/// Open a WAV from the zip, parse its header, and record where the
/// entry's data lives in the archive. Both STORE and DEFLATE entries
/// are supported: the Zip stream reader decompresses transparently, so
/// the WAV header parse works regardless of compression method.
fn resolve_wav(pack: *Zip, path: []const u8) !SoundEntry {
    var stream = try pack.open(path);
    defer pack.close_stream(&stream);

    const wav = try parse_wav_stream(stream.reader);

    return .{
        .data_offset = stream.data_offset,
        .header_skip = wav.header_skip,
        .pcm_size = wav.pcm_size,
        .format = wav.format,
        .deflated = stream.compression_method == .deflate,
        .valid = true,
    };
}

const WavInfo = struct {
    header_skip: u64,
    pcm_size: u64,
    format: Audio.PcmFormat,
};

fn parse_wav_stream(reader: *Io.Reader) !WavInfo {
    var header: [12]u8 = undefined;
    try reader.readSliceAll(&header);
    if (!std.mem.eql(u8, header[0..4], "RIFF")) return error.InvalidWav;
    if (!std.mem.eql(u8, header[8..12], "WAVE")) return error.InvalidWav;

    var consumed: u64 = header.len;
    var format: ?Audio.PcmFormat = null;

    while (true) {
        var chunk_header: [8]u8 = undefined;
        try reader.readSliceAll(&chunk_header);
        consumed += chunk_header.len;
        const chunk_id = chunk_header[0..4];
        const chunk_size = std.mem.readInt(u32, chunk_header[4..8], .little);

        if (std.mem.eql(u8, chunk_id, "fmt ")) {
            if (chunk_size < 16) return error.InvalidWav;
            var fmt: [16]u8 = undefined;
            try reader.readSliceAll(&fmt);
            if (std.mem.readInt(u16, fmt[0..2], .little) != 1) return error.UnsupportedFormat;
            format = .{
                .sample_rate = std.mem.readInt(u32, fmt[4..8], .little),
                .channels = std.mem.readInt(u16, fmt[2..4], .little),
                .bit_depth = std.mem.readInt(u16, fmt[14..16], .little),
            };
            consumed += fmt.len;
            const rest = chunk_size - fmt.len;
            if (rest > 0) {
                try reader.discardAll64(rest);
                consumed += rest;
            }
        } else if (std.mem.eql(u8, chunk_id, "data")) {
            const fmt = format orelse return error.InvalidWav;
            if (chunk_size % fmt.frame_size() != 0) return error.InvalidWav;
            return .{
                .header_skip = consumed,
                .pcm_size = chunk_size,
                .format = fmt,
            };
        } else {
            try reader.discardAll64(chunk_size);
            consumed += chunk_size;
        }

        if (chunk_size & 1 != 0) {
            try reader.discardAll64(1);
            consumed += 1;
        }
    }
}

// --- per-frame update ---

pub fn update(dt: f32, cam_x: f32, cam_y: f32, cam_z: f32, yaw: f32, pitch: f32) void {
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

    // Reap finished SFX voices.
    // When sound is muted, actively stop any voices that are still streaming
    // so we don't burn I/O and CPU on audio no one can hear.
    for (voices[0..music_slot]) |*v| {
        if (!v.active) continue;
        if (Options.current.sound_volume == 0.0) {
            release_voice(v);
        } else if (!Audio.is_playing(v.handle)) {
            Audio.destroy_stream(v.stream);
            v.handle = .none;
            v.stream = .none;
            release_deflate(v);
            v.active = false;
        }
    }

    // Music state machine
    switch (music_state) {
        .playing => {
            if (Options.current.music_volume == 0.0) {
                // Muted while playing: stop the stream and park in delay so
                // music resumes automatically once volume is restored.
                release_voice(&voices[music_slot]);
                music_state = .delay;
                music_delay_timer = 1.0;
            } else if (!Audio.is_playing(voices[music_slot].handle)) {
                Audio.destroy_stream(voices[music_slot].stream);
                voices[music_slot].handle = .none;
                voices[music_slot].stream = .none;
                release_deflate(&voices[music_slot]);
                voices[music_slot].active = false;
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
                    // Still muted: poll again in 1 s so music starts quickly
                    // when volume is later restored.
                    music_delay_timer = 1.0;
                }
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
        .volume = music_volume(),
        .priority = .critical,
    }) catch {
        music_state = .delay;
        music_delay_timer = 30.0;
        return;
    };
    music_state = .playing;
}

// --- play API ---

fn music_volume() f32 {
    return 0.5 * Options.current.music_volume;
}

pub fn play_dig(block: Block, bx: u16, by: u16, bz: u16) void {
    play_material_sound(&dig_entries, &dig_counts, block, bx, by, bz, 1.0);
}

pub fn play_step(block: Block) void {
    if (!initialised) return;
    if (Options.current.sound_volume == 0.0) return;
    if (!block.has_step_sound()) return;
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
    start_voice(slot, entry, null, .{
        .volume = 0.15 * Options.current.sound_volume,
        .priority = .low,
    }) catch return;
}

fn play_material_sound(
    entries: *const [material_count][max_variants]SoundEntry,
    counts: *const [material_count]u8,
    block: Block,
    bx: u16,
    by: u16,
    bz: u16,
    volume: f32,
) void {
    if (!initialised) return;
    if (Options.current.sound_volume == 0.0) return;
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
        .volume = volume * Options.current.sound_volume,
        .priority = .normal,
        .ref_distance = 1.0,
        .max_distance = 16.0,
    }) catch return;
}

// --- internals ---

fn find_free_sfx() ?*Voice {
    for (voices[0..music_slot]) |*v| {
        if (!v.active) return v;
    }
    return null;
}

fn release_voice(v: *Voice) void {
    Audio.stop(v.handle);
    Audio.destroy_stream(v.stream);
    v.handle = .none;
    v.stream = .none;
    release_deflate(v);
    v.active = false;
}

fn release_deflate(v: *Voice) void {
    if (v.deflate) |ds| {
        ds.in_use = false;
        v.deflate = null;
    }
}

fn start_voice(
    v: *Voice,
    entry: SoundEntry,
    pos: ?Math.Vec3,
    opts: Audio.PlayOptions,
) !void {
    v.file_reader = File.Reader.init(stored_file, stored_io, &v.read_buf);
    v.deflate = null;

    if (entry.deflated) {
        const ds = find_free_deflate_slot() orelse return error.OutOfDeflateSlots;
        try v.file_reader.seekTo(entry.data_offset);
        ds.decompressor = flate.Decompress.init(
            &v.file_reader.interface,
            .raw,
            &ds.flate_buf,
        );
        try ds.decompressor.reader.discardAll64(entry.header_skip);
        ds.in_use = true;
        v.deflate = ds;
        v.limited = Io.Reader.Limited.init(
            &ds.decompressor.reader,
            Io.Limit.limited64(entry.pcm_size),
            &.{},
        );
    } else {
        try v.file_reader.seekTo(entry.data_offset + entry.header_skip);
        v.limited = Io.Reader.Limited.init(
            &v.file_reader.interface,
            Io.Limit.limited64(entry.pcm_size),
            &.{},
        );
    }

    v.stream = try Audio.create_stream(&.{
        .reader = &v.limited.interface,
        .format = entry.format,
        .byte_length = entry.pcm_size,
    });
    errdefer {
        Audio.destroy_stream(v.stream);
        v.stream = .none;
    }

    v.handle = try Audio.play_stream(v.stream, &opts);
    if (pos) |p| Audio.set_position(v.handle, p);
    v.active = true;
}
