/// Centralised resource ownership for all game states.
///
/// Resources are identified by typed enums (`Tex`, future `Sound`/`Music`)
/// and loaded on demand from the open Zip archive. Each state declares
/// its required set via `apply_tex_set`; unneeded resources are freed
/// automatically. The Zip stays open for the lifetime of the program,
/// enabling future resource-pack switching (close old, open new, reload).
const ResourcePack = @This();

const SoundManager = @import("SoundManager.zig");

const std = @import("std");
const ae = @import("aether");
const Rendering = ae.Rendering;
const Zip = @import("util/Zip.zig");
const TextureAtlas = @import("graphics/TextureAtlas.zig").TextureAtlas;

// -- texture identifiers -----------------------------------------------------

pub const Tex = enum(u8) {
    dirt,
    logo,
    font,
    gui,
    terrain,
    clouds,
    water_still,
    lava_still,
    char,

    const count = @typeInfo(Tex).@"enum".fields.len;
};

fn tex_path(id: Tex) []const u8 {
    return switch (id) {
        .dirt => "minecraft/textures/dirt",
        .logo => "crosscraft/textures/menu/logo",
        .font => "minecraft/textures/default",
        .gui => "minecraft/textures/gui/gui",
        .terrain => "minecraft/textures/terrain",
        .clouds => "minecraft/textures/clouds",
        .water_still => "crosscraft/textures/water_still",
        .lava_still => "crosscraft/textures/lava_still",
        .char => "minecraft/textures/char",
    };
}

// -- storage -----------------------------------------------------------------

var textures: [Tex.count]Rendering.Texture = undefined;
var tex_loaded: u16 = 0;

pub var atlas: TextureAtlas = undefined;
var alloc: std.mem.Allocator = undefined;
var pack: *Zip = undefined;

/// Backing store for the path of the currently-open archive. Owned here so
/// other systems (e.g. SoundManager) can re-open the same file by absolute
/// name when they need a private file handle.
const max_pack_path_len: usize = 256;
var pack_path_buf: [max_pack_path_len]u8 = undefined;
var pack_path_len: usize = 0;

const log = std.log.scoped(.respack);

// -- animation state ---------------------------------------------------------

const tile_size: u32 = 16;
const water_tile_col: u32 = 14;
const water_tile_row: u32 = 0;
const lava_tile_col: u32 = 14;
const lava_tile_row: u32 = 1;
const anim_period_ticks: u32 = 2;

var anim_tick: u32 = 0;
var pack_initialized: bool = false;

// -- lifecycle ---------------------------------------------------------------

/// Open the resource pack and prepare for texture loading. Safe to call
/// multiple times -- subsequent calls are no-ops so MenuState.init can be
/// re-entered after a disconnect without leaking the already-open Zip.
pub fn init(render_alloc: std.mem.Allocator, game_alloc: std.mem.Allocator, io: std.Io, path: []const u8) !void {
    if (pack_initialized) return;
    std.debug.assert(path.len > 0 and path.len <= max_pack_path_len);
    alloc = render_alloc;
    tex_loaded = 0;
    anim_tick = 0;
    pack = try Zip.init(game_alloc, io, path);
    @memcpy(pack_path_buf[0..path.len], path);
    pack_path_len = path.len;
    pack_initialized = true;
}

pub fn deinit() void {
    if (!pack_initialized) return;
    var i: u8 = 0;
    while (i < Tex.count) : (i += 1) {
        if (tex_loaded & (@as(u16, 1) << @intCast(i)) != 0) {
            textures[i].deinit(alloc);
        }
    }
    tex_loaded = 0;
    pack.deinit();
    pack_initialized = false;
}

// -- pack access -------------------------------------------------------------

pub fn get_pack() *Zip {
    return pack;
}

pub fn get_pack_path() []const u8 {
    return pack_path_buf[0..pack_path_len];
}

/// Replace the active archive at `path`, transparently re-loading every
/// texture currently in the resident set so cached `*const Texture`
/// pointers (kept alive in screens, font batchers, etc.) stay valid -- only
/// the pixel data behind them changes. The new pack is fully validated and
/// every required texture is loaded into a temporary array before the swap,
/// so a malformed pack leaves the prior pack untouched.
pub fn switch_pack(path: []const u8) !void {
    std.debug.assert(pack_initialized);
    std.debug.assert(path.len > 0 and path.len <= max_pack_path_len);

    // Same path -- nothing to do (avoids closing & reopening the file).
    if (std.mem.eql(u8, path, pack_path_buf[0..pack_path_len])) return;

    const game_alloc = pack.allocator;
    const io_handle = pack.io;

    var new_pack = try Zip.init(game_alloc, io_handle, path);
    errdefer new_pack.deinit();

    // Stage replacements for every currently-resident texture before
    // touching the live array. If any required asset is missing the
    // previously loaded set stays in place.
    var staged: [Tex.count]Rendering.Texture = undefined;
    var staged_mask: u16 = 0;

    const old_pack = pack;
    pack = new_pack;

    var i: u8 = 0;
    while (i < Tex.count) : (i += 1) {
        const bit: u16 = @as(u16, 1) << @intCast(i);
        if (tex_loaded & bit == 0) continue;
        staged[i] = load_from_zip(@enumFromInt(i)) catch |err| {
            log.warn("pack '{s}' missing {s}: {}", .{ path, @tagName(@as(Tex, @enumFromInt(i))), err });
            // Roll back staged uploads and the pack swap.
            var j: u8 = 0;
            while (j < i) : (j += 1) {
                if (staged_mask & (@as(u16, 1) << @intCast(j)) != 0) {
                    staged[j].deinit(alloc);
                }
            }
            pack = old_pack;
            new_pack.deinit();
            return err;
        };
        staged_mask |= bit;
    }

    // Commit: free old GPU textures, install staged ones, reapply tags
    // (force_resident, atlas regen) so transient state matches load_tex().
    i = 0;
    while (i < Tex.count) : (i += 1) {
        const bit: u16 = @as(u16, 1) << @intCast(i);
        if (staged_mask & bit == 0) continue;
        textures[i].deinit(alloc);
        textures[i] = staged[i];
        switch (@as(Tex, @enumFromInt(i))) {
            .terrain => {
                textures[i].force_resident();
                atlas = TextureAtlas.init(256, 256, 16, 16);
            },
            .logo => textures[i].force_resident(),
            else => {},
        }
    }

    old_pack.deinit();

    @memcpy(pack_path_buf[0..path.len], path);
    pack_path_len = path.len;

    log.info("switched to pack '{s}'", .{path});
}

// -- texture access ----------------------------------------------------------

pub fn get_tex(id: Tex) *const Rendering.Texture {
    const i = @intFromEnum(id);
    std.debug.assert(tex_loaded & (@as(u16, 1) << @intCast(i)) != 0);
    return &textures[i];
}

pub fn load_tex(id: Tex) !void {
    const i = @intFromEnum(id);
    if (tex_loaded & (@as(u16, 1) << @intCast(i)) != 0) return;
    textures[i] = try load_from_zip(id);
    tex_loaded |= @as(u16, 1) << @intCast(i);

    switch (id) {
        .terrain => {
            textures[i].force_resident();
            atlas = TextureAtlas.init(256, 256, 16, 16);
        },
        .logo => textures[i].force_resident(),
        else => {},
    }
}

pub fn unload_tex(id: Tex) void {
    const i = @intFromEnum(id);
    const bit: u16 = @as(u16, 1) << @intCast(i);
    if (tex_loaded & bit == 0) return;
    textures[i].deinit(alloc);
    tex_loaded &= ~bit;
}

/// Load every texture in `set`, then unload everything not in it.
/// Phase 1 (load) may fail; phase 2 (unload) only runs on success so
/// the previous resource set is preserved on error.
pub fn apply_tex_set(set: []const Tex) !void {
    for (set) |id| try load_tex(id);

    var i: u8 = 0;
    while (i < Tex.count) : (i += 1) {
        var needed = false;
        for (set) |s| {
            if (@intFromEnum(s) == i) {
                needed = true;
                break;
            }
        }
        if (!needed) unload_tex(@enumFromInt(i));
    }
}

// -- animation ---------------------------------------------------------------

/// Advance fluid tile animations. Called every game tick; actually blits
/// a new frame once every `anim_period_ticks` ticks.
pub fn tick_animations() void {
    const t_bit: u16 = @as(u16, 1) << @intFromEnum(Tex.terrain);
    const w_bit: u16 = @as(u16, 1) << @intFromEnum(Tex.water_still);
    const l_bit: u16 = @as(u16, 1) << @intFromEnum(Tex.lava_still);
    std.debug.assert(tex_loaded & (t_bit | w_bit | l_bit) == (t_bit | w_bit | l_bit));

    anim_tick +%= 1;
    if (anim_tick % anim_period_ticks != 0) return;

    const water = &textures[@intFromEnum(Tex.water_still)];
    const lava = &textures[@intFromEnum(Tex.lava_still)];
    const water_frames: u32 = water.height / tile_size;
    const lava_frames: u32 = lava.height / tile_size;
    const step = anim_tick / anim_period_ticks;

    blit_frame(water, step % water_frames, water_tile_col, water_tile_row);
    blit_frame(lava, step % lava_frames, lava_tile_col, lava_tile_row);
    textures[@intFromEnum(Tex.terrain)].update();
}

fn blit_frame(
    src: *const Rendering.Texture,
    frame: u32,
    dst_col: u32,
    dst_row: u32,
) void {
    const dst_x0 = dst_col * tile_size;
    const dst_y0 = dst_row * tile_size;
    const src_y0 = frame * tile_size;
    var y: u32 = 0;
    while (y < tile_size) : (y += 1) {
        var x: u32 = 0;
        while (x < tile_size) : (x += 1) {
            const px = src.get_pixel(x, src_y0 + y);
            textures[@intFromEnum(Tex.terrain)].set_pixel(dst_x0 + x, dst_y0 + y, px);
        }
    }
}

// -- helpers -----------------------------------------------------------------

fn load_from_zip(id: Tex) !Rendering.Texture {
    var buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "assets/{s}.png", .{tex_path(id)});
    var stream = try pack.open(path);
    defer pack.closeStream(&stream);
    return try Rendering.Texture.load_from_reader(alloc, stream.reader);
}
