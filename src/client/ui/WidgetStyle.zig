const texture_region = @import("aether").Ui.texture_region;
const Colors = @import("../graphics/Color.zig");
const Color = Colors.Color;

const TextureRegion = texture_region.TextureRegion;
const TextureSizing = texture_region.TextureSizing;

pub const Button = struct {
    normal: TextureRegion,
    hover: TextureRegion,
    disabled: TextureRegion,
    sizing: TextureSizing,
    label_color_normal: Color = Colors.white_fg,
    label_color_hover: Color = Colors.select_front,
    label_color_disabled: Color = Colors.silver_fg,
    shadow_color_normal: Color = Colors.menu_gray,
    shadow_color_hover: Color = Colors.select_back,
    text_padding_x: i16 = 4,

    pub const classic: Button = .{
        .normal = .{ .x = 0, .y = 66, .w = 200, .h = 20 },
        .hover = .{ .x = 0, .y = 86, .w = 200, .h = 20 },
        .disabled = .{ .x = 0, .y = 46, .w = 200, .h = 20 },
        .sizing = .{ .center_elide = .{} },
    };
};

pub const Slider = struct {
    track_normal: TextureRegion,
    knob_normal: TextureRegion,
    knob_hover: TextureRegion,
    knob_active: TextureRegion,
    sizing: TextureSizing,
    knob_w: i16 = 8,
    label_color: Color = Colors.white_fg,
    label_color_hover: Color = Colors.select_front,
    shadow_color_normal: Color = Colors.menu_gray,
    shadow_color_hover: Color = Colors.select_back,
    focus_outline_color: Color = Colors.white_fg,
    active_outline_color: Color = Colors.select_front,
    focus_outline_thickness: i16 = 1,
    active_outline_thickness: i16 = 2,
    text_padding_x: i16 = 4,

    pub const classic: Slider = .{
        .track_normal = .{ .x = 0, .y = 46, .w = 200, .h = 20 },
        .knob_normal = .{ .x = 0, .y = 66, .w = 200, .h = 20 },
        .knob_hover = .{ .x = 0, .y = 86, .w = 200, .h = 20 },
        .knob_active = .{ .x = 0, .y = 86, .w = 200, .h = 20 },
        .sizing = .{ .center_elide = .{} },
    };
};

pub const TextField = struct {
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

    pub const classic: TextField = .{
        .bg_region = .{ .x = 0, .y = 66, .w = 200, .h = 20 },
        .bg_color = Color.rgba(25, 25, 25, 255),
        .sizing = .{ .center_elide = .{} },
    };
};
