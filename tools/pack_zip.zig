/// Build CrossCraft resource packs as ZIP archives.
///
/// Usage: pack_zip <input_dir> <output_file>
///
/// Use --store-extension=.wav (repeatable), --store-all, and --max-file-bytes=N.
/// Default compression is DEFLATE, falling back to store when it is smaller.
/// Archive paths use forward slashes on every host.
const std = @import("std");
const Io = std.Io;
const Dir = Io.Dir;
const Crc32 = std.hash.crc.Crc32IsoHdlc;
const flate = std.compress.flate;
const caps = @import("capabilities").resource_pack;
const utf8_flag: u16 = 1 << 11;

const local_file_header_sig = [4]u8{ 0x50, 0x4b, 0x03, 0x04 };
const central_dir_header_sig = [4]u8{ 0x50, 0x4b, 0x01, 0x02 };
const end_of_central_dir_sig = [4]u8{ 0x50, 0x4b, 0x05, 0x06 };

const CdRecord = struct {
    crc32: u32,
    compressed_size: u32,
    uncompressed_size: u32,
    compression_method: u16,
    filename: []const u8,
    local_header_offset: u32,
};

const Entry = struct {
    /// Never use a normalized archive name for filesystem I/O.
    source_path: []const u8,
    archive_path: []const u8,
};

pub const Options = struct {
    stored_extensions: []const []const u8 = &.{},
    store_all: bool = false,
    max_file_bytes: usize = 64 * 1024 * 1024,
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 3) return error.InvalidArguments;
    var opts: Options = .{};
    var extensions: std.ArrayList([]const u8) = .empty;
    defer extensions.deinit(allocator);

    for (args[3..]) |arg| {
        if (std.mem.eql(u8, arg, "--store-all")) {
            opts.store_all = true;
        } else if (std.mem.startsWith(u8, arg, "--store-extension=")) {
            const ext = arg[18..];
            if (ext.len == 0) return error.InvalidArguments;
            try extensions.append(allocator, ext);
        } else if (std.mem.startsWith(u8, arg, "--max-file-bytes=")) {
            opts.max_file_bytes = try std.fmt.parseInt(usize, arg[17..], 10);
        } else return error.InvalidArguments;
    }
    opts.stored_extensions = extensions.items;
    var cwd: [Dir.max_path_bytes]u8 = undefined;
    const cwd_len = try std.process.currentPath(io, &cwd);
    const input_path = try std.fs.path.resolve(allocator, &.{ cwd[0..cwd_len], args[1] });
    defer allocator.free(input_path);

    const output_path = try std.fs.path.resolve(allocator, &.{ cwd[0..cwd_len], args[2] });
    defer allocator.free(output_path);

    var input_dir = try Dir.openDirAbsolute(io, input_path, .{ .iterate = true });
    defer input_dir.close(io);

    var output_dir = try Dir.openDirAbsolute(io, std.fs.path.dirname(output_path).?, .{});
    defer output_dir.close(io);

    // Compare physical directories as well as lexical paths so a symlink to
    // the input cannot hide the output from the self-inclusion check.
    var input_real: [Dir.max_path_bytes]u8 = undefined;
    var output_real: [Dir.max_path_bytes]u8 = undefined;
    const input_len = try input_dir.realPath(io, &input_real);
    const output_len = try output_dir.realPath(io, &output_real);
    if (path_within(input_real[0..input_len], output_real[0..output_len])) return error.OutputInsideInput;
    // Preserve an existing archive on errors and replace an output symlink
    // itself, without truncating the file to which it points.
    var output = try output_dir.createFileAtomic(io, std.fs.path.basename(output_path), .{ .replace = true });
    defer output.deinit(io);

    var buffer: [8192]u8 = undefined;
    var writer = output.file.writer(io, &buffer);
    try pack_directory(allocator, io, input_dir, &writer.interface, opts);
    try output.replace(io);
}

/// Stable path ordering, zero timestamps, ZIP32 size checks, and configurable
/// compression. File and directory symlinks are skipped. Input must remain
/// unchanged during packing. Names must be safe, relative UTF-8 paths; literal
/// backslashes on POSIX are rejected instead of interpreted as separators.
pub fn pack_directory(gpa: std.mem.Allocator, io: Io, input_dir: Dir, w: *Io.Writer, opts: Options) !void {
    var entries: std.ArrayList(Entry) = .empty;
    defer {
        for (entries.items) |entry| {
            gpa.free(entry.source_path);
            gpa.free(entry.archive_path);
        }
        entries.deinit(gpa);
    }

    var walker = try input_dir.walk(gpa);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (entries.items.len == std.math.maxInt(u16)) return error.TooManyEntries;
        const source_path = try gpa.dupe(u8, entry.path);
        errdefer gpa.free(source_path);

        const archive_path = try archive_name(gpa, entry.path);
        errdefer gpa.free(archive_path);

        try entries.append(gpa, .{ .source_path = source_path, .archive_path = archive_path });
    }

    std.mem.sort(Entry, entries.items, {}, struct {
        fn order(_: void, a: Entry, b: Entry) bool {
            return std.mem.lessThan(u8, a.archive_path, b.archive_path);
        }
    }.order);
    if (entries.items.len > 1) for (entries.items[1..], entries.items[0 .. entries.items.len - 1]) |entry, previous| {
        if (std.mem.eql(u8, entry.archive_path, previous.archive_path)) return error.DuplicatePath;
    };

    // Phase 1: local file headers + data
    var cd_records: std.ArrayList(CdRecord) = .empty;
    defer cd_records.deinit(gpa);

    const compress_window = try gpa.create([flate.max_window_len]u8);
    defer gpa.destroy(compress_window);

    const comp_storage = try gpa.create(flate.Compress);
    defer gpa.destroy(comp_storage);

    var offset: u32 = 0;

    for (entries.items) |entry| {
        const rel_path = entry.archive_path;
        const data = try input_dir.readFileAlloc(io, entry.source_path, gpa, .limited(@min(opts.max_file_bytes, std.math.maxInt(u32))));
        defer gpa.free(data);

        const crc = Crc32.hash(data);
        const uncompressed_size: u32 = @intCast(data.len);
        const name_len: u16 = @intCast(rel_path.len);
        const local_header_offset = offset;

        const is_store = opts.store_all or for (opts.stored_extensions) |ext| {
            if (std.mem.endsWith(u8, rel_path, ext)) break true;
        } else false;
        var compression_method: u16 = if (is_store) 0 else 8;

        var compressed_size: u32 = uncompressed_size;
        var compressed_data: []const u8 = data;
        var compressed = try Io.Writer.Allocating.initCapacity(gpa, 4096);
        defer compressed.deinit();

        if (!is_store) {
            comp_storage.* = try flate.Compress.init(&compressed.writer, compress_window, .raw, .default);
            try comp_storage.writer.writeAll(data);
            try comp_storage.finish();
            if (compressed.written().len < data.len) {
                compressed_size = @intCast(compressed.written().len);
                compressed_data = compressed.written();
            } else compression_method = 0;
        }

        // Local file header (30 bytes)
        try w.writeAll(&local_file_header_sig);
        try w.writeInt(u16, 20, .little); // version needed
        try w.writeInt(u16, utf8_flag, .little);
        try w.writeInt(u16, compression_method, .little);
        try w.writeInt(u16, 0, .little); // mod time
        try w.writeInt(u16, 0, .little); // mod date
        try w.writeInt(u32, crc, .little);
        try w.writeInt(u32, compressed_size, .little);
        try w.writeInt(u32, uncompressed_size, .little);
        try w.writeInt(u16, name_len, .little);
        try w.writeInt(u16, 0, .little); // extra field length

        try w.writeAll(rel_path);
        try w.writeAll(compressed_data);

        offset = std.math.add(u32, offset, 30 + @as(u32, name_len)) catch return error.ArchiveTooLarge;
        offset = std.math.add(u32, offset, compressed_size) catch return error.ArchiveTooLarge;

        try cd_records.append(gpa, .{
            .crc32 = crc,
            .compressed_size = compressed_size,
            .uncompressed_size = uncompressed_size,
            .compression_method = compression_method,
            .filename = rel_path,
            .local_header_offset = local_header_offset,
        });
    }

    // Phase 2: central directory
    const cd_offset = offset;

    for (cd_records.items) |rec| {
        const name_len: u16 = @intCast(rec.filename.len);

        try w.writeAll(&central_dir_header_sig);
        try w.writeInt(u16, 20, .little); // version made by
        try w.writeInt(u16, 20, .little); // version needed
        try w.writeInt(u16, utf8_flag, .little);
        try w.writeInt(u16, rec.compression_method, .little);
        try w.writeInt(u16, 0, .little); // mod time
        try w.writeInt(u16, 0, .little); // mod date
        try w.writeInt(u32, rec.crc32, .little);
        try w.writeInt(u32, rec.compressed_size, .little);
        try w.writeInt(u32, rec.uncompressed_size, .little);
        try w.writeInt(u16, name_len, .little);
        try w.writeInt(u16, 0, .little); // extra field length
        try w.writeInt(u16, 0, .little); // comment length
        try w.writeInt(u16, 0, .little); // disk number
        try w.writeInt(u16, 0, .little); // internal attributes
        try w.writeInt(u32, 0, .little); // external attributes
        try w.writeInt(u32, rec.local_header_offset, .little);
        try w.writeAll(rec.filename);

        offset = std.math.add(u32, offset, 46 + @as(u32, name_len)) catch return error.ArchiveTooLarge;
    }

    const cd_size = offset - cd_offset;
    const entry_count: u16 = @intCast(cd_records.items.len);

    // Phase 3: end of central directory (22 bytes)
    _ = std.math.add(u32, offset, 22) catch return error.ArchiveTooLarge;
    try w.writeAll(&end_of_central_dir_sig);
    try w.writeInt(u16, 0, .little); // disk number
    try w.writeInt(u16, 0, .little); // disk with CD
    try w.writeInt(u16, entry_count, .little); // entries on this disk
    try w.writeInt(u16, entry_count, .little); // total entries
    try w.writeInt(u32, cd_size, .little);
    try w.writeInt(u32, cd_offset, .little);
    try w.writeInt(u16, 0, .little); // comment length

    try w.flush();
}

fn archive_name(gpa: std.mem.Allocator, source_path: []const u8) ![]u8 {
    const path = try gpa.dupe(u8, source_path);
    errdefer gpa.free(path);

    if (caps.windows_paths) std.mem.replaceScalar(u8, path, '\\', '/');
    try validate_archive_name(path);
    return path;
}

fn validate_archive_name(path: []const u8) !void {
    if (path.len == 0 or std.mem.indexOfAny(u8, path, "\\:\x00") != null) return error.UnsafePath;
    if (path.len > std.math.maxInt(u16)) return error.NameTooLong;
    if (!std.unicode.utf8ValidateSlice(path)) return error.InvalidUtf8;
    var components = std.mem.splitScalar(u8, path, '/');
    while (components.next()) |component| {
        if (component.len == 0 or std.mem.eql(u8, component, ".") or std.mem.eql(u8, component, "..")) return error.UnsafePath;
    }
}

fn path_within(parent: []const u8, candidate: []const u8) bool {
    if (candidate.len < parent.len) return false;
    const prefix_matches = if (caps.windows_paths)
        std.ascii.eqlIgnoreCase(parent, candidate[0..parent.len])
    else
        std.mem.eql(u8, parent, candidate[0..parent.len]);
    if (!prefix_matches) return false;
    return parent.len == candidate.len or parent[parent.len - 1] == std.fs.path.sep or candidate[parent.len] == std.fs.path.sep;
}

test "packing is deterministic and obeys stored-extension and input-size policies" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    for ([_][]const u8{ "b.raw", "a.txt" }) |name| {
        const file = try tmp.dir.createFile(io, name, .{});
        defer file.close(io);

        try file.writeStreamingAll(io, "repeated repeated repeated repeated repeated repeated");
    }
    var first = Io.Writer.Allocating.init(allocator);
    defer first.deinit();

    var second = Io.Writer.Allocating.init(allocator);
    defer second.deinit();

    const opts = Options{ .stored_extensions = &.{".raw"} };
    try pack_directory(allocator, io, tmp.dir, &first.writer, opts);
    try pack_directory(allocator, io, tmp.dir, &second.writer, opts);
    try std.testing.expectEqualSlices(u8, first.written(), second.written());
    const bytes = first.written();
    try std.testing.expectEqualStrings("a.txt", bytes[30..35]);
    try std.testing.expectEqual(@as(u16, 8), std.mem.readInt(u16, bytes[8..10], .little));
    const second_offset = 35 + std.mem.readInt(u32, bytes[18..22], .little);
    try std.testing.expectEqual(@as(u16, 0), std.mem.readInt(u16, bytes[second_offset + 8 ..][0..2], .little));
    try std.testing.expectError(error.StreamTooLong, pack_directory(allocator, io, tmp.dir, &second.writer, .{ .max_file_bytes = 2 }));
}

test "archive names reject traversal ambiguity and invalid UTF-8" {
    for ([_][]const u8{ "", "/absolute", "../escape", "a/../b", "a/./b", "a//b", "a/", "a\\b", "C:/drive", "a\x00b" }) |path| {
        try std.testing.expectError(error.UnsafePath, validate_archive_name(path));
    }
    try std.testing.expectError(error.InvalidUtf8, validate_archive_name("bad\xffname"));
    try validate_archive_name("nested/caf\xc3\xa9.txt");
    try validate_archive_name(".../file..txt");
    const filename = try archive_name(std.testing.allocator, if (caps.windows_paths) "nested\\file.txt" else "nested/file.txt");
    defer std.testing.allocator.free(filename);

    try std.testing.expectEqualStrings("nested/file.txt", filename);
    if (!caps.windows_paths) {
        try std.testing.expectError(error.UnsafePath, archive_name(std.testing.allocator, "..\\escape"));
        try std.testing.expect(path_within("/tmp/input", "/tmp/input/child"));
        try std.testing.expect(!path_within("/tmp/input", "/tmp/input-other"));
        try std.testing.expect(path_within("/", "/tmp/input"));
    }
}

test "packing writes UTF-8 flags in local and central headers" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const name = "caf\xc3\xa9.txt";
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = name, .data = "data" });
    var output = Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();

    try pack_directory(std.testing.allocator, std.testing.io, tmp.dir, &output.writer, .{ .store_all = true });
    const bytes = output.written();
    try std.testing.expectEqual(utf8_flag, std.mem.readInt(u16, bytes[6..8], .little));
    try std.testing.expectEqualStrings(name, bytes[30..][0..name.len]);
    const central = 30 + name.len + 4;
    try std.testing.expectEqual(utf8_flag, std.mem.readInt(u16, bytes[central + 8 ..][0..2], .little));
    try std.testing.expectEqualStrings(name, bytes[central + 46 ..][0..name.len]);
}

test "POSIX backslash names never read outside the input directory" {
    if (caps.windows_paths) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.createDir(std.testing.io, "input", .default_dir);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "outside", .data = "external bytes" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "input/..\\outside", .data = "local bytes" });
    var input = try tmp.dir.openDir(std.testing.io, "input", .{ .iterate = true });
    defer input.close(std.testing.io);

    var output = Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();

    try std.testing.expectError(error.UnsafePath, pack_directory(std.testing.allocator, std.testing.io, input, &output.writer, .{}));
    try std.testing.expectEqual(@as(usize, 0), output.written().len);
}

test "packing skips file and directory symlinks" {
    if (caps.windows_paths) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.createDir(std.testing.io, "input", .default_dir);
    try tmp.dir.createDir(std.testing.io, "outside", .default_dir);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "outside/file", .data = "external bytes" });
    try tmp.dir.symLink(std.testing.io, "../outside", "input/directory-link", .{ .is_directory = true });
    try tmp.dir.symLink(std.testing.io, "../outside/file", "input/file-link", .{});
    var input = try tmp.dir.openDir(std.testing.io, "input", .{ .iterate = true });
    defer input.close(std.testing.io);

    var output = Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();

    try pack_directory(std.testing.allocator, std.testing.io, input, &output.writer, .{});
    try std.testing.expectEqual(@as(usize, 22), output.written().len);
    try std.testing.expectEqualSlices(u8, &end_of_central_dir_sig, output.written()[0..4]);
}
