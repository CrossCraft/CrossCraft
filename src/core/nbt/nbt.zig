const std = @import("std");

pub const WriteError = std.Io.Writer.Error;
pub const ReadError = std.Io.Reader.Error || error{InvalidTag};

pub const Tag = enum(u8) {
    end = 0,
    byte = 1,
    short = 2,
    int = 3,
    long = 4,
    float = 5,
    double = 6,
    byte_array = 7,
    string = 8,
    list = 9,
    compound = 10,
};

pub fn read_tag(reader: *std.Io.Reader) ReadError!Tag {
    const value = try reader.takeByte();
    if (value > @intFromEnum(Tag.compound)) return error.InvalidTag;
    return @enumFromInt(value);
}

pub const NBT = struct {
    name: []const u8,
    value: Value,

    pub const Value = union(Tag) {
        end: void,
        byte: i8,
        short: i16,
        int: i32,
        long: i64,
        float: f32,
        double: f64,
        byte_array: []const u8,
        string: []const u8,
        list: []const NBT,
        compound: []const NBT,
    };

    pub fn write(self: NBT, writer: *std.Io.Writer) WriteError!void {
        try write_header(writer, std.meta.activeTag(self.value), self.name);
        try write_payload(self.value, writer);
    }

    fn write_payload(value: Value, writer: *std.Io.Writer) WriteError!void {
        switch (value) {
            .end => {},
            .byte => |v| try writer.writeByte(@bitCast(v)),
            .short => |v| try writer.writeInt(i16, v, .big),
            .int => |v| try writer.writeInt(i32, v, .big),
            .long => |v| try writer.writeInt(i64, v, .big),
            .float => |v| try writer.writeInt(u32, @bitCast(v), .big),
            .double => |v| try writer.writeInt(u64, @bitCast(v), .big),
            .byte_array => |v| {
                try writer.writeInt(i32, @intCast(v.len), .big);
                try writer.writeAll(v);
            },
            .string => |v| try write_string(writer, v),
            .list => |items| {
                const tag: Tag = if (items.len == 0) .end else std.meta.activeTag(items[0].value);
                try writer.writeByte(@intFromEnum(tag));
                try writer.writeInt(i32, @intCast(items.len), .big);
                for (items) |item| try write_payload(item.value, writer);
            },
            .compound => |items| {
                for (items) |item| try item.write(writer);
                try writer.writeByte(@intFromEnum(Tag.end));
            },
        }
    }
};

fn write_string(writer: *std.Io.Writer, value: []const u8) WriteError!void {
    try writer.writeInt(u16, @intCast(value.len), .big);
    try writer.writeAll(value);
}

pub fn write_header(writer: *std.Io.Writer, tag: Tag, name: []const u8) WriteError!void {
    try writer.writeByte(@intFromEnum(tag));
    if (tag != .end) try write_string(writer, name);
}

test "writes nested NBT in network byte order" {
    const children = [_]NBT{
        .{ .name = "b", .value = .{ .byte = -1 } },
        .{ .name = "s", .value = .{ .short = 0x1234 } },
        .{ .name = "answer", .value = .{ .int = 42 } },
        .{ .name = "l", .value = .{ .long = 0x0102030405060708 } },
        .{ .name = "name", .value = .{ .string = "world" } },
    };
    const root: NBT = .{ .name = "root", .value = .{ .compound = &children } };

    var buf: [96]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try root.write(&writer);

    const expected = [_]u8{
        10,  0,   4,    'r',  'o',  'o', 't',
        1,   0,   1,    'b',  0xff, 2,   0,
        1,   's', 0x12, 0x34, 3,    0,   6,
        'a', 'n', 's',  'w',  'e',  'r', 0,
        0,   0,   42,   4,    0,    1,   'l',
        1,   2,   3,    4,    5,    6,   7,
        8,   8,   0,    4,    'n',  'a', 'm',
        'e', 0,   5,    'w',  'o',  'r', 'l',
        'd', 0,
    };
    try std.testing.expectEqualSlices(u8, &expected, writer.buffered());
}

test "writes a named byte array" {
    const payload = [_]u8{ 0xaa, 0xbb, 0xcc };
    var buf: [32]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    const array: NBT = .{ .name = "BlockArray", .value = .{ .byte_array = &payload } };
    try array.write(&writer);

    const expected = [_]u8{
        7, 0, 10, 'B', 'l',  'o',  'c',  'k', 'A', 'r', 'r', 'a', 'y',
        0, 0, 0,  3,   0xaa, 0xbb, 0xcc,
    };
    try std.testing.expectEqualSlices(u8, &expected, writer.buffered());
}
