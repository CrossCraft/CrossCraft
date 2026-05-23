const std = @import("std");

pub const NAME_MAX: u8 = 16;
pub const PATH_MAX: usize = "saves/".len + NAME_MAX + ".cw".len;

pub const Result = struct {
    path: []const u8,
    name: []const u8,
};

pub fn build_path(input: []const u8, path_out: []u8, name_out: []u8) !Result {
    const name = try sanitize_name(input, name_out);
    if (path_out.len < "saves/".len + name.len + ".cw".len) return error.NoSpaceLeft;

    var pos: usize = 0;
    @memcpy(path_out[pos..][0.."saves/".len], "saves/");
    pos += "saves/".len;
    @memcpy(path_out[pos..][0..name.len], name);
    pos += name.len;
    @memcpy(path_out[pos..][0..".cw".len], ".cw");
    pos += ".cw".len;

    return .{ .path = path_out[0..pos], .name = name };
}

pub fn sanitize_name(input: []const u8, out: []u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, input, " ");
    if (trimmed.len == 0) return error.EmptyName;

    const limit = @min(@as(usize, NAME_MAX), out.len);
    var len: usize = 0;
    var saw_alnum = false;
    for (trimmed) |ch| {
        if (len >= limit) break;
        if (std.ascii.isAlphanumeric(ch)) {
            out[len] = ch;
            saw_alnum = true;
        } else if (ch == ' ' or ch == '_') {
            out[len] = '_';
        } else {
            return error.InvalidCharacter;
        }
        len += 1;
    }

    if (len == 0 or !saw_alnum) return error.EmptyName;
    return out[0..len];
}

test "build_path maps display name to saves cw file" {
    var path_buf: [PATH_MAX]u8 = undefined;
    var name_buf: [NAME_MAX]u8 = undefined;
    const got = try build_path("My World", &path_buf, &name_buf);
    try std.testing.expectEqualStrings("My_World", got.name);
    try std.testing.expectEqualStrings("saves/My_World.cw", got.path);
}

test "build_path trims input" {
    var path_buf: [PATH_MAX]u8 = undefined;
    var name_buf: [NAME_MAX]u8 = undefined;
    const got = try build_path("  New World  ", &path_buf, &name_buf);
    try std.testing.expectEqualStrings("New_World", got.name);
    try std.testing.expectEqualStrings("saves/New_World.cw", got.path);
}

test "build_path rejects blank and punctuation names" {
    var path_buf: [PATH_MAX]u8 = undefined;
    var name_buf: [NAME_MAX]u8 = undefined;
    try std.testing.expectError(error.EmptyName, build_path("   ", &path_buf, &name_buf));
    try std.testing.expectError(error.InvalidCharacter, build_path("////", &path_buf, &name_buf));
    try std.testing.expectError(error.EmptyName, build_path("____", &path_buf, &name_buf));
}

test "build_path rejects invalid file characters" {
    var path_buf: [PATH_MAX]u8 = undefined;
    var name_buf: [NAME_MAX]u8 = undefined;
    try std.testing.expectError(error.InvalidCharacter, build_path("../world", &path_buf, &name_buf));
    try std.testing.expectError(error.InvalidCharacter, build_path("world:name", &path_buf, &name_buf));
}

test "build_path clamps long names" {
    var input: [NAME_MAX + 32]u8 = @splat('a');
    var path_buf: [PATH_MAX]u8 = undefined;
    var name_buf: [NAME_MAX]u8 = undefined;
    const got = try build_path(&input, &path_buf, &name_buf);
    try std.testing.expectEqual(@as(usize, NAME_MAX), got.name.len);
    try std.testing.expectEqual(@as(usize, PATH_MAX), got.path.len);
}
