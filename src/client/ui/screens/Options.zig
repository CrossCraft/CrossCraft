const std = @import("std");
const ae = @import("aether");

const Ui = @import("../Ui.zig");
const Options = @import("../../Options.zig");
const Prompts = @import("../Prompts.zig");
const config = @import("../../config.zig");
const widget_id = @import("../widget_id.zig");

pub const Widget = enum(u16) {
    music = 1,
    sound = 2,
    fov = 3,
    sensitivity = 4,
    render_distance = 5,
    fancy_leaves = 6,
    ambient_occlusion = 7,
    controller_tooltips = 8,
    bouncy_chunks = 9,
    vsync = 10,
    rain = 11,
    done = 12,
    controls_placeholder = 13,
    fog = 14,
    _,
};

pub const DIM_LAYER: u8 = 1;
pub const LAYER_BASE: u8 = 2;
pub const WIDGET_W: i16 = 150;
pub const SENS_MIN: f32 = 0.1;
pub const SENS_MAX: f32 = 10.0;

pub const Hooks = struct {
    on_fov_changed: ?*const fn () void = null,
};

pub fn wid(w: Widget) widget_id.WidgetId {
    return widget_id.from(Widget, w);
}

pub fn run(ui: *Ui, opt: *Options.Options, rd_view: *f32, hooks: Hooks) bool {
    var col = ui.stack(.{ .axis = .vertical, .anchor = .middle_center, .cross_align = .center, .gap = 4 });
    var close = false;

    ui.label("Options");
    {
        var row = ui.stack(.{ .axis = .horizontal, .gap = 4 });
        defer row.end();
        _ = ui.slider(wid(.music), &opt.music_volume, .{
            .label = ui.fmt("Music: {d}%", .{pct_round(opt.music_volume)}),
            .width = WIDGET_W,
            .min = 0,
            .max = 1,
            .nudge = 0.05,
        });
        _ = ui.slider(wid(.sound), &opt.sound_volume, .{
            .label = ui.fmt("Sound: {d}%", .{pct_round(opt.sound_volume)}),
            .width = WIDGET_W,
            .min = 0,
            .max = 1,
            .nudge = 0.05,
        });
    }
    {
        var row = ui.stack(.{ .axis = .horizontal, .gap = 4 });
        defer row.end();
        if (ui.slider(wid(.fov), &opt.fov, .{
            .label = ui.fmt("FOV: {d}", .{@as(u32, @intFromFloat(@round(opt.fov)))}),
            .width = WIDGET_W,
            .min = 30,
            .max = 110,
            .nudge = 0.0625,
        })) {
            opt.fov = std.math.clamp(opt.fov, 30, 110);
            if (hooks.on_fov_changed) |f| f();
        }
        _ = ui.slider(wid(.sensitivity), &opt.sensitivity, .{
            .label = ui.fmt("Sensitivity: {d}%", .{sens_pct(opt.sensitivity)}),
            .width = WIDGET_W,
            .min = SENS_MIN,
            .max = SENS_MAX,
            .nudge = 0.05,
            .scale = .log10,
        });
    }
    {
        var row = ui.stack(.{ .axis = .horizontal, .gap = 4 });
        defer row.end();
        const rd_max_u8: u8 = @intCast(@min(@as(u32, 255), config.current.chunk_radius));
        const rd_max: f32 = @floatFromInt(rd_max_u8);
        if (ui.slider(wid(.render_distance), rd_view, .{
            .label = ui.fmt("Render Distance: {d}", .{Options.capped_render_distance()}),
            .width = WIDGET_W,
            .min = 1,
            .max = rd_max,
            .nudge = if (rd_max_u8 > 1) 1.0 / (rd_max - 1.0) else 0.05,
        })) {
            const rounded: u8 = @intFromFloat(std.math.clamp(@round(rd_view.*), 1.0, rd_max));
            opt.render_distance = rounded;
            rd_view.* = @floatFromInt(rounded);
        }
        if (ui.button(wid(.fog), ui.fmt("Fog: {s}", .{bool_str(opt.fog)}), .{ .width = WIDGET_W })) {
            opt.fog = !opt.fog;
        }
    }

    cycle_row(
        ui,
        opt,
        .{ .id = .fancy_leaves, .label = "Fancy Leaves", .field = .fancy_leaves, .enabled = Options.fancy_leaves_supported() },
        .{ .id = .ambient_occlusion, .label = "Ambient Occlusion", .field = .ambient_occlusion },
    );
    {
        var row = ui.stack(.{ .axis = .horizontal, .gap = 4 });
        defer row.end();
        if (ui.button(wid(.controller_tooltips), ui.fmt("Controllers: {s}", .{ct_label(opt.controller_tooltips)}), .{ .width = WIDGET_W })) {
            opt.controller_tooltips = ct_next(opt.controller_tooltips);
        }
        if (ui.button(wid(.bouncy_chunks), ui.fmt("Bouncy Chunks: {s}", .{bool_str(opt.bouncy_chunks)}), .{ .width = WIDGET_W })) {
            opt.bouncy_chunks = !opt.bouncy_chunks;
        }
    }
    cycle_row(
        ui,
        opt,
        .{ .id = .vsync, .label = "VSync", .field = .vsync },
        .{ .id = .rain, .label = "Rain", .field = .rain },
    );

    _ = ui.button(wid(.controls_placeholder), "Controls...", .{ .width = WIDGET_W, .enabled = false });

    if (ui.button(wid(.done), "Done", .{ .width = WIDGET_W })) {
        ui.close_request();
        close = true;
    }
    col.end();
    ui.prompts(&.{ Prompts.select(), Prompts.back() });
    return close or ui.close_requested or ui.cancel_pressed();
}

const Toggle = struct {
    id: Widget,
    label: []const u8,
    field: enum { fancy_leaves, ambient_occlusion, vsync, rain, fog },
    enabled: bool = true,
};

fn cycle_row(ui: *Ui, opt: *Options.Options, a: Toggle, b: Toggle) void {
    var row = ui.stack(.{ .axis = .horizontal, .gap = 4 });
    defer row.end();
    inline for (.{ a, b }) |t| {
        const ptr = switch (t.field) {
            .fancy_leaves => &opt.fancy_leaves,
            .ambient_occlusion => &opt.ambient_occlusion,
            .vsync => &opt.vsync,
            .rain => &opt.rain,
            .fog => &opt.fog,
        };
        if (ui.button(wid(t.id), ui.fmt("{s}: {s}", .{ t.label, bool_str(ptr.*) }), .{ .width = WIDGET_W, .enabled = t.enabled })) {
            ptr.* = !ptr.*;
        }
    }
}

fn pct_round(v: f32) u32 {
    return @intFromFloat(@round(std.math.clamp(v, 0, 1) * 100));
}

pub fn sens_pct(v: f32) u32 {
    const cl = std.math.clamp(v, SENS_MIN, SENS_MAX);
    const lmin = std.math.log10(SENS_MIN);
    const lmax = std.math.log10(SENS_MAX);
    return @intFromFloat(@round((std.math.log10(cl) - lmin) / (lmax - lmin) * 100));
}

fn bool_str(b: bool) []const u8 {
    return if (b) "ON" else "OFF";
}

fn ct_label(m: Options.ControllerTooltips) []const u8 {
    return switch (m) {
        .auto => "Auto",
        .xbox => "Xbox",
        .playstation => "PlayStation",
        .nintendo => "Nintendo",
        .off => "Off",
    };
}

fn ct_next(cur: Options.ControllerTooltips) Options.ControllerTooltips {
    const modes = if (ae.platform == .psp)
        [_]Options.ControllerTooltips{ .auto, .off }
    else
        [_]Options.ControllerTooltips{ .auto, .xbox, .playstation, .nintendo, .off };
    for (modes, 0..) |m, i| if (m == cur) return modes[(i + 1) % modes.len];
    return .auto;
}
