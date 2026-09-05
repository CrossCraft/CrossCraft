const std = @import("std");
const assert = std.debug.assert;

const ColorPrefix: u8 = '&';

pub fn wrap(
    comptime MaxLines: usize,
    comptime MaxLineBytes: usize,
    fonts: anytype,
    text: []const u8,
    max_w: i16,
    out: *[MaxLines][MaxLineBytes]u8,
    lens: *[MaxLines]u8,
) u8 {
    assert(MaxLines > 0);
    assert(MaxLines <= std.math.maxInt(u8));
    assert(MaxLineBytes > 0);
    assert(MaxLineBytes <= std.math.maxInt(u8));

    if (text.len == 0 or max_w <= 0) return 0;

    var count: u8 = 0;
    var remaining = std.mem.trimStart(u8, text, " ");
    var active_color: ?u8 = null;

    while (remaining.len > 0 and count < MaxLines) {
        const fit = fonts.fit_width(remaining, max_w, 0, 1);
        const fit_end = @min(remaining.len, @max(fit, first_visible_end(remaining)));
        var end = fit_end;
        var next = fit_end;
        if (fit_end < remaining.len) {
            if (std.mem.lastIndexOfScalar(u8, remaining[0..fit_end], ' ')) |space| {
                if (space > 0) {
                    end = space;
                    next = space + 1;
                }
            }
        }

        const line = std.mem.trimEnd(u8, remaining[0..end], " ");
        if (line.len > 0) {
            var prefix_len: usize = 0;
            if (count > 0) {
                if (active_color) |color| {
                    assert(MaxLineBytes >= 2);
                    out[count][prefix_len] = ColorPrefix;
                    out[count][prefix_len + 1] = color;
                    prefix_len = 2;
                }
            }
            assert(prefix_len + line.len <= MaxLineBytes);
            @memcpy(out[count][prefix_len..][0..line.len], line);
            lens[count] = @intCast(prefix_len + line.len);
            active_color = scan_color(active_color, line);
            count += 1;
        }
        remaining = std.mem.trimStart(u8, remaining[next..], " ");
    }

    return count;
}

fn first_visible_end(text: []const u8) usize {
    var i: usize = 0;
    while (i < text.len) {
        if (is_color_code(text, i)) {
            i += 2;
            continue;
        }
        return i + 1;
    }
    return text.len;
}

fn scan_color(initial: ?u8, text: []const u8) ?u8 {
    var active = initial;
    var i: usize = 0;
    while (i + 1 < text.len) {
        if (is_color_code(text, i)) {
            active = text[i + 1];
            i += 2;
            continue;
        }
        i += 1;
    }
    return active;
}

fn is_color_code(text: []const u8, at: usize) bool {
    if (at + 1 >= text.len or text[at] != ColorPrefix) return false;
    const c = text[at + 1];
    return (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f');
}

const TestFont = struct {
    pub fn fit_width(_: *const TestFont, text: []const u8, max_w: i16, _: i8, _: u8) usize {
        if (max_w <= 0 or text.len == 0) return 0;
        var width: i16 = 0;
        var i: usize = 0;
        var last_fit: usize = 0;
        while (i < text.len) {
            if (is_color_code(text, i)) {
                i += 2;
                last_fit = i;
                continue;
            }
            if (width + 1 > max_w) break;
            width += 1;
            i += 1;
            last_fit = i;
        }
        return last_fit;
    }
};

fn expect_wrap(text: []const u8, max_w: i16, expected: []const []const u8) !void {
    var out: [8][32]u8 = undefined;
    var lens: [8]u8 = undefined;
    const font = TestFont{};
    const count = wrap(8, 32, &font, text, max_w, &out, &lens);
    try std.testing.expectEqual(@as(u8, @intCast(expected.len)), count);
    for (expected, 0..) |line, i| {
        try std.testing.expectEqualStrings(line, out[i][0..lens[i]]);
    }
}

test "text wrapping handles whitespace and long words" {
    try expect_wrap("", 5, &.{});
    try expect_wrap("   ", 5, &.{});
    try expect_wrap("hello", 0, &.{});
    try expect_wrap("hello", 5, &.{"hello"});
    try expect_wrap("hello world", 5, &.{ "hello", "world" });
    try expect_wrap("abcdefgh", 3, &.{ "abc", "def", "gh" });
    try expect_wrap("  hello   world  ", 5, &.{ "hello", "world" });
}

test "text wrapping preserves color codes across lines" {
    try expect_wrap("a&cb", 1, &.{ "a&c", "&cb" });
    try expect_wrap("&chello world", 5, &.{ "&chello", "&cworld" });
    try expect_wrap("&c", 1, &.{"&c"});
    try expect_wrap("&c&aab", 1, &.{ "&c&aa", "&ab" });
    try expect_wrap("a&", 1, &.{ "a", "&" });
}

test "text wrapping stops when the output is full" {
    var out: [2][1]u8 = undefined;
    var lens: [2]u8 = undefined;
    const font: TestFont = .{};
    try std.testing.expectEqual(2, wrap(2, 1, &font, "abc", 1, &out, &lens));
    try std.testing.expectEqualDeep([2][1]u8{ .{'a'}, .{'b'} }, out);
}
