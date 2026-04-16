/// Streams all audio directly from pack.zip — no PCM buffers in RAM
/// for STORE entries. DEFLATE entries are decompressed on the main
/// thread into per-voice ring buffers; the audio callback reads only
/// from those buffers, keeping the decompressor off the audio thread's
/// small stack.
const SoundManager = @This();

const std = @import("std");
const ae = @import("aether");
const Audio = ae.Audio;
const Math = ae.Math;
const Util = ae.Util;
const Estimator = Util.Estimator;
const c = @import("common").consts;
const B = c.Block;
const Options = @import("Options.zig");
const ResourcePack = @import("ResourcePack.zig");
const Zip = @import("util/Zip.zig");

const flate = std.compress.flate;
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
var dig_counts: [material_count]u8 = .{ 0, 0, 0, 0, 0 };
var step_entries: [material_count][max_variants]SoundEntry = init_entry_grid();
var step_counts: [material_count]u8 = .{ 0, 0, 0, 0, 0 };
var music_entries: [music_count]SoundEntry = init_entry_row();

// -- streaming voice pool ---------------------------------------------------

const max_voices: u32 = if (ae.platform == .psp) 8 else 17;
const music_slot: u32 = if (ae.platform == .psp) 7 else 16;

/// Ring buffer size per voice for DEFLATE PCM staging. Must be a power
/// of two so the mask trick works for cheap modular arithmetic.
const pcm_buf_shift = 15;
const pcm_buf_size: u32 = 1 << pcm_buf_shift; // 32 KiB
const pcm_buf_mask: u32 = pcm_buf_size - 1;

const StreamVoice = struct {
    read_buf: [8192]u8,
    file_reader: File.Reader,
    flate_buf: [flate.max_window_len]u8,
    decompressor: flate.Decompress,
    /// Pre-decoded PCM ring buffer. The main thread writes decompressed
    /// PCM here; the audio callback reads from it via `ring_reader`.
    pcm_buf: [pcm_buf_size]u8,
    /// Write cursor (advanced by main thread after decompressing).
    pcm_write: u32,
    /// Read cursor (advanced by audio callback after consuming).
    pcm_read: u32,
    /// Remaining uncompressed PCM bytes the decompressor has yet to
    /// produce. Zero means the main thread has finished inflating.
    pcm_remaining: u64,
    /// Io.Reader backed by `pcm_buf` for the audio callback.
    ring_reader: Io.Reader,
    limited: Io.Reader.Limited,
    handle: Audio.SoundHandle,
    active: bool,
    deflated: bool,
};

fn init_voices() [max_voices]StreamVoice {
    var v: [max_voices]StreamVoice = undefined;
    for (&v) |*slot| {
        slot.active = false;
        slot.deflated = false;
        slot.handle = 0;
        slot.pcm_write = 0;
        slot.pcm_read = 0;
        slot.pcm_remaining = 0;
    }
    return v;
}

var voices: [max_voices]StreamVoice = init_voices();

// -- ring buffer reader (audio callback side) -------------------------------

/// VTable for the ring-buffer reader consumed by the audio callback.
/// All decompression happens on the main thread; this reader only does
/// memcpy from the pre-filled `pcm_buf`.
const ring_vtable: Io.Reader.VTable = .{
    .stream = ringStream,
};

fn ringStream(r: *Io.Reader, w: *Io.Writer, limit: Io.Limit) Io.Reader.StreamError!usize {
    const v: *StreamVoice = @alignCast(@fieldParentPtr("ring_reader", r));

    const rp: u32 = v.pcm_read;
    const wp: u32 = @atomicLoad(u32, &v.pcm_write, .acquire);

    const avail: u32 = (wp -% rp) & pcm_buf_mask;
    if (avail == 0) {
        // Buffer empty -- check whether the decompressor is truly done.
        if (v.pcm_remaining == 0)
            return error.EndOfStream;
        // Temporary underrun: write silence so the voice stays alive
        // while the main thread catches up.
        const n: u32 = @intCast(limit.minInt(pcm_buf_size / 4));
        const zeroes = [_]u8{0} ** 256;
        var left: u32 = n;
        while (left > 0) {
            const chunk: u32 = @min(left, zeroes.len);
            try w.writeAll(zeroes[0..chunk]);
            left -= chunk;
        }
        return n;
    }

    const n: u32 = @intCast(limit.minInt(avail));
    const first: u32 = @min(n, pcm_buf_size - rp);

    try w.writeAll(v.pcm_buf[rp..][0..first]);
    if (first < n) {
        try w.writeAll(v.pcm_buf[0 .. n - first]);
    }

    @atomicStore(u32, &v.pcm_read, (rp +% n) & pcm_buf_mask, .release);
    return n;
}

// -- ring buffer producer (main thread) -------------------------------------

fn ringFree(v: *const StreamVoice) u32 {
    const rp: u32 = @atomicLoad(u32, &v.pcm_read, .acquire);
    const wp: u32 = v.pcm_write;
    // One slot is always kept empty to distinguish full from empty.
    return (pcm_buf_size - 1) - ((wp -% rp) & pcm_buf_mask);
}

/// Fill a voice's ring buffer with up to `budget` bytes of
/// decompressed PCM. Small per-frame budgets spread the decode cost
/// across frames; the silence-on-underrun in ringStream covers the
/// ramp-up after a voice starts.
fn refillRing(v: *StreamVoice, budget: u32) void {
    var produced: u32 = 0;
    while (v.pcm_remaining > 0 and produced < budget) {
        const free = ringFree(v);
        if (free == 0) return;
        const wp = v.pcm_write;
        const contig: u32 = @min(free, pcm_buf_size - wp);
        // Cap at read_buf size to avoid overrunning the file reader's
        // internal buffer when the decompressor delegates a large read.
        const left: u32 = budget - produced;
        const want: u32 = @intCast(@min(@min(@min(contig, v.read_buf.len), v.pcm_remaining), left));
        const n = v.decompressor.reader.readSliceShort(v.pcm_buf[wp..][0..want]) catch break;
        if (n == 0) {
            v.pcm_remaining = 0;
            break;
        }
        const bytes: u32 = @intCast(n);
        produced += bytes;
        v.pcm_remaining -= n;
        @atomicStore(u32, &v.pcm_write, (wp + bytes) & pcm_buf_mask, .release);
    }
}

// -- shared state -----------------------------------------------------------

var stored_file: File = undefined;
var stored_io: Io = undefined;
var initialised: bool = false;
var refill_estimator: Estimator = Estimator.init();

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
        v.deflated = false;
        v.handle = 0;
        v.pcm_write = 0;
        v.pcm_read = 0;
        v.pcm_remaining = 0;
    }

    refill_estimator = Estimator.init();
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

/// Open a WAV from the zip, parse its header, and record where the
/// entry's data lives in the archive. Both STORE and DEFLATE entries
/// are supported: the Zip stream reader decompresses transparently, so
/// the WAV header parse works regardless of compression method.
fn resolve_wav(pack: *Zip, path: []const u8) !SoundEntry {
    var stream = try pack.open(path);
    defer pack.closeStream(&stream);

    const wav = try Audio.wav.open(stream.reader);
    const pcm_size = wav.byte_length orelse return error.UnknownLength;
    const header_skip = stream.uncompressed_size - pcm_size;

    return .{
        .data_offset = stream.data_offset,
        .header_skip = header_skip,
        .pcm_size = pcm_size,
        .format = wav.format,
        .deflated = stream.compression_method == .deflate,
        .valid = true,
    };
}

// -- per-frame update -------------------------------------------------------

pub fn update(dt: f32, budget: *const Util.BudgetContext, cam_x: f32, cam_y: f32, cam_z: f32, yaw: f32, pitch: f32) void {
    if (!initialised) return;

    // Top up ring buffers for active DEFLATE voices. The estimator
    // tracks refill cost with a single measurement per frame; when the
    // frame budget is already exhausted we skip the pass entirely and
    // let the silence padding in ringStream cover the gap.
    {
        var has_deflate = false;
        for (&voices) |*v| {
            if (v.active and v.deflated and v.pcm_remaining > 0) {
                has_deflate = true;
                break;
            }
        }
        if (has_deflate) {
            const skip = !refill_estimator.is_warming_up() and
                budget.safe_remaining() < refill_estimator.estimate_cost(.p75);
            if (!skip) {
                refill_estimator.begin(stored_io);
                for (&voices) |*v| {
                    if (!v.active or !v.deflated) continue;
                    if (v.pcm_remaining == 0) continue;
                    refillRing(v, 8192);
                }
                refill_estimator.end(stored_io);
            }
        }
    }

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

    // Reap finished SFX voices (not music slot).
    // When sound is muted, actively stop any voices that are still streaming
    // so we don't burn I/O and CPU on audio no one can hear.
    for (voices[0..music_slot]) |*v| {
        if (!v.active) continue;
        if (Options.current.sound_volume == 0.0) {
            Audio.stop(v.handle);
            v.active = false;
        } else if (!Audio.is_playing(v.handle)) {
            v.active = false;
        }
    }

    // Music state machine
    switch (music_state) {
        .playing => {
            if (Options.current.music_volume == 0.0) {
                // Muted while playing: stop the stream and park in delay so
                // music resumes automatically once volume is restored.
                Audio.stop(voices[music_slot].handle);
                voices[music_slot].active = false;
                music_state = .delay;
                music_delay_timer = 1.0;
            } else if (!Audio.is_playing(voices[music_slot].handle)) {
                voices[music_slot].active = false;
                music_state = .delay;
                music_delay_timer = min_music_delay +
                    rand_f32() * (max_music_delay - min_music_delay);
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
        .volume = 0.5 * Options.current.music_volume,
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
    if (Options.current.sound_volume == 0.0) return;
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
    start_voice(slot, entry, null, .{ .volume = 0.15 * Options.current.sound_volume, .priority = .low }) catch return;
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
    v.deflated = entry.deflated;

    if (entry.deflated) {
        try v.file_reader.seekTo(entry.data_offset);
        v.decompressor = flate.Decompress.init(
            &v.file_reader.interface,
            .raw,
            &v.flate_buf,
        );
        try v.decompressor.reader.discardAll64(entry.header_skip);

        // Reset ring buffer. The next update() call will begin filling
        // it; ringStream writes silence until data arrives.
        v.pcm_write = 0;
        v.pcm_read = 0;
        v.pcm_remaining = entry.pcm_size;

        v.ring_reader = .{
            .vtable = &ring_vtable,
            .buffer = &.{},
            .seek = 0,
            .end = 0,
        };
        v.limited = Io.Reader.Limited.init(
            &v.ring_reader,
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
