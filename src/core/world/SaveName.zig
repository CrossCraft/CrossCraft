const std = @import("std");

const Policy = enum { create, dump };

fn SaveNameType(comptime policy: Policy) type {
    return struct {
        pub const NameMax: u8 = switch (policy) {
            .create => 20,
            .dump => 64,
        };
        pub const PathMax: usize = "saves/".len + NameMax + ".cw".len;

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

            const limit = @min(@as(usize, NameMax), out.len);
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

pub const Create = SaveNameType(.create);
pub const Dump = SaveNameType(.dump);
