/// Declarative component array for the main menu, plus activation handlers.
///
/// The component array is module-static so the Screen can hold a stable slice
/// into it. Activation callbacks own all side effects — currently only
/// `on_singleplayer` is wired, the rest are stubs that no-op.
const std = @import("std");
const ae = @import("aether");
const Rendering = ae.Rendering;

const component = @import("component.zig");
const Component = component.Component;
const Screen = @import("Screen.zig");
const Scaling = @import("Scaling.zig");
const SpriteBatcher = @import("SpriteBatcher.zig");
const FontBatcher = @import("FontBatcher.zig");

const log = std.log.scoped(.menu);

pub const Context = struct {
    dirt: *const Rendering.Texture,
    logo: *const Rendering.Texture,
};

const components = [_]Component{
    .{ .label = .{
        .text = "CrossCraft Classic v0.1.0",
        .pos_x = 2,
        .pos_y = 2,
        .color = .dark_gray,
        .shadow_color = .menu_version,
        .reference = .top_left,
        .origin = .top_left,
    } },
    .{ .label = .{
        .text = "Copyleft CrossCraft Team. Distribute!",
        .pos_x = -2,
        .pos_y = -2,
        .color = .white,
        .shadow_color = .menu_copyright,
        .reference = .bottom_right,
        .origin = .bottom_right,
    } },
    .{ .button = .{
        .label = "Singleplayer",
        .width = 200,
        .height = 20,
        .pos_x = 0,
        .pos_y = 120,
        .on_activate = on_singleplayer,
    } },
    .{ .button = .{
        .label = "Multiplayer",
        .width = 200,
        .height = 20,
        .pos_x = 0,
        .pos_y = 144,
        .on_activate = on_multiplayer,
    } },
    .{ .button = .{
        .label = "Mods and Texture Packs",
        .width = 200,
        .height = 20,
        .pos_x = 0,
        .pos_y = 168,
        .enabled = false,
        .on_activate = on_noop,
    } },
    .{ .button = .{
        .label = "Options...",
        .width = 200,
        .height = 20,
        .pos_x = 0,
        .pos_y = 202,
        .enabled = false,
        .on_activate = on_noop,
    } },
};

/// Set after the "Multiplayer" button is clicked; MenuState reads and clears.
pub var pending_direct_connect: bool = false;
/// Set after the "Singleplayer" button is clicked; MenuState reads and clears.
pub var pending_singleplayer: bool = false;

fn on_multiplayer(_: *anyopaque) void {
    pending_direct_connect = true;
}

fn on_singleplayer(_: *anyopaque) void {
    pending_singleplayer = true;
}

fn on_noop(_: *anyopaque) void {}

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

    sprites.add_sprite(&.{
        .texture = menu.logo,
        .pos_offset = .{ .x = 0, .y = 24 },
        .pos_extent = .{ .x = 512, .y = 64 },
        .tex_offset = .{ .x = 0, .y = 0 },
        .tex_extent = .{ .x = @intCast(menu.logo.width), .y = @intCast(menu.logo.height) },
        .color = .white,
        .layer = 1,
        .reference = .top_center,
        .origin = .top_center,
    });
}

pub fn build(ctx: *Context) Screen {
    return .{
        .components = components[0..],
        .ctx = ctx,
        .nav = .stack,
        .draw_underlay = draw_underlay,
    };
}
