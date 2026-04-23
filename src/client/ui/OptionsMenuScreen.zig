/// Options menu screen: two-column grid of settings buttons backed by
/// Options.current, plus a grayed-out "Controls..." placeholder and "Done".
///
/// Can be opened from the main menu (dirt background) or the in-game pause
/// menu (dim overlay + elevated layer_base). Callers build the correct
/// variant by populating Context.dirt: non-null = main-menu origin.
///
/// Clicking an option cycles its value instantly with no disk I/O. The
/// caller (MenuState / GameState) saves options.json once when the screen
/// is dismissed, keeping the render loop free of blocking writes.
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
const PromptStrip = @import("PromptStrip.zig");
const Prompts = @import("Prompts.zig");

pub const Context = struct {
    /// Non-null when opened from the main menu: used for the dirt-tile underlay.
    /// Null when opened from the pause menu: a dim overlay is drawn instead.
    dirt: ?*const Rendering.Texture,
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
var lbl_ct: [label_max]u8 = undefined;
var lbl_ct_len: u8 = 0;
var lbl_bouncy: [label_max]u8 = undefined;
var lbl_bouncy_len: u8 = 0;
var lbl_vsync: [label_max]u8 = undefined;
var lbl_vsync_len: u8 = 0;
var lbl_rain: [label_max]u8 = undefined;
var lbl_rain_len: u8 = 0;

// -- component storage -------------------------------------------------------
// 1 title label + 11 option buttons + 1 Controls (disabled) + 1 Done = 14.
const total_components = 14;
var components_buf: [total_components]Component = undefined;

// -- option step tables -------------------------------------------------------

const vol_steps = [_]f32{ 0.0, 0.25, 0.5, 0.75, 1.0 };
const fov_steps = [_]f32{ 60.0, 70.0, 80.0, 90.0, 100.0, 110.0 };
const sens_steps = [_]f32{ 1.0, 2.0, 3.0, 5.0, 10.0 };

const ct_modes_desktop = [_]Options.ControllerTooltips{ .auto, .xbox, .playstation, .nintendo, .off };
const ct_modes_psp = [_]Options.ControllerTooltips{ .auto, .off };
const ct_modes: []const Options.ControllerTooltips =
    if (ae.platform == .psp) &ct_modes_psp else &ct_modes_desktop;

fn ct_display(m: Options.ControllerTooltips) []const u8 {
    return switch (m) {
        .auto => "Auto",
        .xbox => "Xbox",
        .playstation => "PlayStation",
        .nintendo => "Nintendo",
        .off => "Off",
    };
}

fn next_ct(cur: Options.ControllerTooltips) Options.ControllerTooltips {
    for (ct_modes, 0..) |m, i| if (m == cur) return ct_modes[(i + 1) % ct_modes.len];
    return .auto;
}

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
    fmt_label(&lbl_rd, &lbl_rd_len, "Render Distance: {d}", .{Options.capped_render_distance()});
    fmt_label(&lbl_fancy, &lbl_fancy_len, "Fancy Leaves: {s}", .{bool_str(c.fancy_leaves)});
    fmt_label(&lbl_fov, &lbl_fov_len, "FOV: {d}", .{@as(u32, @intFromFloat(c.fov + 0.5))});
    fmt_label(&lbl_ao, &lbl_ao_len, "Ambient Occlusion: {s}", .{bool_str(c.ambient_occlusion)});
    fmt_label(&lbl_sens, &lbl_sens_len, "Sensitivity: {d}", .{@as(u32, @intFromFloat(c.sensitivity + 0.5))});
    fmt_label(&lbl_ct, &lbl_ct_len, "Controllers: {s}", .{ct_display(c.controller_tooltips)});
    fmt_label(&lbl_bouncy, &lbl_bouncy_len, "Bouncy Chunks: {s}", .{bool_str(c.bouncy_chunks)});
    fmt_label(&lbl_vsync, &lbl_vsync_len, "VSync: {s}", .{bool_str(c.vsync)});
    fmt_label(&lbl_rain, &lbl_rain_len, "Rain: {s}", .{bool_str(c.rain)});
}

fn rebuild_components() void {
    // Two-column buttons: width 196 with pos_x +-100 from screen center.
    // At 400-pixel minimum logical width this leaves a 2-pixel margin each side.
    // Array order is row-major across the two columns so grid nav maps cleanly:
    // index = row * 2 + col. The title label and centered Controls/Done still
    // sit in that virtual grid but are either unfocusable or span a row.
    const w2: i16 = 196;
    const wf: i16 = 200;
    const bh: i16 = 20;
    const lx: i16 = -100; // left column center offset
    const rx: i16 = 100; // right column center offset

    // Row 0: Music (L) | Sound (R)
    components_buf[0] = .{ .button = .{
        .label = lbl_music[0..lbl_music_len],
        .width = w2,
        .height = bh,
        .pos_x = lx,
        .pos_y = -72,
        .reference = .middle_center,
        .origin = .middle_center,
        .on_activate = on_music,
    } };
    components_buf[1] = .{ .button = .{
        .label = lbl_sound[0..lbl_sound_len],
        .width = w2,
        .height = bh,
        .pos_x = rx,
        .pos_y = -72,
        .reference = .middle_center,
        .origin = .middle_center,
        .on_activate = on_sound,
    } };
    // Row 1: Render Distance (L) | Fancy Leaves (R)
    components_buf[2] = .{ .button = .{
        .label = lbl_rd[0..lbl_rd_len],
        .width = w2,
        .height = bh,
        .pos_x = lx,
        .pos_y = -48,
        .reference = .middle_center,
        .origin = .middle_center,
        .on_activate = on_rd,
    } };
    components_buf[3] = .{ .button = .{
        .label = lbl_fancy[0..lbl_fancy_len],
        .width = w2,
        .height = bh,
        .pos_x = rx,
        .pos_y = -48,
        .reference = .middle_center,
        .origin = .middle_center,
        .enabled = Options.fancy_leaves_supported(),
        .on_activate = on_fancy,
    } };
    // Row 2: FOV (L) | Ambient Occlusion (R)
    components_buf[4] = .{ .button = .{
        .label = lbl_fov[0..lbl_fov_len],
        .width = w2,
        .height = bh,
        .pos_x = lx,
        .pos_y = -24,
        .reference = .middle_center,
        .origin = .middle_center,
        .on_activate = on_fov,
    } };
    components_buf[5] = .{ .button = .{
        .label = lbl_ao[0..lbl_ao_len],
        .width = w2,
        .height = bh,
        .pos_x = rx,
        .pos_y = -24,
        .reference = .middle_center,
        .origin = .middle_center,
        .on_activate = on_ao,
    } };
    // Row 3: Sensitivity (L) | Controllers (R)
    components_buf[6] = .{ .button = .{
        .label = lbl_sens[0..lbl_sens_len],
        .width = w2,
        .height = bh,
        .pos_x = lx,
        .pos_y = 0,
        .reference = .middle_center,
        .origin = .middle_center,
        .on_activate = on_sens,
    } };
    components_buf[7] = .{ .button = .{
        .label = lbl_ct[0..lbl_ct_len],
        .width = w2,
        .height = bh,
        .pos_x = rx,
        .pos_y = 0,
        .reference = .middle_center,
        .origin = .middle_center,
        .on_activate = on_ct,
    } };
    // Row 4: Bouncy Chunks (L) | VSync (R)
    components_buf[8] = .{ .button = .{
        .label = lbl_bouncy[0..lbl_bouncy_len],
        .width = w2,
        .height = bh,
        .pos_x = lx,
        .pos_y = 24,
        .reference = .middle_center,
        .origin = .middle_center,
        .on_activate = on_bouncy,
    } };
    components_buf[9] = .{ .button = .{
        .label = lbl_vsync[0..lbl_vsync_len],
        .width = w2,
        .height = bh,
        .pos_x = rx,
        .pos_y = 24,
        .reference = .middle_center,
        .origin = .middle_center,
        .on_activate = on_vsync,
    } };
    // Row 5: Rain (L) | Controls (R, disabled).
    components_buf[10] = .{ .button = .{
        .label = lbl_rain[0..lbl_rain_len],
        .width = w2,
        .height = bh,
        .pos_x = lx,
        .pos_y = 48,
        .reference = .middle_center,
        .origin = .middle_center,
        .on_activate = on_rain,
    } };
    components_buf[11] = .{ .button = .{
        .label = "Controls...",
        .width = w2,
        .height = bh,
        .pos_x = rx,
        .pos_y = 48,
        .reference = .middle_center,
        .origin = .middle_center,
        .enabled = false,
        .on_activate = on_noop,
    } };
    // Row 6: Done spans the row, drawn centered.
    components_buf[12] = .{ .button = .{
        .label = "Done",
        .width = wf,
        .height = bh,
        .pos_x = 0,
        .pos_y = 72,
        .reference = .middle_center,
        .origin = .middle_center,
        .on_activate = on_done,
    } };
    // Title is unfocusable; parked past the interactive grid so nav math stays clean.
    components_buf[13] = .{ .label = .{
        .text = "Options",
        .pos_x = 0,
        .pos_y = -96,
        .color = .white_fg,
        .shadow_color = .menu_gray,
        .reference = .middle_center,
        .origin = .middle_center,
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
// No disk I/O here: callers (MenuState / GameState) write options.json once
// when the screen is dismissed, keeping every click free of blocking writes.

fn on_music(_: *anyopaque) void {
    Options.current.music_volume = nearest_next(&vol_steps, Options.current.music_volume);
    refresh();
}

fn on_sound(_: *anyopaque) void {
    Options.current.sound_volume = nearest_next(&vol_steps, Options.current.sound_volume);
    refresh();
}

fn on_rd(_: *anyopaque) void {
    const max: u8 = @intCast(@min(@as(u32, 255), config.current.chunk_radius));
    // Cycle from the effective (capped) value so a stale stored value above
    // the platform max does not produce a confusing first-click skip.
    const cur: u8 = Options.capped_render_distance();
    Options.current.render_distance = if (cur + 1 > max) 1 else cur + 1;
    refresh();
}

fn on_fancy(_: *anyopaque) void {
    Options.current.fancy_leaves = !Options.current.fancy_leaves;
    refresh();
}

fn on_fov(_: *anyopaque) void {
    Options.current.fov = nearest_next(&fov_steps, Options.current.fov);
    refresh();
}

fn on_ao(_: *anyopaque) void {
    Options.current.ambient_occlusion = !Options.current.ambient_occlusion;
    refresh();
}

fn on_sens(_: *anyopaque) void {
    Options.current.sensitivity = nearest_next(&sens_steps, Options.current.sensitivity);
    refresh();
}

fn on_ct(_: *anyopaque) void {
    Options.current.controller_tooltips = next_ct(Options.current.controller_tooltips);
    refresh();
}

fn on_bouncy(_: *anyopaque) void {
    Options.current.bouncy_chunks = !Options.current.bouncy_chunks;
    refresh();
}

fn on_vsync(_: *anyopaque) void {
    Options.current.vsync = !Options.current.vsync;
    refresh();
}

fn on_rain(_: *anyopaque) void {
    Options.current.rain = !Options.current.rain;
    refresh();
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

fn build_prompts(_: *anyopaque, buf: []PromptStrip.Prompt) []const PromptStrip.Prompt {
    buf[0] = Prompts.select();
    buf[1] = Prompts.back();
    return buf[0..2];
}

pub fn build(ctx: *Context) Screen {
    refresh();
    pending_done = false;
    return .{
        .components = components_buf[0..],
        .ctx = ctx,
        .nav = .grid,
        .row_width = 2,
        .draw_underlay = if (ctx.dirt != null) draw_dirt_underlay else draw_dim_underlay,
        .layer_base = if (ctx.dirt != null) 0 else LAYER_BASE,
        .prompts_fn = build_prompts,
    };
}
