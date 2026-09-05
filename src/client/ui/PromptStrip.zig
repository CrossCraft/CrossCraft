//! CrossCraft prompt wording/artwork over Aether's generic prompt layout.
const ae = @import("aether");
const caps = @import("capabilities").ClientType(ae);
const Buttons = @import("Buttons.zig");
const Options = @import("../Options.zig");
const Colors = @import("../graphics/Color.zig");
const UiDrawList = @import("UiDrawList.zig");
const Screen = @import("Screen.zig");
const Input = ae.Core.input;
pub const Anchor = ae.Ui.Anchor;
pub const Prompt = struct { chord: [2]?Buttons.Button, label: []const u8, letter_overlay: ?[]const u8 = null };
pub const DefaultPosX: i16 = 20;
pub const DefaultPosY: i16 = caps.ui.prompt_y;
pub fn enabled() bool {
    return Options.current.controller_tooltips != .off;
}
const Provider = struct {
    texture: *const ae.Rendering.Texture,
    style: Buttons.Style,
    overlay: ?[]const u8,
    fn glyph(context: *anyopaque, source: Input.BindingSource, _: Input.InputMode) ?ae.Ui.PromptStrip.Glyph {
        const self: *Provider = @ptrCast(@alignCast(context));
        const button: Buttons.Button = switch (source) {
            .key => |key| switch (key) {
                .Enter => .EnterKey,
                .Escape => .EscapeKey,
                else => .BlankKey,
            },
            .mouse_button => |button| if (button == .Left) .Lmb else .Rmb,
            .gamepad_axis => |axis| switch (axis) {
                .LeftX => .LStick,
                .RightX => .RStick,
                .LeftTrigger => .LTrigger,
                .RightTrigger => .RTrigger,
                else => return null,
            },
            .gamepad_button => |button| switch (button) {
                .A => .A,
                .B => .B,
                .X => .X,
                .Y => .Y,
                .DpadUp => .DpadUp,
                .DpadDown => .DpadDown,
                .DpadLeft => .DpadLeft,
                .DpadRight => .DpadRight,
                .LButton => .LButton,
                .RButton => .RButton,
                .Start => .Start,
                .Back => .Select,
                .Guide => .Home,
                else => return null,
            },
            else => return null,
        };
        const rect = Buttons.lookup(button, self.style);
        return .{ .texture = self.texture, .region = .{ .x = rect.tex_x, .y = rect.tex_y, .w = rect.tex_w, .h = rect.tex_h }, .width = rect.render_w, .height = rect.render_h, .overlay = self.overlay };
    }
};
fn binding_source(button: Buttons.Button) Input.BindingSource {
    return switch (button) {
        .EnterKey => .{ .key = .Enter },
        .EscapeKey => .{ .key = .Escape },
        .BlankKey => .{ .key = .Space },
        .Lmb => .{ .mouse_button = .Left },
        .Rmb => .{ .mouse_button = .Right },
        .LStick => .{ .gamepad_axis = .LeftX },
        .RStick => .{ .gamepad_axis = .RightX },
        .LTrigger => .{ .gamepad_axis = .LeftTrigger },
        .RTrigger => .{ .gamepad_axis = .RightTrigger },
        .A => .{ .gamepad_button = .A },
        .B => .{ .gamepad_button = .B },
        .X => .{ .gamepad_button = .X },
        .Y => .{ .gamepad_button = .Y },
        .DpadUp => .{ .gamepad_button = .DpadUp },
        .DpadDown => .{ .gamepad_button = .DpadDown },
        .DpadLeft => .{ .gamepad_button = .DpadLeft },
        .DpadRight => .{ .gamepad_button = .DpadRight },
        .LButton => .{ .gamepad_button = .LButton },
        .RButton => .{ .gamepad_button = .RButton },
        .Start => .{ .gamepad_button = .Start },
        .Select => .{ .gamepad_button = .Back },
        .Home => .{ .gamepad_button = .Guide },
    };
}
pub fn draw_into(list: *UiDrawList, texture: *const ae.Rendering.Texture, font: *const ae.Ui.FontBatcher, prompts: []const Prompt, anchor: Anchor, pos_x: i16, y_base: i16, _: u8, _: u8) void {
    if (!enabled()) return;
    const screen = Screen.logical_rect();
    const reference = ae.Ui.layout.anchor_point(anchor, screen.width(), screen.height());
    var x = reference.x + pos_x;
    const style = Buttons.resolve_style();
    for (prompts, 0..) |prompt, index| {
        if (index > 0) x += 12;
        var sources: [2]Input.BindingSource = undefined;
        var count: usize = 0;
        var height: i16 = 8;
        for (prompt.chord) |optional| if (optional) |button| {
            sources[count] = binding_source(button);
            count += 1;
            height = Buttons.lookup(button, style).render_h;
        };
        var provider: Provider = .{ .texture = texture, .style = style, .overlay = prompt.letter_overlay };
        x += ae.Ui.PromptStrip.draw(list.native(), font, .{ .context = &provider, .get = Provider.glyph }, &.{.{ .chord = sources[0..count], .label = prompt.label }}, .{ .origin = .{ .x = x, .y = reference.y - y_base - height }, .height = height, .chord_separator = "", .chord_gap = 2, .label_gap = 4, .glyph_offset_y = Buttons.glyph_y_offset(), .text_offset_y = 1 + @as(i16, if (style == .kbm) 1 else 0), .shadow_color = Colors.menu_gray }) catch @panic("Prompt command capacity exhausted");
    }
    list.count = list.native().count;
}
