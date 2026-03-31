/// Build tool: packs a directory into a store-only ZIP archive.
///
/// Usage: pack_zip <input_dir> <output_file>
///
/// Walks the input directory recursively and writes all files into a
/// ZIP archive using the "store" method (no compression). Paths inside
/// the ZIP use forward slashes regardless of host OS.
const std = @import("std");
const Io = std.Io;
const Dir = Io.Dir;
const File = Io.File;
const Allocator = std.mem.Allocator;
const Crc32 = std.hash.crc.Crc32IsoHdlc;

const local_file_header_sig = [4]u8{ 0x50, 0x4b, 0x03, 0x04 };
const central_dir_header_sig = [4]u8{ 0x50, 0x4b, 0x01, 0x02 };
const end_of_central_dir_sig = [4]u8{ 0x50, 0x4b, 0x05, 0x06 };

const CdRecord = struct {
    crc32: u32,
    size: u32,
    filename: []const u8,
    local_header_offset: u32,
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 3) return error.InvalidArguments;

    const input_path = args[1];
    const output_path = args[2];

    var input_dir = try Dir.openDirAbsolute(io, input_path, .{ .iterate = true });
    defer input_dir.close(io);

    // Collect file paths
    var entries: std.ArrayList([]const u8) = .empty;
    defer {
        for (entries.items) |e| gpa.free(e);
        entries.deinit(gpa);
    }

    var walker = try input_dir.walk(gpa);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const path = try gpa.dupe(u8, entry.path);
        // Normalize to forward slashes for ZIP compatibility
        std.mem.replaceScalar(u8, path, '\\', '/');
        try entries.append(gpa, path);
    }

    // Sort for deterministic output
    std.mem.sort([]const u8, entries.items, {}, struct {
        fn order(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.order);

    // Create output file
    const output_file = try Dir.createFileAbsolute(io, output_path, .{});
    defer output_file.close(io);

    var write_buf: [8192]u8 = undefined;
    var writer = output_file.writer(io, &write_buf);
    const w = &writer.interface;

    // Phase 1: local file headers + data
    var cd_records: std.ArrayList(CdRecord) = .empty;
    defer {
        for (cd_records.items) |r| gpa.free(r.filename);
        cd_records.deinit(gpa);
    }

    var offset: u32 = 0;

    for (entries.items) |rel_path| {
        const data = try input_dir.readFileAlloc(io, rel_path, gpa, .unlimited);
        defer gpa.free(data);

        const crc = Crc32.hash(data);
        const size: u32 = @intCast(data.len);
        const name_len: u16 = @intCast(rel_path.len);
        const local_header_offset = offset;

        // Local file header (30 bytes)
        try w.writeAll(&local_file_header_sig);
        try w.writeInt(u16, 20, .little); // version needed
        try w.writeInt(u16, 0, .little); // flags
        try w.writeInt(u16, 0, .little); // compression: store
        try w.writeInt(u16, 0, .little); // mod time
        try w.writeInt(u16, 0, .little); // mod date
        try w.writeInt(u32, crc, .little);
        try w.writeInt(u32, size, .little); // compressed size
        try w.writeInt(u32, size, .little); // uncompressed size
        try w.writeInt(u16, name_len, .little);
        try w.writeInt(u16, 0, .little); // extra field length

        try w.writeAll(rel_path);
        try w.writeAll(data);

        offset += 30 + @as(u32, name_len) + size;

        try cd_records.append(gpa, .{
            .crc32 = crc,
            .size = size,
            .filename = try gpa.dupe(u8, rel_path),
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
        try w.writeInt(u16, 0, .little); // flags
        try w.writeInt(u16, 0, .little); // compression: store
        try w.writeInt(u16, 0, .little); // mod time
        try w.writeInt(u16, 0, .little); // mod date
        try w.writeInt(u32, rec.crc32, .little);
        try w.writeInt(u32, rec.size, .little); // compressed size
        try w.writeInt(u32, rec.size, .little); // uncompressed size
        try w.writeInt(u16, name_len, .little);
        try w.writeInt(u16, 0, .little); // extra field length
        try w.writeInt(u16, 0, .little); // comment length
        try w.writeInt(u16, 0, .little); // disk number
        try w.writeInt(u16, 0, .little); // internal attributes
        try w.writeInt(u32, 0, .little); // external attributes
        try w.writeInt(u32, rec.local_header_offset, .little);
        try w.writeAll(rec.filename);

        offset += 46 + @as(u32, name_len);
    }

    const cd_size = offset - cd_offset;
    const entry_count: u16 = @intCast(cd_records.items.len);

    // Phase 3: end of central directory (22 bytes)
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
