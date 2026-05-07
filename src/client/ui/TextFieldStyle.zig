//! Visual style for editable text fields. Mirrors `ButtonStyle`.

const texture_region = @import("texture_region.zig");
const Color = @import("../graphics/Color.zig").Color;

pub const TextureRegion = texture_region.TextureRegion;
pub const TextureSizing = texture_region.TextureSizing;

pub const TextFieldStyle = struct {
    bg_region: TextureRegion,
    bg_color: Color,
    sizing: TextureSizing,

    text_color: Color = Color.white_fg,
    text_shadow: Color = Color.menu_gray,
    placeholder_color: Color = Color.silver_fg,
    cursor_color: Color = Color.white_fg,

    text_padding_x: i16 = 4,
};

pub const classic: TextFieldStyle = .{
    .bg_region = .{ .x = 0, .y = 66, .w = 200, .h = 20 },
    .bg_color = Color.rgba(25, 25, 25, 255),
    .sizing = .{ .center_elide = .{} },
};
