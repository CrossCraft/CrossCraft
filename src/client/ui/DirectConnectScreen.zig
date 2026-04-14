/// Declarative component array for the Direct Connect screen.
///
/// Presents IP address and username text fields with Join/Back buttons.
/// Uses the same dirt+logo underlay as the main menu.
const std = @import("std");
const ae = @import("aether");
const Rendering = ae.Rendering;

const component = @import("component.zig");
const Component = component.Component;
const Screen = @import("Screen.zig");
const Session = @import("../state/Session.zig");
const Scaling = @import("Scaling.zig");
const SpriteBatcher = @import("SpriteBatcher.zig");
const FontBatcher = @import("FontBatcher.zig");

pub const Context = struct {
    dirt: *const Rendering.Texture,
};

// Sized for hostnames (e.g. "play.example.com:25565"), not just dotted-quad
// literals. Resolution is performed at connect time via DNS.
const IP_MAX: u8 = 32;
const NAME_MAX: u8 = 16;

var ip_buf: [IP_MAX]u8 = undefined;
var ip_len: u8 = 0;
var name_buf: [NAME_MAX]u8 = undefined;
var name_len: u8 = 0;

/// Set after the "Back to Menu" button is clicked; MenuState reads and clears.
pub var pending_back: bool = false;

const components = [_]Component{
    .{ .label = .{
        .text = "Direct Connect",
        .pos_x = 0,
        .pos_y = 40,
        .color = .white_fg,
        .shadow_color = .menu_gray,
        .reference = .top_center,
        .origin = .top_center,
    } },
    .{ .label = .{
        .text = "Server Address",
        .pos_x = 0,
        .pos_y = 64,
        .color = .silver_fg,
        .shadow_color = .menu_gray,
        .reference = .top_center,
        .origin = .top_center,
    } },
    .{ .text_input = .{
        .placeholder = "ip:port",
        .buf = &ip_buf,
        .len = &ip_len,
        .max_len = IP_MAX,
        .width = 200,
        .height = 20,
        .pos_x = 0,
        .pos_y = 76,
    } },
    .{ .label = .{
        .text = "Username",
        .pos_x = 0,
        .pos_y = 102,
        .color = .silver_fg,
        .shadow_color = .menu_gray,
        .reference = .top_center,
        .origin = .top_center,
    } },
    .{ .text_input = .{
        .placeholder = "Player",
        .buf = &name_buf,
        .len = &name_len,
        .max_len = NAME_MAX,
        .width = 200,
        .height = 20,
        .pos_x = 0,
        .pos_y = 114,
    } },
    .{ .button = .{
        .label = "Join Server",
        .width = 200,
        .height = 20,
        .pos_x = 0,
        .pos_y = 146,
        .on_activate = on_join,
    } },
    .{ .button = .{
        .label = "Back to Menu",
        .width = 200,
        .height = 20,
        .pos_x = 0,
        .pos_y = 170,
        .on_activate = on_back,
    } },
};

/// Set after the "Join Server" button is clicked; MenuState reads and clears.
pub var pending_join: bool = false;

fn on_join(_: *anyopaque) void {
    // Copy captured text into Session so LoadState/GameState can read it
    // without having to reach back into this module's private buffers.
    Session.set_server(ip_buf[0..ip_len]);
    if (name_len > 0) {
        Session.set_username(name_buf[0..name_len]);
    } else {
        Session.set_username("Player");
    }
    pending_join = true;
}

fn on_back(_: *anyopaque) void {
    pending_back = true;
}

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

pub fn build(ctx: *Context) Screen {
    return .{
        .components = components[0..],
        .ctx = ctx,
        .nav = .stack,
        .draw_underlay = draw_underlay,
    };
}
