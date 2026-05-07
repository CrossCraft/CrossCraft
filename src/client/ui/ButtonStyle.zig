//! Visual style for buttons. Lifts atlas regions, label colors, and sizing
//! out of widget code so each button carries a `*const ButtonStyle`.

const texture_region = @import("texture_region.zig");
const Color = @import("../graphics/Color.zig").Color;

pub const TextureRegion = texture_region.TextureRegion;
pub const TextureSizing = texture_region.TextureSizing;

pub const ButtonStyle = struct {
    normal: TextureRegion,
    hover: TextureRegion,
    disabled: TextureRegion,
    sizing: TextureSizing,

    label_color_normal: Color = Color.white_fg,
    label_color_hover: Color = Color.select_front,
    label_color_disabled: Color = Color.silver_fg,
    shadow_color_normal: Color = Color.menu_gray,
    shadow_color_hover: Color = Color.select_back,

    /// Inset on each side reserved for the label. Button drawing truncates
    /// to fit `width - 2 * text_padding_x`.
    text_padding_x: i16 = 4,
};

/// Minecraft Classic button atlas: three Y bands sharing a 200x20 source rect.
pub const classic: ButtonStyle = .{
    .normal = .{ .x = 0, .y = 66, .w = 200, .h = 20 },
    .hover = .{ .x = 0, .y = 86, .w = 200, .h = 20 },
    .disabled = .{ .x = 0, .y = 46, .w = 200, .h = 20 },
    .sizing = .{ .center_elide = .{} },
};
