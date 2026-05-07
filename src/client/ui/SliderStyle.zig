//! Visual style for sliders. Mirrors `ButtonStyle` / `TextFieldStyle`.

const texture_region = @import("texture_region.zig");
const Color = @import("../graphics/Color.zig").Color;

pub const TextureRegion = texture_region.TextureRegion;
pub const TextureSizing = texture_region.TextureSizing;

pub const SliderStyle = struct {
    track_normal: TextureRegion,
    track_disabled: TextureRegion,
    knob_normal: TextureRegion,
    knob_hover: TextureRegion,
    knob_active: TextureRegion,
    sizing: TextureSizing,
    /// Knob slides along the track between `rect.x0` and `rect.x1 - knob_w`.
    knob_w: i16 = 8,

    label_color: Color = Color.white_fg,
    label_color_hover: Color = Color.select_front,
    label_color_disabled: Color = Color.silver_fg,
    shadow_color_normal: Color = Color.menu_gray,
    shadow_color_hover: Color = Color.select_back,
    text_padding_x: i16 = 4,
};

/// Disabled row (Y=46) for the recessed track; normal/highlight (Y=66/86) for the knob.
pub const classic: SliderStyle = .{
    .track_normal = .{ .x = 0, .y = 46, .w = 200, .h = 20 },
    .track_disabled = .{ .x = 0, .y = 46, .w = 200, .h = 20 },
    .knob_normal = .{ .x = 0, .y = 66, .w = 200, .h = 20 },
    .knob_hover = .{ .x = 0, .y = 86, .w = 200, .h = 20 },
    .knob_active = .{ .x = 0, .y = 86, .w = 200, .h = 20 },
    .sizing = .{ .center_elide = .{} },
};
