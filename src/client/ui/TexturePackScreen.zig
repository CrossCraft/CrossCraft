/// Lists every .zip in the user `texturepacks/` folder plus a "Default"
/// entry that restores the bundled `pack.zip`. Selecting a row sets the
/// `pending_select` signal, which MenuState consumes to call
/// `ResourcePack.switch_pack` and re-init dependent systems (sound,
/// font glyph widths). The component array, button labels, and pack
/// path strings are all backed by module-static buffers so this screen
/// allocates nothing per scan.
const std = @import("std");
const ae = @import("aether");
const Rendering = ae.Rendering;

const component = @import("component.zig");
const Component = component.Component;
const Screen = @import("Screen.zig");
const Scaling = @import("Scaling.zig");
const SpriteBatcher = @import("SpriteBatcher.zig");
const FontBatcher = @import("FontBatcher.zig");
const PromptStrip = @import("PromptStrip.zig");
const Prompts = @import("Prompts.zig");

const Options = @import("../Options.zig");

const log = std.log.scoped(.menu);

pub const Context = struct {
    dirt: *const Rendering.Texture,
};

// --- selection signals ---

/// Set after a pack row is clicked. Carries both the dir and the path to
/// hand to `ResourcePack.switch_pack`. MenuState reads and clears.
/// The dir differentiates bundled (resources) from user-installed (data)
/// packs, which live in different places on every platform.
pub const PendingSelect = struct {
    dir: std.Io.Dir,
    path: []const u8,
};
pub var pending_select: ?PendingSelect = null;
/// Set after the "Back" button is clicked. MenuState reads and clears.
pub var pending_back: bool = false;

// --- backing storage ---

const max_packs: u8 = 12;
/// Long enough for "texturepacks/" + a 64-char filename + ".zip".
const max_path_len: u8 = 96;

/// Stores the path string used by `switch_pack` for each entry. Index 0
/// is the bundled default pack; indices 1.. map onto entries scanned out
/// of the texturepacks folder.
var path_buf: [max_packs + 1][max_path_len]u8 = undefined;
var path_lens: [max_packs + 1]u8 = undefined;
/// Dir each entry's path is rooted in (resources for default, data for
/// scanned entries). Kept parallel to `path_buf`.
var dir_buf: [max_packs + 1]std.Io.Dir = undefined;

/// Display label rendered onto each button. May differ from the path
/// string (e.g. "Default" vs "pack.zip", or filename vs full path).
var label_buf: [max_packs + 1][max_path_len]u8 = undefined;
var label_lens: [max_packs + 1]u8 = undefined;

var entry_count: u8 = 0;
/// Index of the currently-active pack entry, or null if none matched.
/// Set by refresh() from Options and overridden immediately on click so
/// the button grays out on the same frame the user selects a pack.
var selected_index: ?u8 = null;

const default_path = "pack.zip";

// 2 fixed components (title, back) + up to (max_packs + 1) selectable rows.
const max_components = max_packs + 1 + 2;
var components_buf: [max_components]Component = undefined;
var component_count: u8 = 0;

// Activation handlers are generated one-per-slot at comptime so each
// click can carry the row index without runtime indirection.
const select_fns = blk: {
    var fns: [max_packs + 1]component.ActivateFn = undefined;
    var i: u8 = 0;
    while (i < max_packs + 1) : (i += 1) {
        fns[i] = make_select_fn(i);
    }
    break :blk fns;
};

fn make_select_fn(comptime idx: u8) component.ActivateFn {
    return struct {
        fn f(_: *anyopaque) void {
            if (idx >= entry_count) return;
            pending_select = .{
                .dir = dir_buf[idx],
                .path = path_buf[idx][0..path_lens[idx]],
            };
            // Gray out the newly-selected entry immediately; MenuState will
            // persist the change when it processes pending_select.
            selected_index = idx;
            rebuild_components();
        }
    }.f;
}

fn on_back(_: *anyopaque) void {
    pending_back = true;
}

/// Determine which entry index matches the persisted active pack, if any.
/// "" in Options means the bundled default (index 0, path "pack.zip");
/// all other stored paths are compared verbatim against the entry paths.
fn find_active_index() ?u8 {
    const saved = Options.current.active_texturepack();
    var i: u8 = 0;
    while (i < entry_count) : (i += 1) {
        const path = path_buf[i][0..path_lens[i]];
        const is_default_entry = std.mem.eql(u8, path, default_path);
        if (is_default_entry) {
            if (saved.len == 0) return i;
        } else {
            if (std.mem.eql(u8, path, saved)) return i;
        }
    }
    return null;
}

// --- scan ---

/// Re-scan the texturepacks folder and rebuild the component layout.
/// Always seeds entry 0 with the bundled default pack so the player can
/// fall back even if the folder is missing or empty. Safe to call
/// repeatedly.
///
/// `resources_dir` is where `pack.zip` lives (bundled assets). `data_dir`
/// hosts the user-writable `texturepacks/` folder.
pub fn refresh(io: std.Io, resources_dir: std.Io.Dir, data_dir: std.Io.Dir) void {
    entry_count = 0;
    pending_select = null;
    pending_back = false;

    add_entry("Default", default_path, resources_dir);

    var dir = data_dir.openDir(io, "texturepacks", .{ .iterate = true }) catch |err| {
        log.warn("texturepacks/ not iterable: {}", .{err});
        selected_index = find_active_index();
        rebuild_components();
        return;
    };
    defer dir.close(io);

    var iter = dir.iterate();
    while (iter.next(io) catch null) |entry| {
        if (entry_count >= max_packs + 1) break;
        if (entry.kind != .file) continue;
        if (entry.name.len < 4) continue;
        const ext = entry.name[entry.name.len - 4 ..];
        if (!std.ascii.eqlIgnoreCase(ext, ".zip")) continue;

        var path_tmp: [max_path_len]u8 = undefined;
        const full_path = std.fmt.bufPrint(&path_tmp, "texturepacks/{s}", .{entry.name}) catch continue;
        const stem = entry.name[0 .. entry.name.len - 4];
        add_entry(stem, full_path, data_dir);
    }

    selected_index = find_active_index();
    rebuild_components();
}

fn add_entry(label: []const u8, path: []const u8, dir: std.Io.Dir) void {
    if (entry_count >= max_packs + 1) return;
    if (label.len > max_path_len or path.len > max_path_len) return;

    @memcpy(label_buf[entry_count][0..label.len], label);
    label_lens[entry_count] = @intCast(label.len);

    @memcpy(path_buf[entry_count][0..path.len], path);
    path_lens[entry_count] = @intCast(path.len);
    dir_buf[entry_count] = dir;

    entry_count += 1;
}

fn rebuild_components() void {
    component_count = 0;

    components_buf[component_count] = .{ .label = .{
        .text = "Select Texture Pack",
        .pos_x = 0,
        .pos_y = 16,
        .color = .white_fg,
        .shadow_color = .menu_gray,
        .reference = .top_center,
        .origin = .top_center,
    } };
    component_count += 1;

    var i: u8 = 0;
    const button_h: i16 = 20;
    const button_w: i16 = 200;
    const row_step: i16 = 22;
    const first_y: i16 = 40;
    while (i < entry_count) : (i += 1) {
        const is_active = if (selected_index) |si| si == i else false;
        components_buf[component_count] = .{ .button = .{
            .label = label_buf[i][0..label_lens[i]],
            .width = button_w,
            .height = button_h,
            .pos_x = 0,
            .pos_y = first_y + @as(i16, @intCast(i)) * row_step,
            .enabled = !is_active,
            .on_activate = select_fns[i],
        } };
        component_count += 1;
    }

    components_buf[component_count] = .{ .button = .{
        .label = "Done",
        .width = button_w,
        .height = button_h,
        .pos_x = 0,
        .pos_y = first_y + @as(i16, @intCast(entry_count)) * row_step + 8,
        .on_activate = on_back,
    } };
    component_count += 1;
}

// --- screen rendering ---

fn draw_underlay(ctx: *anyopaque, sprites: *SpriteBatcher, _: *FontBatcher, _: *const Rendering.Texture) void {
    const menu: *const Context = @ptrCast(@alignCast(ctx));
    const screen_w = Rendering.gfx.surface.get_width();
    const screen_h = Rendering.gfx.surface.get_height();
    const scale = Scaling.compute(screen_w, screen_h);
    const extent_x: i16 = @intCast((screen_w + scale - 1) / scale);
    const extent_y: i16 = @intCast((screen_h + scale - 1) / scale);

    var y: i16 = 0;
    const tile_size: i16 = 32;
    while (y < extent_y) : (y += tile_size) {
        var x: i16 = 0;
        while (x < extent_x) : (x += tile_size) {
            sprites.add_sprite(&.{
                .texture = menu.dirt,
                .pos_offset = .{ .x = x, .y = y },
                .pos_extent = .{ .x = tile_size, .y = tile_size },
                .tex_offset = .{ .x = 0, .y = 0 },
                .tex_extent = .{ .x = @intCast(menu.dirt.width), .y = @intCast(menu.dirt.height) },
                .color = .menu_tiles,
                .layer = 0,
            });
        }
    }
}

fn build_prompts(_: *anyopaque, buf: []PromptStrip.Prompt) []const PromptStrip.Prompt {
    buf[0] = Prompts.select();
    buf[1] = Prompts.back();
    return buf[0..2];
}

pub fn build(ctx: *Context) Screen {
    return .{
        .components = components_buf[0..component_count],
        .ctx = ctx,
        .nav = .stack,
        .draw_underlay = draw_underlay,
        .prompts_fn = build_prompts,
    };
}
