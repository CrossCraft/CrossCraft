//! Classic protocol color codes and the game's font configuration.
const std = @import("std");
const ae = @import("aether");

const FontBatcher = ae.Ui.FontBatcher;
const Color = ae.Ui.Color;

pub fn control_length(text: []const u8) usize {
    if (text.len < 2 or text[0] != '&') return 0;
    const code = text[1];
    return if ((code >= '0' and code <= '9') or (code >= 'a' and code <= 'f')) 2 else 0;
}

pub fn parse(text: []const u8) ?FontBatcher.StyleControl {
    if (control_length(text) == 0) return null;
    const colors = switch (text[1]) {
        '0' => .{ Color.rgba(0, 0, 0, 255), Color.rgba(0, 0, 0, 255) },
        '1' => .{ Color.rgba(0, 0, 170, 255), Color.rgba(0, 0, 42, 255) },
        '2' => .{ Color.rgba(0, 170, 0, 255), Color.rgba(0, 42, 0, 255) },
        '3' => .{ Color.rgba(0, 170, 170, 255), Color.rgba(0, 42, 42, 255) },
        '4' => .{ Color.rgba(170, 0, 0, 255), Color.rgba(42, 0, 0, 255) },
        '5' => .{ Color.rgba(170, 0, 170, 255), Color.rgba(42, 0, 42, 255) },
        '6' => .{ Color.rgba(170, 170, 0, 255), Color.rgba(42, 42, 0, 255) },
        '7' => .{ Color.rgba(170, 170, 170, 255), Color.rgba(42, 42, 42, 255) },
        '8' => .{ Color.rgba(85, 85, 85, 255), Color.rgba(21, 21, 21, 255) },
        '9' => .{ Color.rgba(85, 85, 255, 255), Color.rgba(21, 21, 63, 255) },
        'a' => .{ Color.rgba(85, 255, 85, 255), Color.rgba(21, 63, 21, 255) },
        'b' => .{ Color.rgba(85, 255, 255, 255), Color.rgba(21, 63, 63, 255) },
        'c' => .{ Color.rgba(255, 85, 85, 255), Color.rgba(63, 21, 21, 255) },
        'd' => .{ Color.rgba(255, 85, 255, 255), Color.rgba(63, 21, 63, 255) },
        'e' => .{ Color.rgba(255, 255, 85, 255), Color.rgba(63, 63, 21, 255) },
        'f' => .{ Color.rgba(255, 255, 255, 255), Color.rgba(63, 63, 63, 255) },
        else => unreachable,
    };
    return .{ .length = 2, .color = colors[0], .shadow_color = colors[1] };
}

pub fn init_font(allocator: std.mem.Allocator, texture: *const ae.Rendering.Texture) !FontBatcher {
    var font = try FontBatcher.init(allocator, texture);
    font.style_parser = parse;
    return font;
}
