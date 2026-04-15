/// In-game pause menu: vertical button stack drawn on top of the live game
/// scene with a translucent dim overlay. SP and MP use distinct component
/// arrays so the bottom button reads "Save and quit to menu" or "Disconnect"
/// and so "Save level..." is disabled in MP.
///
/// Activation callbacks set module-level pending flags read+cleared by
/// GameState.update each frame, matching the convention used by
/// MainMenuScreen.
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

pub const Context = struct {};

// Layer ordering: HUD tops out at 252 (inventory tooltip). The dim quad
// sits one layer above so it obscures the HUD; pause components draw on
// top via screen.layer_base.
pub const DIM_LAYER: u8 = 253;
pub const LAYER_BASE: u8 = 252;

const sp_components = [_]Component{
    .{ .label = .{
        .text = "Game menu",
        .pos_x = 0,
        .pos_y = -72,
        .reference = .middle_center,
        .origin = .middle_center,
    } },
    .{ .button = .{
        .label = "Back to game",
        .width = 200,
        .height = 20,
        .pos_x = 0,
        .pos_y = -36,
        .reference = .middle_center,
        .origin = .middle_center,
        .on_activate = on_resume,
    } },
    .{ .button = .{
        .label = "Options...",
        .width = 200,
        .height = 20,
        .pos_x = 0,
        .pos_y = -12,
        .reference = .middle_center,
        .origin = .middle_center,
        .on_activate = on_noop,
    } },
    .{ .button = .{
        .label = "Save level...",
        .width = 200,
        .height = 20,
        .pos_x = 0,
        .pos_y = 12,
        .reference = .middle_center,
        .origin = .middle_center,
        .on_activate = on_save,
    } },
    .{ .button = .{
        .label = "Save and quit to menu",
        .width = 200,
        .height = 20,
        .pos_x = 0,
        .pos_y = 36,
        .reference = .middle_center,
        .origin = .middle_center,
        .on_activate = on_quit,
    } },
};

const mp_components = [_]Component{
    .{ .label = .{
        .text = "Game menu",
        .pos_x = 0,
        .pos_y = -72,
        .reference = .middle_center,
        .origin = .middle_center,
    } },
    .{ .button = .{
        .label = "Back to game",
        .width = 200,
        .height = 20,
        .pos_x = 0,
        .pos_y = -36,
        .reference = .middle_center,
        .origin = .middle_center,
        .on_activate = on_resume,
    } },
    .{ .button = .{
        .label = "Options...",
        .width = 200,
        .height = 20,
        .pos_x = 0,
        .pos_y = -12,
        .reference = .middle_center,
        .origin = .middle_center,
        .on_activate = on_noop,
    } },
    .{ .button = .{
        .label = "Save level...",
        .width = 200,
        .height = 20,
        .pos_x = 0,
        .pos_y = 12,
        .reference = .middle_center,
        .origin = .middle_center,
        .enabled = false,
        .on_activate = on_noop,
    } },
    .{ .button = .{
        .label = "Disconnect",
        .width = 200,
        .height = 20,
        .pos_x = 0,
        .pos_y = 36,
        .reference = .middle_center,
        .origin = .middle_center,
        .on_activate = on_quit,
    } },
};

pub var pending_resume: bool = false;
pub var pending_quit: bool = false;
pub var pending_save: bool = false;

fn on_resume(_: *anyopaque) void {
    pending_resume = true;
}

fn on_quit(_: *anyopaque) void {
    pending_quit = true;
}

fn on_save(_: *anyopaque) void {
    pending_save = true;
}

fn on_noop(_: *anyopaque) void {}

fn draw_dim_overlay(_: *anyopaque, sprites: *SpriteBatcher, _: *FontBatcher, _: *const Rendering.Texture) void {
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

pub fn build(ctx: *Context, is_singleplayer: bool) Screen {
    const slice: []const Component = if (is_singleplayer) sp_components[0..] else mp_components[0..];
    return .{
        .components = slice,
        .ctx = ctx,
        .nav = .stack,
        .draw_underlay = draw_dim_overlay,
        .layer_base = LAYER_BASE,
    };
}
