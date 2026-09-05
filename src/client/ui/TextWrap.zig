//! Classic chat color continuation over Aether's generic bounded wrapper.
const ae = @import("aether");
const TextFormat = @import("TextFormat.zig");
pub fn wrap(comptime max_lines: usize, comptime max_line_bytes: usize, font: anytype, text: []const u8, width: i16, output: *[max_lines][max_line_bytes]u8, lengths: *[max_lines]u8) u8 {
    if (width <= 0) return 0;
    var storage: [max_lines * max_line_bytes]u8 = undefined;
    var lines: [max_lines][]const u8 = undefined;
    const result = ae.Ui.TextWrap.wrap(font, text, .{ .max_width = width, .control_length = TextFormat.control_length }, &storage, &lines) catch return 0;
    var count: usize = 0;
    var active_color: ?u8 = null;
    for (lines[0..result.line_count]) |line| {
        const prefix: usize = if (count > 0 and active_color != null) 2 else 0;
        if (prefix + line.len > max_line_bytes) break;
        if (prefix != 0) {
            output[count][0] = '&';
            output[count][1] = active_color.?;
        }
        @memcpy(output[count][prefix..][0..line.len], line);
        lengths[count] = @intCast(prefix + line.len);
        count += 1;
        var i: usize = 0;
        while (i < line.len) {
            const control = TextFormat.control_length(line[i..]);
            if (control != 0) {
                active_color = line[i + 1];
                i += control;
            } else i += 1;
        }
    }
    return @intCast(count);
}

test "Aether chat wrapping preserves colors in fixed line buffers" {
    const std = @import("std");
    var fonts: ae.Ui.FontBatcher = undefined;
    fonts.glyph_widths = @splat(1);
    fonts.style_parser = TextFormat.parse;
    var output: [4][32]u8 = undefined;
    var lengths: [4]u8 = undefined;
    const count = wrap(4, 32, &fonts, "&cabc def", 5, &output, &lengths);
    try std.testing.expectEqual(2, count);
    try std.testing.expectEqualStrings("&cabc", output[0][0..lengths[0]]);
    try std.testing.expectEqualStrings("&cdef", output[1][0..lengths[1]]);
}

test "Classic chat wrapping carries trailing controls through empty lines" {
    const std = @import("std");
    var fonts: ae.Ui.FontBatcher = undefined;
    fonts.glyph_widths = @splat(1);
    fonts.style_parser = TextFormat.parse;
    var output: [8][32]u8 = undefined;
    var lengths: [8]u8 = undefined;
    const count = wrap(8, 32, &fonts, "&cabc def&b\n\n&fX\n", 5, &output, &lengths);
    try std.testing.expectEqual(5, count);
    for ([_][]const u8{ "&cabc", "&cdef&b", "&b", "&b&fX", "&f" }, 0..) |expected, i| {
        try std.testing.expectEqualStrings(expected, output[i][0..lengths[i]]);
    }
    const controls_only = wrap(8, 32, &fonts, "&c&b", 1, &output, &lengths);
    try std.testing.expectEqual(1, controls_only);
    try std.testing.expectEqualStrings("&c&b", output[0][0..lengths[0]]);
    var small: [4][3]u8 = undefined;
    var small_lengths: [4]u8 = undefined;
    try std.testing.expectEqual(0, wrap(4, 3, &fonts, "&cAB", 3, &small, &small_lengths));
}
