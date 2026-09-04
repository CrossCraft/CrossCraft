const std = @import("std");
const assert = std.debug.assert;

const COLOR_PREFIX: u8 = '&';

pub fn wrap(
    comptime MAX_LINES: usize,
    comptime MAX_LINE_BYTES: usize,
    fonts: anytype,
    text: []const u8,
    max_w: i16,
    out: *[MAX_LINES][MAX_LINE_BYTES]u8,
    lens: *[MAX_LINES]u8,
) u8 {
    assert(MAX_LINES > 0);
    assert(MAX_LINES <= std.math.maxInt(u8));
    assert(MAX_LINE_BYTES > 0);
    assert(MAX_LINE_BYTES <= std.math.maxInt(u8));

    if (text.len == 0 or max_w <= 0) return 0;

    var count: u8 = 0;
    var start = skip_spaces(text, 0);
    var active_color: ?u8 = null;

    while (start < text.len and count < MAX_LINES) {
        const fit = fonts.fit_width(text[start..], max_w, 0, 1);
        var fit_end = start + fit;
        if (fit_end <= start or !has_visible(text[start..fit_end])) {
            fit_end = force_one_visible(text, start);
        }
        if (fit_end > text.len) fit_end = text.len;

        var end = fit_end;
        var next = fit_end;
        if (fit_end < text.len) {
            if (last_space(text, start, fit_end)) |space| {
                if (space > start) {
                    end = space;
                    next = space + 1;
                }
            }
        }

        end = trim_trailing_spaces(text, start, end);
        if (end == start) {
            start = skip_spaces(text, next);
            continue;
        }

        lens[count] = write_line(MAX_LINE_BYTES, &out[count], if (count > 0) active_color else null, text[start..end]);
        active_color = scan_color(active_color, text[start..end]);
        count += 1;
        start = skip_spaces(text, next);
    }

    return count;
}

fn write_line(
    comptime MAX_LINE_BYTES: usize,
    out: *[MAX_LINE_BYTES]u8,
    prefix_color: ?u8,
    text: []const u8,
) u8 {
    var n: usize = 0;
    if (prefix_color) |c| {
        assert(n + 2 <= MAX_LINE_BYTES);
        out[n] = COLOR_PREFIX;
        out[n + 1] = c;
        n += 2;
    }
    assert(n + text.len <= MAX_LINE_BYTES);
    @memcpy(out[n .. n + text.len], text);
    n += text.len;
    return @intCast(n);
}

fn skip_spaces(text: []const u8, at: usize) usize {
    var i = at;
    while (i < text.len and text[i] == ' ') : (i += 1) {}
    return i;
}

fn trim_trailing_spaces(text: []const u8, start: usize, end: usize) usize {
    var n = end;
    while (n > start and text[n - 1] == ' ') : (n -= 1) {}
    return n;
}

fn last_space(text: []const u8, start: usize, end: usize) ?usize {
    var i = end;
    while (i > start) {
        i -= 1;
        if (text[i] == ' ') return i;
    }
    return null;
}

fn has_visible(text: []const u8) bool {
    var i: usize = 0;
    while (i < text.len) {
        if (is_color_code(text, i)) {
            i += 2;
            continue;
        }
        return true;
    }
    return false;
}

fn force_one_visible(text: []const u8, start: usize) usize {
    var i = start;
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
    return at + 1 < text.len and text[at] == COLOR_PREFIX and is_color_hex(text[at + 1]);
}

fn is_color_hex(c: u8) bool {
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

test "single-line fit" {
    try expect_wrap("hello", 5, &.{"hello"});
}

test "wraps at spaces" {
    try expect_wrap("hello world", 5, &.{ "hello", "world" });
}

test "hard wraps long words" {
    try expect_wrap("abcdefgh", 3, &.{ "abc", "def", "gh" });
}

test "skips leading spaces on continuation lines" {
    try expect_wrap("hello   world", 5, &.{ "hello", "world" });
}

test "does not split color codes" {
    try expect_wrap("a&cb", 1, &.{ "a&c", "&cb" });
}

test "preserves active color on continuation lines" {
    try expect_wrap("&chello world", 5, &.{ "&chello", "&cworld" });
}
