const std = @import("std");

pub const NAME_MAX: u8 = 64;
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
    var saw_allowed = false;
    for (trimmed) |ch| {
        if (len >= limit) break;
        if (allowed(ch)) {
            out[len] = ch;
            saw_allowed = true;
        } else {
            out[len] = '_';
        }
        len += 1;
    }

    if (len == 0 or !saw_allowed) return error.EmptyName;
    return out[0..len];
}

fn allowed(ch: u8) bool {
    return (ch >= 'a' and ch <= 'z') or
        (ch >= 'A' and ch <= 'Z') or
        (ch >= '0' and ch <= '9') or
        ch == '_' or ch == '-' or ch == ' ';
}

test "build_path maps display name to saves cw file" {
    var path_buf: [PATH_MAX]u8 = undefined;
    var name_buf: [NAME_MAX]u8 = undefined;
    const got = try build_path("My World", &path_buf, &name_buf);
    try std.testing.expectEqualStrings("My World", got.name);
    try std.testing.expectEqualStrings("saves/My World.cw", got.path);
}

test "build_path rejects empty or only invalid names" {
    var path_buf: [PATH_MAX]u8 = undefined;
    var name_buf: [NAME_MAX]u8 = undefined;
    try std.testing.expectError(error.EmptyName, build_path("   ", &path_buf, &name_buf));
    try std.testing.expectError(error.EmptyName, build_path("////", &path_buf, &name_buf));
}

test "build_path prevents path traversal" {
    var path_buf: [PATH_MAX]u8 = undefined;
    var name_buf: [NAME_MAX]u8 = undefined;
    const got = try build_path("../server/world", &path_buf, &name_buf);
    try std.testing.expectEqualStrings("saves/___server_world.cw", got.path);
    try std.testing.expect(std.mem.startsWith(u8, got.path, "saves/"));
    try std.testing.expect(std.mem.indexOfScalar(u8, got.path["saves/".len..], '/') == null);
}

test "build_path clamps long names" {
    var input: [NAME_MAX + 32]u8 = @splat('a');
    var path_buf: [PATH_MAX]u8 = undefined;
    var name_buf: [NAME_MAX]u8 = undefined;
    const got = try build_path(&input, &path_buf, &name_buf);
    try std.testing.expectEqual(@as(usize, NAME_MAX), got.name.len);
    try std.testing.expectEqual(@as(usize, PATH_MAX), got.path.len);
}
