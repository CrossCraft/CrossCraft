/// ZIP archive reader for texture/resource pack loading.
///
/// Wraps `std.zip` to open files by path and stream decompressed contents via
/// `Io.Reader`.
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

index: []IndexEntry,
name_blob: []u8,

streams: [max_streams]StreamSlot,

const IndexEntry = struct {
    entry: zip.Iterator.Entry,
    name_offset: usize,
    name_len: u32,
};

const StreamSlot = struct {
    in_use: bool = false,

    stream_read_buf: [4096]u8 = undefined,
    stream_file_reader: File.Reader = undefined,

    flate_buf: [flate.max_window_len]u8 = undefined,
    decompressor: flate.Decompress = undefined,

    limited: Io.Reader.Limited = undefined,

    /// Absolute byte offset of the file's raw data inside the zip archive.
    data_offset: u64 = 0,
    uncompressed_size: u64 = 0,
};

pub const Stream = struct {
    slot_index: u32,
    reader: *Io.Reader,
    /// Absolute byte offset of the file's raw data inside the zip archive.
    data_offset: u64,
    uncompressed_size: u64,
    compression_method: zip.CompressionMethod,
};

/// Opens the archive at `path` (resolved against `dir`). Pass the
/// engine-owned resources or data dir -- not `Io.Dir.cwd()`, which is not
/// guaranteed to match the app root under Finder-launched `.app` bundles.
pub fn init(allocator: std.mem.Allocator, _io: Io, dir: std.Io.Dir, path: []const u8) !*Zip {
    assert(path.len > 0);

    const self = try allocator.create(Zip);
    errdefer allocator.destroy(self);

    self.file = try dir.openFile(_io, path, .{});
    errdefer self.file.close(_io);

    self.allocator = allocator;
    self.io = _io;
    self.file_reader = File.Reader.init(self.file, _io, &self.file_read_buf);

    self.index = &.{};
    self.name_blob = &.{};
    errdefer self.free_index();
    try self.build_index();

    for (&self.streams) |*slot| {
        slot.in_use = false;
    }

    return self;
}

pub fn deinit(self: *Zip) void {
    for (self.streams) |slot| {
        assert(!slot.in_use);
    }
    self.free_index();
    self.file.close(self.io);
    const allocator = self.allocator;
    self.* = undefined;
    allocator.destroy(self);
}

fn build_index(self: *Zip) !void {
    var iter = try zip.Iterator.init(&self.file_reader);
    if (iter.cd_record_count > max_cd_entries) return error.ZipTooManyEntries;

    var index_len: usize = 0;
    var name_bytes: usize = 0;
    while (try iter.next()) |entry| {
        if (entry.filename_len > max_filename_len) continue;
        index_len += 1;
        name_bytes += entry.filename_len;
    }

    const new_index = try self.allocator.alloc(IndexEntry, index_len);
    errdefer self.allocator.free(new_index);
    const new_name_blob = try self.allocator.alloc(u8, name_bytes);
    errdefer self.allocator.free(new_name_blob);

    var name_offset: usize = 0;
    var i: usize = 0;
    iter = try zip.Iterator.init(&self.file_reader);
    if (iter.cd_record_count > max_cd_entries) return error.ZipTooManyEntries;
    while (try iter.next()) |entry| {
        if (entry.filename_len > max_filename_len) continue;

        const name_len: usize = @intCast(entry.filename_len);
        const name = new_name_blob[name_offset .. name_offset + name_len];
        try self.file_reader.seekTo(entry.header_zip_offset + @sizeOf(zip.CentralDirectoryFileHeader));
        try self.file_reader.interface.readSliceAll(name);

        new_index[i] = .{
            .entry = entry,
            .name_offset = name_offset,
            .name_len = entry.filename_len,
        };
        name_offset += name_len;
        i += 1;
    }
    assert(i == index_len);
    assert(name_offset == name_bytes);

    self.index = new_index;
    self.name_blob = new_name_blob;
}

fn free_index(self: *Zip) void {
    self.allocator.free(self.index);
    self.allocator.free(self.name_blob);
    self.index = &.{};
    self.name_blob = &.{};
}

fn find_index_entry(self: *const Zip, path: []const u8) ?*const IndexEntry {
    if (path.len > max_filename_len) return null;

    for (self.index) |*entry| {
        if (entry.name_len != path.len) continue;
        const name_len: usize = @intCast(entry.name_len);
        const name = self.name_blob[entry.name_offset .. entry.name_offset + name_len];
        if (std.mem.eql(u8, name, path)) return entry;
    }
    return null;
}

pub fn open(self: *Zip, path: []const u8) !Stream {
    const slot_index: u32 = for (&self.streams, 0..) |*slot, i| {
        if (!slot.in_use) break @as(u32, @intCast(i));
    } else return error.StreamsExhausted;

    const slot = &self.streams[slot_index];
    const index_entry = self.find_index_entry(path) orelse return error.FileNotFound;

    try setup_stream(self, slot, &index_entry.entry);
    slot.in_use = true;

    return .{
        .slot_index = slot_index,
        .reader = &slot.limited.interface,
        .data_offset = slot.data_offset,
        .uncompressed_size = slot.uncompressed_size,
        .compression_method = index_entry.entry.compression_method,
    };
}

fn setup_stream(self: *Zip, slot: *StreamSlot, entry: *const zip.Iterator.Entry) !void {
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

pub fn close_stream(self: *Zip, stream: *const Stream) void {
    assert(stream.slot_index < max_streams);
    const slot = &self.streams[stream.slot_index];
    assert(slot.in_use);
    slot.in_use = false;
}

const testing = std.testing;

const TestZip = struct {
    tmp: testing.TmpDir,
    zip: *Zip,

    fn deinit(self: *TestZip) void {
        self.zip.deinit();
        self.tmp.cleanup();
        self.* = undefined;
    }
};

fn open_test_zip() !TestZip {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    errdefer tmp.cleanup();

    {
        const file = try tmp.dir.createFile(io, "test.zip", .{});
        defer file.close(io);

        var write_buf: [4096]u8 = undefined;
        var writer = file.writer(io, &write_buf);
        try writer.interface.writeAll(@embedFile("testdata/test.zip"));
        try writer.interface.flush();
    }

    return .{
        .tmp = tmp,
        .zip = try Zip.init(testing.allocator, io, tmp.dir, "test.zip"),
    };
}

test "open by path stored" {
    var fixture = try open_test_zip();
    defer fixture.deinit();

    const z = fixture.zip;

    var stream = try z.open("hello.txt");
    defer z.close_stream(&stream);

    var buf: [64]u8 = undefined;
    var result: Io.Writer = .fixed(&buf);
    try stream.reader.streamExact64(&result, 18);

    try testing.expectEqualStrings("Hello, CrossCraft!", buf[0..18]);
}

test "open by path deflate" {
    var fixture = try open_test_zip();
    defer fixture.deinit();

    const z = fixture.zip;

    var stream = try z.open("compressed.txt");
    defer z.close_stream(&stream);

    const expected = "This is a compressed file. " ** 20;

    var buf: [expected.len]u8 = undefined;
    var result: Io.Writer = .fixed(&buf);
    try stream.reader.streamExact64(&result, expected.len);

    try testing.expectEqualStrings(expected, &buf);
}

test "open nested path" {
    var fixture = try open_test_zip();
    defer fixture.deinit();

    const z = fixture.zip;

    var stream = try z.open("subdir/nested.txt");
    defer z.close_stream(&stream);

    var buf: [64]u8 = undefined;
    var result: Io.Writer = .fixed(&buf);
    try stream.reader.streamExact64(&result, 11);

    try testing.expectEqualStrings("nested file", buf[0..11]);
}

test "open nonexistent" {
    var fixture = try open_test_zip();
    defer fixture.deinit();

    const z = fixture.zip;

    const result = z.open("nope.txt");
    try testing.expectError(error.FileNotFound, result);
}

test "two simultaneous streams" {
    var fixture = try open_test_zip();
    defer fixture.deinit();

    const z = fixture.zip;

    var s1 = try z.open("hello.txt");
    defer z.close_stream(&s1);

    var s2 = try z.open("subdir/nested.txt");
    defer z.close_stream(&s2);

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
    var fixture = try open_test_zip();
    defer fixture.deinit();

    const z = fixture.zip;

    var s1 = try z.open("hello.txt");
    defer z.close_stream(&s1);

    var s2 = try z.open("subdir/nested.txt");
    defer z.close_stream(&s2);

    const result = z.open("compressed.txt");
    try testing.expectError(error.StreamsExhausted, result);
}
