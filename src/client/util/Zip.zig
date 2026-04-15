/// ZIP archive reader for texture/resource pack loading.
///
/// Wraps `std.zip` to provide a directory-like interface: iterate entries,
/// open files by path, and stream decompressed contents via `Io.Reader`.
/// Supports at most 2 simultaneous open file streams.
///
/// The `Zip` struct is heap-allocated because each stream slot contains a
/// 64 KiB decompression window that must not live on the stack.
const Zip = @This();

const std = @import("std");
const Io = std.Io;
const File = std.Io.File;
const flate = std.compress.flate;
const zip = std.zip;
const assert = std.debug.assert;

const max_filename_len: u32 = 256;
const max_streams: u32 = 2;
/// Upper bound on central directory entries to prevent unbounded iteration.
const max_cd_entries: u32 = 65536;

allocator: std.mem.Allocator,
file: File,
io: Io,

file_read_buf: [4096]u8,
file_reader: File.Reader,

cd_record_count: u64,
cd_zip_offset: u64,
cd_size: u64,

streams: [max_streams]StreamSlot,

const StreamSlot = struct {
    in_use: bool = false,
    filename_buf: [max_filename_len]u8 = undefined,
    filename_len: u32 = 0,

    stream_read_buf: [4096]u8 = undefined,
    stream_file_reader: File.Reader = undefined,

    flate_buf: [flate.max_window_len]u8 = undefined,
    decompressor: flate.Decompress = undefined,

    limited: Io.Reader.Limited = undefined,

    /// Absolute byte offset of the file's raw data inside the zip archive.
    data_offset: u64 = 0,
    uncompressed_size: u64 = 0,
};

pub const Entry = struct {
    inner: zip.Iterator.Entry,
    filename: []const u8,

    pub fn isDirectory(self: *const Entry) bool {
        return self.filename.len > 0 and self.filename[self.filename.len - 1] == '/';
    }
};

pub const Stream = struct {
    slot_index: u32,
    reader: *Io.Reader,
    /// Absolute byte offset of the file's raw data inside the zip archive.
    data_offset: u64,
    uncompressed_size: u64,
    compression_method: zip.CompressionMethod,
};

pub const Iterator = struct {
    zip_state: *Zip,
    inner: zip.Iterator,
    filename_buf: [max_filename_len]u8 = undefined,

    pub fn next(self: *Iterator) !?Entry {
        const entry = try self.inner.next() orelse return null;

        if (entry.filename_len > max_filename_len) return error.ZipFilenameTooLong;

        const fr = &self.zip_state.file_reader;
        try fr.seekTo(entry.header_zip_offset + @sizeOf(zip.CentralDirectoryFileHeader));
        try fr.interface.readSliceAll(self.filename_buf[0..entry.filename_len]);

        return .{
            .inner = entry,
            .filename = self.filename_buf[0..entry.filename_len],
        };
    }
};

/// Opens the archive at `path` (resolved against `dir`). Pass the
/// engine-owned resources or data dir — not `Io.Dir.cwd()`, which is not
/// guaranteed to match the app root under Finder-launched `.app` bundles.
pub fn init(allocator: std.mem.Allocator, _io: Io, dir: Io.Dir, path: []const u8) !*Zip {
    std.debug.assert(path.len > 0);

    const self = try allocator.create(Zip);
    errdefer allocator.destroy(self);

    self.file = try dir.openFile(_io, path, .{});
    errdefer self.file.close(_io);

    self.allocator = allocator;
    self.io = _io;
    self.file_reader = File.Reader.init(self.file, _io, &self.file_read_buf);

    const iter = try zip.Iterator.init(&self.file_reader);
    self.cd_record_count = iter.cd_record_count;
    self.cd_zip_offset = iter.cd_zip_offset;
    self.cd_size = iter.cd_size;

    for (&self.streams) |*slot| {
        slot.in_use = false;
    }

    return self;
}

pub fn deinit(self: *Zip) void {
    for (self.streams) |slot| {
        assert(!slot.in_use);
    }
    self.file.close(self.io);
    const allocator = self.allocator;
    allocator.destroy(self);
}

pub fn iterator(self: *Zip) Iterator {
    return .{
        .zip_state = self,
        .inner = .{
            .input = &self.file_reader,
            .cd_record_count = self.cd_record_count,
            .cd_zip_offset = self.cd_zip_offset,
            .cd_size = self.cd_size,
        },
    };
}

pub fn open(self: *Zip, path: []const u8) !Stream {
    const slot_index: u32 = for (&self.streams, 0..) |*slot, i| {
        if (!slot.in_use) break @as(u32, @intCast(i));
    } else return error.StreamsExhausted;

    const slot = &self.streams[slot_index];

    var iter: zip.Iterator = .{
        .input = &self.file_reader,
        .cd_record_count = self.cd_record_count,
        .cd_zip_offset = self.cd_zip_offset,
        .cd_size = self.cd_size,
    };

    var count: u32 = 0;
    while (count < max_cd_entries) : (count += 1) {
        const entry = iter.next() catch |err| return err;
        const zip_entry = entry orelse return error.FileNotFound;

        if (zip_entry.filename_len != path.len) continue;
        if (zip_entry.filename_len > max_filename_len) continue;

        // Read filename from central directory header
        self.file_reader.seekTo(
            zip_entry.header_zip_offset + @sizeOf(zip.CentralDirectoryFileHeader),
        ) catch |err| return err;

        self.file_reader.interface.readSliceAll(
            slot.filename_buf[0..zip_entry.filename_len],
        ) catch |err| return err;

        if (!std.mem.eql(u8, slot.filename_buf[0..zip_entry.filename_len], path)) continue;

        // Found the matching entry - set up streaming
        slot.filename_len = zip_entry.filename_len;
        try setupStream(self, slot, &zip_entry);
        slot.in_use = true;

        return .{
            .slot_index = slot_index,
            .reader = &slot.limited.interface,
            .data_offset = slot.data_offset,
            .uncompressed_size = slot.uncompressed_size,
            .compression_method = zip_entry.compression_method,
        };
    }

    return error.FileNotFound;
}

fn setupStream(self: *Zip, slot: *StreamSlot, entry: *const zip.Iterator.Entry) !void {
    slot.stream_file_reader = File.Reader.init(self.file, self.io, &slot.stream_read_buf);

    // Read local file header to compute the data offset
    try slot.stream_file_reader.seekTo(entry.file_offset);
    const local_header = try slot.stream_file_reader.interface.takeStruct(
        zip.LocalFileHeader,
        .little,
    );

    if (!std.mem.eql(u8, &local_header.signature, &zip.local_file_header_sig))
        return error.ZipBadFileOffset;

    const data_offset: u64 = entry.file_offset + @sizeOf(zip.LocalFileHeader) +
        @as(u64, local_header.filename_len) + @as(u64, local_header.extra_len);

    slot.data_offset = data_offset;
    slot.uncompressed_size = entry.uncompressed_size;

    try slot.stream_file_reader.seekTo(data_offset);

    switch (entry.compression_method) {
        .store => {
            slot.limited = .init(
                &slot.stream_file_reader.interface,
                Io.Limit.limited64(entry.uncompressed_size),
                &.{},
            );
        },
        .deflate => {
            slot.decompressor = flate.Decompress.init(
                &slot.stream_file_reader.interface,
                .raw,
                &slot.flate_buf,
            );
            slot.limited = .init(
                &slot.decompressor.reader,
                Io.Limit.limited64(entry.uncompressed_size),
                &.{},
            );
        },
        else => return error.UnsupportedCompressionMethod,
    }
}

pub fn closeStream(self: *Zip, stream: *const Stream) void {
    assert(stream.slot_index < max_streams);
    const slot = &self.streams[stream.slot_index];
    assert(slot.in_use);
    slot.in_use = false;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn openTestZip() !*Zip {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    errdefer tmp.cleanup();

    // Write embedded test fixture to a temp file
    const zip_data = @embedFile("testdata/test.zip");
    const file = try tmp.dir.createFile(io, "test.zip", .{});
    var write_buf: [4096]u8 = undefined;
    var writer = file.writer(io, &write_buf);
    try writer.interface.writeAll(zip_data);
    try writer.interface.flush();
    file.close(io);

    // Re-open for reading
    const read_file = try tmp.dir.openFile(io, "test.zip", .{});
    const allocator = testing.allocator;
    const self = try allocator.create(Zip);
    errdefer allocator.destroy(self);

    self.file = read_file;
    errdefer self.file.close(io);

    self.allocator = allocator;
    self.io = io;
    self.file_reader = File.Reader.init(self.file, io, &self.file_read_buf);

    const it = try zip.Iterator.init(&self.file_reader);
    self.cd_record_count = it.cd_record_count;
    self.cd_zip_offset = it.cd_zip_offset;
    self.cd_size = it.cd_size;

    for (&self.streams) |*slot| {
        slot.in_use = false;
    }

    return self;
}

test "init and deinit" {
    const z = try openTestZip();
    defer z.deinit();

    try testing.expect(z.cd_record_count == 3);
}

test "iterate entries" {
    const z = try openTestZip();
    defer z.deinit();

    var it = z.iterator();
    var count: u32 = 0;
    var found_hello = false;
    var found_compressed = false;
    var found_nested = false;

    while (try it.next()) |entry| {
        if (std.mem.eql(u8, entry.filename, "hello.txt")) found_hello = true;
        if (std.mem.eql(u8, entry.filename, "compressed.txt")) found_compressed = true;
        if (std.mem.eql(u8, entry.filename, "subdir/nested.txt")) found_nested = true;
        count += 1;
    }

    try testing.expectEqual(@as(u32, 3), count);
    try testing.expect(found_hello);
    try testing.expect(found_compressed);
    try testing.expect(found_nested);
}

test "open by path stored" {
    const z = try openTestZip();
    defer z.deinit();

    var stream = try z.open("hello.txt");
    defer z.closeStream(&stream);

    var buf: [64]u8 = undefined;
    var result: Io.Writer = .fixed(&buf);
    try stream.reader.streamExact64(&result, 18);

    try testing.expectEqualStrings("Hello, CrossCraft!", buf[0..18]);
}

test "open by path deflate" {
    const z = try openTestZip();
    defer z.deinit();

    var stream = try z.open("compressed.txt");
    defer z.closeStream(&stream);

    const expected = "This is a compressed file. " ** 20;

    var buf: [expected.len]u8 = undefined;
    var result: Io.Writer = .fixed(&buf);
    try stream.reader.streamExact64(&result, expected.len);

    try testing.expectEqualStrings(expected, &buf);
}

test "open nested path" {
    const z = try openTestZip();
    defer z.deinit();

    var stream = try z.open("subdir/nested.txt");
    defer z.closeStream(&stream);

    var buf: [64]u8 = undefined;
    var result: Io.Writer = .fixed(&buf);
    try stream.reader.streamExact64(&result, 11);

    try testing.expectEqualStrings("nested file", buf[0..11]);
}

test "open nonexistent" {
    const z = try openTestZip();
    defer z.deinit();

    const result = z.open("nope.txt");
    try testing.expectError(error.FileNotFound, result);
}

test "two simultaneous streams" {
    const z = try openTestZip();
    defer z.deinit();

    var s1 = try z.open("hello.txt");
    defer z.closeStream(&s1);

    var s2 = try z.open("subdir/nested.txt");
    defer z.closeStream(&s2);

    var buf1: [64]u8 = undefined;
    var w1: Io.Writer = .fixed(&buf1);
    try s1.reader.streamExact64(&w1, 18);

    var buf2: [64]u8 = undefined;
    var w2: Io.Writer = .fixed(&buf2);
    try s2.reader.streamExact64(&w2, 11);

    try testing.expectEqualStrings("Hello, CrossCraft!", buf1[0..18]);
    try testing.expectEqualStrings("nested file", buf2[0..11]);
}

test "stream slot exhaustion" {
    const z = try openTestZip();
    defer z.deinit();

    var s1 = try z.open("hello.txt");
    defer z.closeStream(&s1);

    var s2 = try z.open("subdir/nested.txt");
    defer z.closeStream(&s2);

    const result = z.open("compressed.txt");
    try testing.expectError(error.StreamsExhausted, result);
}
