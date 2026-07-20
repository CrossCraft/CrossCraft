//! Visual style for editable text fields. Mirrors `ButtonStyle`.

const texture_region = @import("aether").UI.texture_region;
const Colors = @import("../graphics/Color.zig");
const Color = Colors.Color;

pub const TextureRegion = texture_region.TextureRegion;
pub const TextureSizing = texture_region.TextureSizing;

pub const TextFieldStyle = struct {
    bg_region: TextureRegion,
    bg_color: Color,
    sizing: TextureSizing,

    text_color: Color = Colors.white_fg,
    text_shadow: Color = Colors.menu_gray,
    placeholder_color: Color = Colors.silver_fg,
    cursor_color: Color = Colors.white_fg,
    focus_outline_color: Color = Colors.white_fg,
    active_outline_color: Color = Colors.select_front,
    focus_outline_thickness: i16 = 1,
    active_outline_thickness: i16 = 2,

    text_padding_x: i16 = 4,
};

pub const classic: TextFieldStyle = .{
    .bg_region = .{ .x = 0, .y = 66, .w = 200, .h = 20 },
    .bg_color = Color.rgba(25, 25, 25, 255),
    .sizing = .{ .center_elide = .{} },
};
