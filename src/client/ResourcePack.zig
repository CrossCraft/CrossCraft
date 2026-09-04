/// Owns the active archive and the textures requested by game states.
const ResourcePack = @This();

const SoundManager = @import("SoundManager.zig");

const std = @import("std");
const ae = @import("aether");
const Rendering = ae.Rendering;
const Image = ae.Util.Image;
const Zip = @import("util/Zip.zig");
const TextureAtlas = @import("graphics/TextureAtlas.zig").TextureAtlas;

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
    glyphs,
    rain,
    particles,

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
        .glyphs => if (@import("aether").platform == .psp)
            "crosscraft/textures/interface/controller_glyphs/psp"
        else
            "crosscraft/textures/interface/controller_glyphs/pc",
        .rain => "minecraft/textures/rain",
        .particles => "minecraft/textures/particles",
    };
}

var textures: [Tex.count]Rendering.Texture = undefined;
var tex_loaded: u16 = 0;
var anim_images: [Tex.count]Image.Image = undefined;
var anim_loaded: u16 = 0;

pub var atlas: TextureAtlas = undefined;
var alloc: std.mem.Allocator = undefined;
var pack: *Zip = undefined;

const max_pack_path_len: usize = 256;
var pack_path_buf: [max_pack_path_len]u8 = undefined;
var pack_path_len: usize = 0;
var pack_dir: std.Io.Dir = undefined;

const log = std.log.scoped(.respack);

const tile_size: u32 = 16;
const water_tile_col: u32 = 14;
const water_tile_row: u32 = 0;
const lava_tile_col: u32 = 14;
const lava_tile_row: u32 = 1;
const anim_period_ticks: u32 = 2;

var anim_tick: u32 = 0;
var pack_initialized: bool = false;

/// Open a pack relative to `dir`. Repeated calls keep the current pack open.
pub fn init(
    render_alloc: std.mem.Allocator,
    game_alloc: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    path: []const u8,
) !void {
    if (pack_initialized) return;
    std.debug.assert(path.len > 0 and path.len <= max_pack_path_len);
    alloc = render_alloc;
    tex_loaded = 0;
    anim_loaded = 0;
    anim_tick = 0;
    pack = try Zip.init(game_alloc, io, dir, path);
    @memcpy(pack_path_buf[0..path.len], path);
    pack_path_len = path.len;
    pack_dir = dir;
    pack_initialized = true;
    SoundManager.init(pack, dir, path);
}

pub fn deinit() void {
    if (!pack_initialized) return;
    SoundManager.deinit();
    var i: u8 = 0;
    while (i < Tex.count) : (i += 1) {
        if (tex_loaded & (@as(u16, 1) << @intCast(i)) != 0) {
            textures[i].deinit(alloc);
        }
        if (anim_loaded & (@as(u16, 1) << @intCast(i)) != 0) {
            anim_images[i].deinit(alloc);
        }
    }
    tex_loaded = 0;
    anim_loaded = 0;
    pack.deinit();
    pack_initialized = false;
}

/// Stage all resident textures before swapping archives, preserving cached
/// texture pointers and leaving the current pack intact on failure.
pub fn switch_pack(dir: std.Io.Dir, path: []const u8) !void {
    std.debug.assert(pack_initialized);
    std.debug.assert(path.len > 0 and path.len <= max_pack_path_len);

    if (same_dir(dir, pack_dir) and
        std.mem.eql(u8, path, pack_path_buf[0..pack_path_len])) return;

    const game_alloc = pack.allocator;
    const io_handle = pack.io;

    var new_pack = try Zip.init(game_alloc, io_handle, dir, path);
    errdefer new_pack.deinit();

    var staged_textures: [Tex.count]Rendering.Texture = undefined;
    var staged_tex_mask: u16 = 0;
    var staged_anim_images: [Tex.count]Image.Image = undefined;
    var staged_anim_mask: u16 = 0;

    const old_pack = pack;
    pack = new_pack;

    var i: u8 = 0;
    while (i < Tex.count) : (i += 1) {
        const bit: u16 = @as(u16, 1) << @intCast(i);
        if (tex_loaded & bit == 0) continue;
        staged_textures[i] = load_texture_from_zip(@enumFromInt(i)) catch |err| {
            log.warn("pack '{s}' missing {s}: {}", .{ path, @tagName(@as(Tex, @enumFromInt(i))), err });
            free_staged_textures(&staged_textures, staged_tex_mask);
            pack = old_pack;
            new_pack.deinit();
            return err;
        };
        staged_tex_mask |= bit;
    }

    i = 0;
    while (i < Tex.count) : (i += 1) {
        const bit: u16 = @as(u16, 1) << @intCast(i);
        if (anim_loaded & bit == 0) continue;
        staged_anim_images[i] = load_image_from_zip(@enumFromInt(i)) catch |err| {
            log.warn("pack '{s}' missing {s}: {}", .{ path, @tagName(@as(Tex, @enumFromInt(i))), err });
            free_staged_textures(&staged_textures, staged_tex_mask);
            free_staged_anim_images(&staged_anim_images, staged_anim_mask);
            pack = old_pack;
            new_pack.deinit();
            return err;
        };
        staged_anim_mask |= bit;
    }

    i = 0;
    while (i < Tex.count) : (i += 1) {
        const bit: u16 = @as(u16, 1) << @intCast(i);
        if (staged_tex_mask & bit == 0) continue;
        textures[i].deinit(alloc);
        textures[i] = staged_textures[i];
        switch (@as(Tex, @enumFromInt(i))) {
            .terrain => {
                textures[i].force_resident();
                atlas = TextureAtlas.init(16, 16);
            },
            .logo => textures[i].force_resident(),
            else => {},
        }
    }

    i = 0;
    while (i < Tex.count) : (i += 1) {
        const bit: u16 = @as(u16, 1) << @intCast(i);
        if (staged_anim_mask & bit == 0) continue;
        anim_images[i].deinit(alloc);
        anim_images[i] = staged_anim_images[i];
    }

    old_pack.deinit();

    @memcpy(pack_path_buf[0..path.len], path);
    pack_path_len = path.len;
    pack_dir = dir;

    SoundManager.deinit();
    SoundManager.init(pack, dir, path);

    log.info("switched to pack '{s}'", .{path});
}

fn same_dir(a: std.Io.Dir, b: std.Io.Dir) bool {
    return a.handle == b.handle;
}

pub fn get_tex(id: Tex) *const Rendering.Texture {
    std.debug.assert(!is_anim_source(id));
    const i = @intFromEnum(id);
    std.debug.assert(tex_loaded & (@as(u16, 1) << @intCast(i)) != 0);
    return &textures[i];
}

pub fn load_tex(id: Tex) !void {
    const i = @intFromEnum(id);
    const bit: u16 = @as(u16, 1) << @intCast(i);
    if (is_anim_source(id)) {
        if (anim_loaded & bit != 0) return;
        anim_images[i] = try load_image_from_zip(id);
        anim_loaded |= bit;
        return;
    }

    if (tex_loaded & bit != 0) return;
    textures[i] = try load_texture_from_zip(id);
    tex_loaded |= bit;

    switch (id) {
        .terrain => {
            textures[i].force_resident();
            atlas = TextureAtlas.init(16, 16);
        },
        .logo => textures[i].force_resident(),
        else => {},
    }
}

pub fn unload_tex(id: Tex) void {
    const i = @intFromEnum(id);
    const bit: u16 = @as(u16, 1) << @intCast(i);
    if (is_anim_source(id)) {
        if (anim_loaded & bit == 0) return;
        anim_images[i].deinit(alloc);
        anim_loaded &= ~bit;
        return;
    }

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

pub fn tick_animations() void {
    const t_bit: u16 = @as(u16, 1) << @intFromEnum(Tex.terrain);
    const w_bit: u16 = @as(u16, 1) << @intFromEnum(Tex.water_still);
    const l_bit: u16 = @as(u16, 1) << @intFromEnum(Tex.lava_still);
    std.debug.assert(tex_loaded & t_bit == t_bit);
    std.debug.assert(anim_loaded & (w_bit | l_bit) == (w_bit | l_bit));

    anim_tick +%= 1;
    if (anim_tick % anim_period_ticks != 0) return;

    const water = &anim_images[@intFromEnum(Tex.water_still)];
    const lava = &anim_images[@intFromEnum(Tex.lava_still)];
    const water_frames: u32 = water.height / tile_size;
    const lava_frames: u32 = lava.height / tile_size;
    const step = anim_tick / anim_period_ticks;

    blit_frame(water, step % water_frames, water_tile_col, water_tile_row);
    blit_frame(lava, ping_pong_frame(step, lava_frames), lava_tile_col, lava_tile_row);
    textures[@intFromEnum(Tex.terrain)].update() catch {};
}

// Ping-pong sequence: 0,1,...,N-1,N-2,...,1,0,1,... with period 2*(N-1).
fn ping_pong_frame(step: u32, frames: u32) u32 {
    if (frames <= 1) return 0;
    const period = 2 * (frames - 1);
    const s = step % period;
    return if (s < frames) s else period - s;
}

fn blit_frame(
    src: *const Image.Image,
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
            const px = image_pixel(src, x, src_y0 + y);
            textures[@intFromEnum(Tex.terrain)].set_pixel(dst_x0 + x, dst_y0 + y, px) catch {};
        }
    }
}

fn is_anim_source(id: Tex) bool {
    return switch (id) {
        .water_still, .lava_still => true,
        else => false,
    };
}

fn image_pixel(img: *const Image.Image, x: u32, y: u32) [4]u8 {
    std.debug.assert(img.mode == .rgba8);
    std.debug.assert(x < img.width);
    std.debug.assert(y < img.height);
    const offset = (@as(usize, y) * img.width + x) * 4;
    return img.data[offset..][0..4].*;
}

fn load_texture_from_zip(id: Tex) !Rendering.Texture {
    var buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "assets/{s}.png", .{tex_path(id)});
    var stream = try pack.open(path);
    defer pack.close_stream(&stream);
    return try Rendering.Texture.load_from_reader(alloc, stream.reader, &.{ .cpu_access = .read_write });
}

fn load_image_from_zip(id: Tex) !Image.Image {
    var buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "assets/{s}.png", .{tex_path(id)});
    var stream = try pack.open(path);
    defer pack.close_stream(&stream);
    return try Image.load_png_ex(alloc, alloc, stream.reader, .rgba8);
}

fn free_staged_textures(staged: *[Tex.count]Rendering.Texture, mask: u16) void {
    var i: u8 = 0;
    while (i < Tex.count) : (i += 1) {
        if (mask & (@as(u16, 1) << @intCast(i)) != 0) {
            staged[i].deinit(alloc);
        }
    }
}

fn free_staged_anim_images(staged: *[Tex.count]Image.Image, mask: u16) void {
    var i: u8 = 0;
    while (i < Tex.count) : (i += 1) {
        if (mask & (@as(u16, 1) << @intCast(i)) != 0) {
            staged[i].deinit(alloc);
        }
    }
}
