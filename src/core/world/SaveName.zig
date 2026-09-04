const std = @import("std");

const Policy = enum { create, dump };

fn SaveName(comptime policy: Policy) type {
    return struct {
        pub const NAME_MAX: u8 = switch (policy) {
            .create => 20,
            .dump => 64,
        };
        pub const PATH_MAX: usize = "saves/".len + NAME_MAX + ".cw".len;

        pub const Result = struct {
            path: []const u8,
            name: []const u8,
        };

        pub fn build_path(input: []const u8, path_out: []u8, name_out: []u8) !Result {
            const name = try sanitize_name(input, name_out);
            return .{ .path = try std.fmt.bufPrint(path_out, "saves/{s}.cw", .{name}), .name = name };
        }

        pub fn sanitize_name(input: []const u8, out: []u8) ![]const u8 {
            const trimmed = std.mem.trim(u8, input, " ");
            if (trimmed.len == 0) return error.EmptyName;

            const limit = @min(@as(usize, NAME_MAX), out.len);
            var len: usize = 0;
            var saw_valid = false;
            for (trimmed) |ch| {
                if (len >= limit) break;
                switch (policy) {
                    .create => {
                        if (std.ascii.isAlphanumeric(ch)) {
                            out[len] = ch;
                            saw_valid = true;
                        } else if (ch == ' ' or ch == '_') {
                            out[len] = '_';
                        } else {
                            return error.InvalidCharacter;
                        }
                    },
                    .dump => {
                        const valid = std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '-' or ch == ' ';
                        out[len] = if (valid) ch else '_';
                        saw_valid = saw_valid or valid;
                    },
                }
                len += 1;
            }

            if (len == 0 or !saw_valid) return error.EmptyName;
            return out[0..len];
        }
    };
}

pub const Create = SaveName(.create);
pub const Dump = SaveName(.dump);

test "create save-name policy" {
    var path_buf: [Create.PATH_MAX]u8 = undefined;
    var name_buf: [Create.NAME_MAX]u8 = undefined;

    const result = try Create.build_path("  New World  ", &path_buf, &name_buf);
    try std.testing.expectEqualStrings("New_World", result.name);
    try std.testing.expectEqualStrings("saves/New_World.cw", result.path);

    try std.testing.expectError(error.EmptyName, Create.build_path("   ", &path_buf, &name_buf));
    try std.testing.expectError(error.InvalidCharacter, Create.build_path("////", &path_buf, &name_buf));
    try std.testing.expectError(error.EmptyName, Create.build_path("____", &path_buf, &name_buf));
    try std.testing.expectError(error.InvalidCharacter, Create.build_path("../world", &path_buf, &name_buf));
    try std.testing.expectError(error.InvalidCharacter, Create.build_path("world:name", &path_buf, &name_buf));

    const long_input = [_]u8{'a'} ** (Create.NAME_MAX + 32);
    const truncated = try Create.build_path(&long_input, &path_buf, &name_buf);
    try std.testing.expectEqual(@as(usize, Create.NAME_MAX), truncated.name.len);
    try std.testing.expectEqual(@as(usize, Create.PATH_MAX), truncated.path.len);
}

test "dump save-name policy" {
    var path_buf: [Dump.PATH_MAX]u8 = undefined;
    var name_buf: [Dump.NAME_MAX]u8 = undefined;

    const result = try Dump.build_path("My World", &path_buf, &name_buf);
    try std.testing.expectEqualStrings("My World", result.name);
    try std.testing.expectEqualStrings("saves/My World.cw", result.path);

    try std.testing.expectError(error.EmptyName, Dump.build_path("   ", &path_buf, &name_buf));
    try std.testing.expectError(error.EmptyName, Dump.build_path("////", &path_buf, &name_buf));

    const safe = try Dump.build_path("../server/world", &path_buf, &name_buf);
    try std.testing.expectEqualStrings("saves/___server_world.cw", safe.path);
    try std.testing.expect(std.mem.indexOfScalar(u8, safe.path["saves/".len..], '/') == null);

    const long_input = [_]u8{'a'} ** (Dump.NAME_MAX + 32);
    const truncated = try Dump.build_path(&long_input, &path_buf, &name_buf);
    try std.testing.expectEqual(@as(usize, Dump.NAME_MAX), truncated.name.len);
    try std.testing.expectEqual(@as(usize, Dump.PATH_MAX), truncated.path.len);
}
