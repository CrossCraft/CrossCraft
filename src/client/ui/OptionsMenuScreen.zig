/// Options menu screen: two-column grid of settings buttons backed by
/// Options.current, plus a grayed-out "Controls..." placeholder and "Done".
///
/// Can be opened from the main menu (dirt background) or the in-game pause
/// menu (dim overlay + elevated layer_base). Callers build the correct
/// variant by populating Context.dirt: non-null = main-menu origin.
///
/// Each option button cycles through a small preset table on click and
/// persists the change immediately via Options.save. Pending flags follow
/// the same read-and-clear convention used by every other UI screen.
const std = @import("std");
const ae = @import("aether");
const Rendering = ae.Rendering;

const component = @import("component.zig");
const Component = component.Component;
const Screen = @import("Screen.zig");
const Scaling = @import("Scaling.zig");
const SpriteBatcher = @import("SpriteBatcher.zig");
const FontBatcher = @import("FontBatcher.zig");
const Color = @import("../graphics/Color.zig").Color;
const Options = @import("../Options.zig");
const config = @import("../config.zig");

pub const Context = struct {
    /// Non-null when opened from the main menu: used for the dirt-tile underlay.
    /// Null when opened from the pause menu: a dim overlay is drawn instead.
    dirt: ?*const Rendering.Texture,
    io: std.Io,
    data_dir: std.Io.Dir,
};

/// Set by the "Done" button; read and cleared by MenuState / GameState.
pub var pending_done: bool = false;

// Layer constants matching PauseMenuScreen when opened in-game.
const DIM_LAYER: u8 = 253;
const LAYER_BASE: u8 = 252;

// -- label storage -----------------------------------------------------------
// Each option button displays the current value as text.  We format into
// these module-level buffers so the Screen can hold stable slices into them.

const label_max = 32;
var lbl_music: [label_max]u8 = undefined;
var lbl_music_len: u8 = 0;
var lbl_sound: [label_max]u8 = undefined;
var lbl_sound_len: u8 = 0;
var lbl_rd: [label_max]u8 = undefined;
var lbl_rd_len: u8 = 0;
var lbl_fancy: [label_max]u8 = undefined;
var lbl_fancy_len: u8 = 0;
var lbl_fov: [label_max]u8 = undefined;
var lbl_fov_len: u8 = 0;
var lbl_ao: [label_max]u8 = undefined;
var lbl_ao_len: u8 = 0;
var lbl_sens: [label_max]u8 = undefined;
var lbl_sens_len: u8 = 0;

// -- component storage -------------------------------------------------------
// 1 title label + 7 option buttons + 1 Controls (disabled) + 1 Done = 10.
const total_components = 10;
var components_buf: [total_components]Component = undefined;

// -- option step tables -------------------------------------------------------

const vol_steps = [_]f32{ 0.0, 0.25, 0.5, 0.75, 1.0 };
const fov_steps = [_]f32{ 60.0, 70.0, 80.0, 90.0, 100.0, 110.0 };
const sens_steps = [_]f32{ 1.0, 2.0, 3.0, 5.0, 10.0 };

/// Find the step closest to `val` and return the next one (wrapping).
fn nearest_next(steps: []const f32, val: f32) f32 {
    var best: usize = 0;
    var best_d: f32 = std.math.floatMax(f32);
    for (steps, 0..) |s, i| {
        const d = @abs(s - val);
        if (d < best_d) {
            best_d = d;
            best = i;
        }
    }
    return steps[(best + 1) % steps.len];
}

fn pct(v: f32) u32 {
    const c = std.math.clamp(v, 0.0, 1.0);
    return @as(u32, @intFromFloat(@round(c * 100.0)));
}

fn bool_str(b: bool) []const u8 {
    return if (b) "ON" else "OFF";
}

fn fmt_label(buf: *[label_max]u8, len: *u8, comptime fmt: []const u8, args: anytype) void {
    const s = std.fmt.bufPrint(buf, fmt, args) catch buf[0..0];
    len.* = @intCast(s.len);
}

// -- label / component rebuild -----------------------------------------------

fn refresh_labels() void {
    const c = Options.current;
    fmt_label(&lbl_music, &lbl_music_len, "Music: {d}%", .{pct(c.music_volume)});
    fmt_label(&lbl_sound, &lbl_sound_len, "Sound: {d}%", .{pct(c.sound_volume)});
    fmt_label(&lbl_rd, &lbl_rd_len, "Render Distance: {d}", .{c.render_distance});
    fmt_label(&lbl_fancy, &lbl_fancy_len, "Fancy Leaves: {s}", .{bool_str(c.fancy_leaves)});
    fmt_label(&lbl_fov, &lbl_fov_len, "FOV: {d}", .{@as(u32, @intFromFloat(c.fov + 0.5))});
    fmt_label(&lbl_ao, &lbl_ao_len, "Ambient Occlusion: {s}", .{bool_str(c.ambient_occlusion)});
    fmt_label(&lbl_sens, &lbl_sens_len, "Sensitivity: {d}", .{@as(u32, @intFromFloat(c.sensitivity + 0.5))});
}

fn rebuild_components() void {
    // Two-column buttons: width 196 with pos_x +-100 from screen center.
    // At 400-pixel minimum logical width this leaves a 2-pixel margin each side.
    const w2: i16 = 196;
    const wf: i16 = 200;
    const bh: i16 = 20;
    const lx: i16 = -100; // left column center offset
    const rx: i16 = 100; // right column center offset

    components_buf[0] = .{ .label = .{
        .text = "Options",
        .pos_x = 0,
        .pos_y = -88,
        .color = .white_fg,
        .shadow_color = .menu_gray,
        .reference = .middle_center,
        .origin = .middle_center,
    } };
    components_buf[1] = .{ .button = .{
        .label = lbl_music[0..lbl_music_len],
        .width = w2,
        .height = bh,
        .pos_x = lx,
        .pos_y = -64,
        .reference = .middle_center,
        .origin = .middle_center,
        .on_activate = on_music,
    } };
    components_buf[2] = .{ .button = .{
        .label = lbl_sound[0..lbl_sound_len],
        .width = w2,
        .height = bh,
        .pos_x = rx,
        .pos_y = -64,
        .reference = .middle_center,
        .origin = .middle_center,
        .on_activate = on_sound,
    } };
    components_buf[3] = .{ .button = .{
        .label = lbl_rd[0..lbl_rd_len],
        .width = w2,
        .height = bh,
        .pos_x = lx,
        .pos_y = -40,
        .reference = .middle_center,
        .origin = .middle_center,
        .on_activate = on_rd,
    } };
    components_buf[4] = .{ .button = .{
        .label = lbl_fancy[0..lbl_fancy_len],
        .width = w2,
        .height = bh,
        .pos_x = rx,
        .pos_y = -40,
        .reference = .middle_center,
        .origin = .middle_center,
        .on_activate = on_fancy,
    } };
    components_buf[5] = .{ .button = .{
        .label = lbl_fov[0..lbl_fov_len],
        .width = w2,
        .height = bh,
        .pos_x = lx,
        .pos_y = -16,
        .reference = .middle_center,
        .origin = .middle_center,
        .on_activate = on_fov,
    } };
    components_buf[6] = .{ .button = .{
        .label = lbl_ao[0..lbl_ao_len],
        .width = w2,
        .height = bh,
        .pos_x = rx,
        .pos_y = -16,
        .reference = .middle_center,
        .origin = .middle_center,
        .on_activate = on_ao,
    } };
    components_buf[7] = .{ .button = .{
        .label = lbl_sens[0..lbl_sens_len],
        .width = w2,
        .height = bh,
        .pos_x = lx,
        .pos_y = 8,
        .reference = .middle_center,
        .origin = .middle_center,
        .on_activate = on_sens,
    } };
    components_buf[8] = .{ .button = .{
        .label = "Controls...",
        .width = wf,
        .height = bh,
        .pos_x = 0,
        .pos_y = 36,
        .reference = .middle_center,
        .origin = .middle_center,
        .enabled = false,
        .on_activate = on_noop,
    } };
    components_buf[9] = .{ .button = .{
        .label = "Done",
        .width = wf,
        .height = bh,
        .pos_x = 0,
        .pos_y = 60,
        .reference = .middle_center,
        .origin = .middle_center,
        .on_activate = on_done,
    } };
}

/// Rebuild label strings and the component array from Options.current.
/// Called once by build() and again after each option change so drawn
/// buttons always reflect the live value.
pub fn refresh() void {
    refresh_labels();
    rebuild_components();
}

// -- activation callbacks ----------------------------------------------------

fn save_options(ctx: *anyopaque) void {
    const c: *const Context = @ptrCast(@alignCast(ctx));
    Options.save(c.io, c.data_dir);
}

fn on_music(ctx: *anyopaque) void {
    Options.current.music_volume = nearest_next(&vol_steps, Options.current.music_volume);
    refresh();
    save_options(ctx);
}

fn on_sound(ctx: *anyopaque) void {
    Options.current.sound_volume = nearest_next(&vol_steps, Options.current.sound_volume);
    refresh();
    save_options(ctx);
}

fn on_rd(ctx: *anyopaque) void {
    const max: u8 = @intCast(@min(@as(u32, 255), config.current.chunk_radius));
    const next: u8 = Options.current.render_distance + 1;
    Options.current.render_distance = if (next > max) 1 else next;
    refresh();
    save_options(ctx);
}

fn on_fancy(ctx: *anyopaque) void {
    Options.current.fancy_leaves = !Options.current.fancy_leaves;
    refresh();
    save_options(ctx);
}

fn on_fov(ctx: *anyopaque) void {
    Options.current.fov = nearest_next(&fov_steps, Options.current.fov);
    refresh();
    save_options(ctx);
}

fn on_ao(ctx: *anyopaque) void {
    Options.current.ambient_occlusion = !Options.current.ambient_occlusion;
    refresh();
    save_options(ctx);
}

fn on_sens(ctx: *anyopaque) void {
    Options.current.sensitivity = nearest_next(&sens_steps, Options.current.sensitivity);
    refresh();
    save_options(ctx);
}

fn on_done(_: *anyopaque) void {
    pending_done = true;
}

fn on_noop(_: *anyopaque) void {}

// -- draw underlays ----------------------------------------------------------

fn draw_dirt_underlay(ctx: *anyopaque, sprites: *SpriteBatcher, _: *FontBatcher, _: *const Rendering.Texture) void {
    const menu: *const Context = @ptrCast(@alignCast(ctx));
    const dirt = menu.dirt.?;
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
                .texture = dirt,
                .pos_offset = .{ .x = x, .y = y },
                .pos_extent = .{ .x = tile_size, .y = tile_size },
                .tex_offset = .{ .x = 0, .y = 0 },
                .tex_extent = .{ .x = @intCast(dirt.width), .y = @intCast(dirt.height) },
                .color = .menu_tiles,
                .layer = 0,
            });
        }
    }
}

fn draw_dim_underlay(_: *anyopaque, sprites: *SpriteBatcher, _: *FontBatcher, _: *const Rendering.Texture) void {
    const screen_w = Rendering.gfx.surface.get_width();
    const screen_h = Rendering.gfx.surface.get_height();
    const scale = Scaling.compute(screen_w, screen_h);
    const extent_x: i16 = @intCast((screen_w + scale - 1) / scale);
    const extent_y: i16 = @intCast((screen_h + scale - 1) / scale);

    sprites.add_sprite(&.{
        .texture = &Rendering.Texture.Default,
        .pos_offset = .{ .x = 0, .y = 0 },
        .pos_extent = .{ .x = extent_x, .y = extent_y },
        .tex_offset = .{ .x = 0, .y = 0 },
        .tex_extent = .{ .x = 1, .y = 1 },
        .color = Color.rgba(0, 0, 0, 160),
        .layer = DIM_LAYER,
        .reference = .top_left,
        .origin = .top_left,
    });
}

// -- public API --------------------------------------------------------------

pub fn build(ctx: *Context) Screen {
    refresh();
    pending_done = false;
    return .{
        .components = components_buf[0..],
        .ctx = ctx,
        .nav = .stack,
        .draw_underlay = if (ctx.dirt != null) draw_dirt_underlay else draw_dim_underlay,
        .layer_base = if (ctx.dirt != null) 0 else LAYER_BASE,
    };
}
