//! Resource-pack ZIP reader. Heap allocation keeps stream decompression
//! windows off the stack.
const Zip = @This();

const std = @import("std");
const Io = std.Io;
const File = std.Io.File;
const flate = std.compress.flate;
const zip = std.zip;
const assert = std.debug.assert;

const max_filename_len: u32 = 256;
const max_streams: u32 = 2;
const max_cd_entries: u32 = 65536;

allocator: std.mem.Allocator,
file: File,
io: Io,

index: []IndexEntry,
name_blob: []u8,

streams: [max_streams]StreamSlot,

const IndexEntry = struct {
    entry: zip.Iterator.Entry,
    name_offset: usize,
};

const StreamSlot = struct {
    in_use: bool = false,

    stream_read_buf: [4096]u8 = undefined,
    stream_file_reader: File.Reader = undefined,

    flate_buf: [flate.max_window_len]u8 = undefined,
    decompressor: flate.Decompress = undefined,

    limited: Io.Reader.Limited = undefined,
};

pub const Stream = struct {
    slot_index: u32,
    reader: *Io.Reader,
    /// Absolute byte offset of the file's raw data inside the zip archive.
    data_offset: u64,
    compression_method: zip.CompressionMethod,
};

/// Use engine-owned directories: cwd may differ under Finder-launched apps.
pub fn init(allocator: std.mem.Allocator, _io: Io, dir: std.Io.Dir, path: []const u8) !*Zip {
    assert(path.len > 0);

    const self = try allocator.create(Zip);
    errdefer allocator.destroy(self);

    self.file = try dir.openFile(_io, path, .{});
    errdefer self.file.close(_io);

    self.allocator = allocator;
    self.io = _io;

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
    self.allocator.free(self.index);
    self.allocator.free(self.name_blob);
    self.file.close(self.io);
    const allocator = self.allocator;
    self.* = undefined;
    allocator.destroy(self);
}

fn build_index(self: *Zip) !void {
    // Streams are idle until indexing completes; reuse their heap buffer.
    var reader = File.Reader.init(self.file, self.io, &self.streams[0].stream_read_buf);
    var iter = try zip.Iterator.init(&reader);
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
    iter = try zip.Iterator.init(&reader);
    if (iter.cd_record_count > max_cd_entries) return error.ZipTooManyEntries;
    while (try iter.next()) |entry| {
        if (entry.filename_len > max_filename_len) continue;

        const name_len: usize = @intCast(entry.filename_len);
        const name = new_name_blob[name_offset .. name_offset + name_len];
        try reader.seekTo(entry.header_zip_offset + @sizeOf(zip.CentralDirectoryFileHeader));
        try reader.interface.readSliceAll(name);

        new_index[i] = .{
            .entry = entry,
            .name_offset = name_offset,
        };
        name_offset += name_len;
        i += 1;
    }
    assert(i == index_len);
    assert(name_offset == name_bytes);

    self.index = new_index;
    self.name_blob = new_name_blob;
}

pub fn open(self: *Zip, path: []const u8) !Stream {
    const slot_index: u32 = for (&self.streams, 0..) |*slot, i| {
        if (!slot.in_use) break @as(u32, @intCast(i));
    } else return error.StreamsExhausted;

    const slot = &self.streams[slot_index];
    const entry = for (self.index) |*indexed| {
        const name = self.name_blob[indexed.name_offset..][0..indexed.entry.filename_len];
        if (std.mem.eql(u8, name, path)) break &indexed.entry;
    } else return error.FileNotFound;
    slot.stream_file_reader = File.Reader.init(self.file, self.io, &slot.stream_read_buf);

    try slot.stream_file_reader.seekTo(entry.file_offset);
    const local_header = try slot.stream_file_reader.interface.takeStruct(
        zip.LocalFileHeader,
        .little,
    );

    if (!std.mem.eql(u8, &local_header.signature, &zip.local_file_header_sig))
        return error.ZipBadFileOffset;

    const data_offset: u64 = entry.file_offset + @sizeOf(zip.LocalFileHeader) +
        @as(u64, local_header.filename_len) + @as(u64, local_header.extra_len);

    try slot.stream_file_reader.seekTo(data_offset);

    const reader = switch (entry.compression_method) {
        .store => &slot.stream_file_reader.interface,
        .deflate => blk: {
            slot.decompressor = flate.Decompress.init(
                &slot.stream_file_reader.interface,
                .raw,
                &slot.flate_buf,
            );
            break :blk &slot.decompressor.reader;
        },
        else => return error.UnsupportedCompressionMethod,
    };
    slot.limited = .init(reader, Io.Limit.limited64(entry.uncompressed_size), &.{});
    slot.in_use = true;
    return .{
        .slot_index = slot_index,
        .reader = &slot.limited.interface,
        .data_offset = data_offset,
        .compression_method = entry.compression_method,
    };
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

test "ZIP stored, deflated, and nested entries stay within their bounds" {
    var fixture = try open_test_zip();
    defer fixture.deinit();

    const z = fixture.zip;

    const cases = .{
        .{ "hello.txt", "Hello, CrossCraft!" },
        .{ "compressed.txt", "This is a compressed file. " ** 20 },
        .{ "subdir/nested.txt", "nested file" },
    };
    inline for (cases) |case| {
        const stream = try z.open(case[0]);
        defer z.close_stream(&stream);

        var buf: [case[1].len]u8 = undefined;
        try stream.reader.readSliceAll(&buf);
        try testing.expectEqualStrings(case[1], &buf);
        var tail: [1]u8 = undefined;
        try testing.expectError(error.EndOfStream, stream.reader.readSliceAll(&tail));
    }
    try testing.expectError(error.FileNotFound, z.open("nope.txt"));
}

test "ZIP streams can interleave and reuse exhausted slots" {
    var fixture = try open_test_zip();
    defer fixture.deinit();

    const z = fixture.zip;

    const s2 = try z.open("compressed.txt");
    defer z.close_stream(&s2);

    var deflated: ["This is a compressed file. ".len]u8 = undefined;
    {
        const s1 = try z.open("hello.txt");
        defer z.close_stream(&s1);

        try testing.expectError(error.StreamsExhausted, z.open("subdir/nested.txt"));

        var stored: [18]u8 = undefined;
        try s1.reader.readSliceAll(stored[0..5]);
        try s2.reader.readSliceAll(&deflated);
        try testing.expectEqualStrings("This is a compressed file. ", &deflated);
        try s1.reader.readSliceAll(stored[5..]);
        try testing.expectEqualStrings("Hello, CrossCraft!", &stored);
    }

    const s3 = try z.open("subdir/nested.txt");
    defer z.close_stream(&s3);

    var nested: [11]u8 = undefined;
    try s3.reader.readSliceAll(&nested);
    try testing.expectEqualStrings("nested file", &nested);
    try s2.reader.readSliceAll(&deflated);
    try testing.expectEqualStrings("This is a compressed file. ", &deflated);
}
