//! Best-effort import of the archival world shipped with desktop releases.

const std = @import("std");

const Io = std.Io;

pub const relative_path = "saves/origins.cw";

pub const ImportResult = enum {
    missing_source,
    already_present,
    imported,
};

/// Optional import; failed copies are removed so a later launch can retry.
pub fn import_if_missing(io: Io, resources: Io.Dir, data: Io.Dir) !ImportResult {
    if (file_exists(io, data, relative_path)) return .already_present;
    if (!file_exists(io, resources, relative_path)) return .missing_source;

    var saves_dir = try data.createDirPathOpen(io, "saves", .{});
    defer saves_dir.close(io);

    // Another process may have imported the save while we opened the directory.
    if (file_exists(io, saves_dir, "origins.cw")) return .already_present;

    const source = try resources.openFile(io, relative_path, .{});
    defer source.close(io);

    const destination = try saves_dir.createFile(io, "origins.cw", .{ .exclusive = true });
    errdefer saves_dir.deleteFile(io, "origins.cw") catch {};
    defer destination.close(io);

    var buffer: [8192]u8 = undefined;
    var offset: u64 = 0;
    while (true) {
        const n = try source.readPositionalAll(io, &buffer, offset);
        if (n == 0) break;
        try destination.writeStreamingAll(io, buffer[0..n]);
        offset += n;
    }

    return .imported;
}

fn file_exists(io: Io, dir: Io.Dir, path: []const u8) bool {
    const file = dir.openFile(io, path, .{}) catch return false;
    file.close(io);
    return true;
}

test "imports bundled save when destination is absent" {
    const io = std.testing.io;
    var resources_tmp = std.testing.tmpDir(.{});
    defer resources_tmp.cleanup();

    var data_tmp = std.testing.tmpDir(.{});
    defer data_tmp.cleanup();

    try resources_tmp.dir.createDir(io, "saves", .default_dir);
    const source = try resources_tmp.dir.createFile(io, relative_path, .{});
    try source.writeStreamingAll(io, "bundled world");
    source.close(io);

    try std.testing.expectEqual(
        ImportResult.imported,
        try import_if_missing(io, resources_tmp.dir, data_tmp.dir),
    );

    const destination = try data_tmp.dir.openFile(io, relative_path, .{});
    defer destination.close(io);

    var contents: [32]u8 = undefined;
    const len = try destination.readPositionalAll(io, &contents, 0);
    try std.testing.expectEqualStrings("bundled world", contents[0..len]);
}

test "does not overwrite an existing user save" {
    const io = std.testing.io;
    var resources_tmp = std.testing.tmpDir(.{});
    defer resources_tmp.cleanup();

    var data_tmp = std.testing.tmpDir(.{});
    defer data_tmp.cleanup();

    try resources_tmp.dir.createDir(io, "saves", .default_dir);
    const source = try resources_tmp.dir.createFile(io, relative_path, .{});
    try source.writeStreamingAll(io, "bundled world");
    source.close(io);

    try data_tmp.dir.createDir(io, "saves", .default_dir);
    const existing = try data_tmp.dir.createFile(io, relative_path, .{});
    try existing.writeStreamingAll(io, "user world");
    existing.close(io);

    try std.testing.expectEqual(
        ImportResult.already_present,
        try import_if_missing(io, resources_tmp.dir, data_tmp.dir),
    );

    const destination = try data_tmp.dir.openFile(io, relative_path, .{});
    defer destination.close(io);

    var contents: [32]u8 = undefined;
    const len = try destination.readPositionalAll(io, &contents, 0);
    try std.testing.expectEqualStrings("user world", contents[0..len]);
}

test "missing bundled save is not an import failure" {
    const io = std.testing.io;
    var resources_tmp = std.testing.tmpDir(.{});
    defer resources_tmp.cleanup();

    var data_tmp = std.testing.tmpDir(.{});
    defer data_tmp.cleanup();

    try std.testing.expectEqual(
        ImportResult.missing_source,
        try import_if_missing(io, resources_tmp.dir, data_tmp.dir),
    );
}

test "CWD resources do not copy over the existing file" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDir(io, "saves", .default_dir);
    const source = try tmp.dir.createFile(io, relative_path, .{});
    try source.writeStreamingAll(io, "bundled world");
    source.close(io);

    try std.testing.expectEqual(
        ImportResult.already_present,
        try import_if_missing(io, tmp.dir, tmp.dir),
    );
}
