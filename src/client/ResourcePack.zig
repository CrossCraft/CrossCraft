/// Game asset names and animation policy over Aether's staged resource store.
const SoundManager = @import("SoundManager.zig");
const std = @import("std");
const assert = std.debug.assert;
const ae = @import("aether");
const caps = @import("capabilities").ClientType(ae);
const Rendering = ae.Rendering;
const Image = ae.Util.Image;
const Zip = ae.Util.Zip;
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
        .glyphs => caps.resources.glyph_texture,
        .rain => "minecraft/textures/rain",
        .particles => "minecraft/textures/particles",
    };
}

const asset_paths: [Tex.count][]const u8 = blk: {
    var paths: [Tex.count][]const u8 = undefined;
    for (0..Tex.count) |i| paths[i] = "assets/" ++ tex_path(@enumFromInt(i)) ++ ".png";
    break :blk paths;
};
const Animation = struct { image: Image.Image, flipbook: Rendering.Flipbook };
const Asset = union(enum) { texture: Rendering.Texture, animation: Animation };
const Store = ae.Resources.AssetStore(Asset);
var assets: Store = undefined;
var active_mask: u16 = 0;

pub const atlas = TextureAtlas.init_grid(16, 16);
var pack: *Zip = undefined;
const archive_options: Zip.Options = .{
    // Keep one reader available for textures while all game voices are active.
    .max_streams = caps.audio.max_voices + 1,
    // Two compressed audio voices plus one texture/animation decoder.
    .max_deflate_streams = 3,
};
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

/// Open a pack relative to dir. Repeated calls keep the current pack open.
pub fn init(render_alloc: std.mem.Allocator, game_alloc: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, path: []const u8) !void {
    if (pack_initialized) return;
    assert(path.len > 0 and path.len <= max_pack_path_len);
    pack = try Zip.init_options(game_alloc, io, dir, path, archive_options);
    assets = Store.init(render_alloc, .{ .load = load_asset, .destroy = destroy_asset }, Tex.count);
    active_mask = 0;
    anim_tick = 0;
    @memcpy(pack_path_buf[0..path.len], path);
    pack_path_len = path.len;
    pack_dir = dir;
    pack_initialized = true;
    SoundManager.init(pack);
}

pub fn deinit() void {
    if (!pack_initialized) return;
    // Stop backend reads and release all owned audio sources before the archive.
    SoundManager.deinit();
    assets.deinit();
    active_mask = 0;
    pack.deinit();
    pack = undefined;
    pack_initialized = false;
}

/// One union store stages both GPU textures and CPU animation images. Retained
/// texture addresses survive a successful reload; failure leaves the active pack
/// and sounds intact. Audio is restarted only after the asset commit succeeds.
pub fn switch_pack(dir: std.Io.Dir, path: []const u8) !void {
    assert(pack_initialized);
    assert(path.len > 0 and path.len <= max_pack_path_len);
    if (dir.handle == pack_dir.handle and std.mem.eql(u8, path, pack_path_buf[0..pack_path_len])) return;

    const replacement = try Zip.init_options(pack.allocator, pack.io, dir, path, archive_options);
    errdefer replacement.deinit();

    var paths: [Tex.count][]const u8 = undefined;
    var count: usize = 0;
    for (0..Tex.count) |i| {
        if (active_mask & (@as(u16, 1) << @intCast(i)) == 0) continue;
        paths[count] = asset_paths[i];
        count += 1;
    }
    assets.apply(replacement.source(), paths[0..count]) catch |err| {
        log.warn("cannot load pack '{s}': {}", .{ path, err });
        return err;
    };

    SoundManager.deinit();
    pack.deinit();
    pack = replacement;
    @memcpy(pack_path_buf[0..path.len], path);
    pack_path_len = path.len;
    pack_dir = dir;
    SoundManager.init(pack);
    log.info("switched to pack '{s}'", .{path});
}

pub fn get_tex(id: Tex) *const Rendering.Texture {
    assert(!is_anim_source(id));
    return &get_asset(id).texture;
}

fn get_asset(id: Tex) *Asset {
    assert(active_mask & (@as(u16, 1) << @intCast(@intFromEnum(id))) != 0);
    return assets.get(asset_paths[@intFromEnum(id)]).?;
}

/// Stage additions before dropping obsolete resources. Retained assets are not
/// decoded or uploaded again when only the game state's requested set changes.
pub fn apply_tex_set(set: []const Tex) !void {
    var paths: [Tex.count][]const u8 = undefined;
    var count: usize = 0;
    var requested_mask: u16 = 0;
    for (set) |id| {
        const bit = @as(u16, 1) << @intCast(@intFromEnum(id));
        if (requested_mask & bit != 0) continue;
        requested_mask |= bit;
        paths[count] = asset_paths[@intFromEnum(id)];
        count += 1;
    }
    try assets.apply_options(pack.source(), paths[0..count], .{ .reload_existing = false });
    active_mask = requested_mask;
}

pub fn tick_animations() void {
    const terrain = &get_asset(.terrain).texture;
    const water = &get_asset(.water_still).animation;
    const lava = &get_asset(.lava_still).animation;
    anim_tick +%= 1;
    if (anim_tick % anim_period_ticks != 0) return;
    const step: f64 = @floatFromInt(anim_tick / anim_period_ticks);
    blit_frame(terrain, water, step, water_tile_col, water_tile_row);
    blit_frame(terrain, lava, step, lava_tile_col, lava_tile_row);
    terrain.update() catch {};
}

fn blit_frame(destination: *Rendering.Texture, animation: *const Animation, step: f64, col: u32, row: u32) void {
    const frame = animation.flipbook.frame_at(step) catch unreachable;
    animation.flipbook.copy_to_texture(destination, animation.image.view(), frame, col * tile_size, row * tile_size) catch |err| {
        log.warn("animation copy failed: {}", .{err});
    };
}

fn is_anim_source(id: Tex) bool {
    return id == .water_still or id == .lava_still;
}

fn load_asset(_: ?*anyopaque, allocator: std.mem.Allocator, path: []const u8, reader: *std.Io.Reader) !Asset {
    const id: Tex = for (asset_paths, 0..) |candidate, i| {
        if (std.mem.eql(u8, candidate, path)) break @enumFromInt(i);
    } else return error.UnknownAsset;
    if (is_anim_source(id)) {
        const image = try Image.load_png_ex(allocator, allocator, reader, .rgba8);
        return .{ .animation = try make_animation(allocator, image, if (id == .lava_still) .ping_pong else .loop) };
    }
    var texture = try Rendering.Texture.load_from_reader(allocator, reader, &.{ .cpu_access = .read_write });
    errdefer texture.deinit(allocator);

    // Animation destination regions must be valid before a staged set commits.
    if (id == .terrain and (texture.width < (water_tile_col + 1) * tile_size or texture.height < (lava_tile_row + 1) * tile_size)) return error.InvalidTerrainTexture;
    if (id == .terrain or id == .logo) texture.force_resident();
    return .{ .texture = texture };
}

fn destroy_asset(_: ?*anyopaque, allocator: std.mem.Allocator, asset: *Asset) void {
    switch (asset.*) {
        .texture => |*texture| texture.deinit(allocator),
        .animation => |*animation| animation.image.deinit(allocator),
    }
}

/// Preserve the pack's vertical first-column animation convention. Extra source
/// columns and incomplete trailing rows are cropped once when the image loads.
fn make_animation(allocator: std.mem.Allocator, image: Image.Image, playback: Rendering.Flipbook.Playback) !Animation {
    var owned = image;
    errdefer owned.deinit(allocator);

    if (owned.width < tile_size or owned.height < tile_size) return error.InvalidAnimation;
    const height = owned.height / tile_size * tile_size;
    if (owned.width != tile_size or owned.height != height) {
        const byte_count = std.math.mul(usize, tile_size * 4, height) catch return error.InvalidAnimation;
        var cropped: Image.Image = .{
            .width = tile_size,
            .height = height,
            .mode = .rgba8,
            .data = try allocator.alignedAlloc(u8, .fromByteUnits(16), byte_count),
        };
        errdefer cropped.deinit(allocator);

        try cropped.copy_region(owned.view(), .{ .width = tile_size, .height = height }, 0, 0);
        owned.deinit(allocator);
        owned = cropped;
    }
    return .{
        .image = owned,
        // The game supplies integer animation steps, so one second represents
        // one original step; tick cadence remains exactly two game ticks.
        .flipbook = try Rendering.Flipbook.init(owned.view(), .{
            .frame_width = tile_size,
            .frame_height = tile_size,
            .frame_count = height / tile_size,
            .frames_per_second = 1,
            .playback = playback,
        }),
    };
}

fn check_animation(allocator: std.mem.Allocator) !void {
    var image: Image.Image = .{
        .width = 32,
        .height = 34,
        .mode = .rgba8,
        .data = try allocator.alignedAlloc(u8, .fromByteUnits(16), 32 * 34 * 4),
    };
    for (0..34) |y| for (0..32) |x| {
        const offset = (y * 32 + x) * 4;
        const red: u8 = if (x >= 16) 99 else if (y >= 32) 88 else if (y >= 16) 2 else 1;
        @memcpy(image.data[offset..][0..4], &[_]u8{ red, 0, 0, 255 });
    };
    var animation = try make_animation(allocator, image, .ping_pong);
    defer animation.image.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 16), animation.image.width);
    try std.testing.expectEqual(@as(u32, 32), animation.image.height);
    for ([_]u32{ 0, 1, 0, 1, 0 }, 0..) |frame, step| {
        try std.testing.expectEqual(frame, try animation.flipbook.frame_at(@floatFromInt(step)));
    }
    var target: [16 * 16 * 4]u8 = undefined;
    try animation.flipbook.copy_to_image(.{ .width = 16, .height = 16, .data = &target }, animation.image.view(), 1, 0, 0);
    for (0..16 * 16) |i| try std.testing.expectEqualSlices(u8, &.{ 2, 0, 0, 255 }, target[i * 4 ..][0..4]);
}

test "resource animation migration preserves vertical frames and ping pong cadence" {
    try check_animation(std.testing.allocator);
    try std.testing.checkAllAllocationFailures(std.testing.allocator, check_animation, .{});
}

test "resource store migration stages mixed assets without invalidating active textures" {
    if (!caps.render.headless) return error.SkipZigTest;
    const t = std.testing;
    const pixel = @embedFile("util/testdata/pixel.png");
    var first: ae.Resources.MemorySource = .{ .allocator = t.allocator, .files = &.{.{ .path = asset_paths[@intFromEnum(Tex.dirt)], .bytes = pixel }} };
    var broken: ae.Resources.MemorySource = .{ .allocator = t.allocator, .files = &.{
        .{ .path = asset_paths[@intFromEnum(Tex.dirt)], .bytes = pixel },
        .{ .path = asset_paths[@intFromEnum(Tex.water_still)], .bytes = "not a PNG" },
    } };
    var store = Store.init(t.allocator, .{ .load = load_asset, .destroy = destroy_asset }, Tex.count);
    defer store.deinit();

    const dirt = asset_paths[@intFromEnum(Tex.dirt)];
    try store.apply(first.source(), &.{dirt});
    const stable = &store.get(dirt).?.texture;
    const original_handle = stable.handle;
    try t.expectError(error.InvalidPNG, store.apply(broken.source(), &.{ dirt, asset_paths[@intFromEnum(Tex.water_still)] }));
    try t.expect(stable == &store.get(dirt).?.texture);
    try t.expectEqual(original_handle, stable.handle);
    try store.apply(first.source(), &.{dirt});
    try t.expect(stable == &store.get(dirt).?.texture);
}
