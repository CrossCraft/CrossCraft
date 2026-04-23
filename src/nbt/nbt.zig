const std = @import("std");

pub const MAX_DEPTH = 512;

pub const ReadError = std.mem.Allocator.Error || std.Io.Reader.Error || error{
    InvalidTag,
    NegativeByteArray,
    NegativeListLength,
    MaxDepthExceeded,
};

pub const WriteError = std.Io.Writer.Error;

fn read_tag(reader: *std.Io.Reader) ReadError!Tag {
    const byte = try reader.takeInt(u8, .big);
    if (byte > @intFromEnum(Tag.compound)) return error.InvalidTag;
    return @enumFromInt(byte);
}

// NBTs are Indev-compatible at this point
// TAG 11 (INT_ARRAY)
// TAG 12 (LONG_ARRAY)
// Are used later into beta and official release.
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

    pub fn get_name(tag: Tag) [:0]const u8 {
        return switch (tag) {
            .end => "TAG_End",
            .byte => "TAG_Byte",
            .short => "TAG_Short",
            .int => "TAG_Int",
            .long => "TAG_Long",
            .float => "TAG_Float",
            .double => "TAG_Double",
            .byte_array => "TAG_Byte_Array",
            .string => "TAG_String",
            .list => "TAG_List",
            .compound => "TAG_Compound",
        };
    }
};

pub const PrefixString = struct {
    value: []u8,

    pub fn read(self: *PrefixString, allocator: std.mem.Allocator, reader: *std.Io.Reader) !void {
        const len = try reader.takeInt(u16, .big);
        self.value = try allocator.alloc(u8, len);

        return reader.readSliceAll(self.value);
    }

    pub fn write(self: PrefixString, writer: *std.Io.Writer) !void {
        try writer.writeInt(u16, @truncate(self.value.len), .big);

        // endian doesn't matter for u8
        try writer.writeSliceEndian(u8, self.value, .big);
    }
};

pub const End = void;

pub const Byte = struct {
    value: i8,

    pub fn read(self: *Byte, reader: *std.Io.Reader) !void {
        self.value = try reader.takeByteSigned();
    }

    pub fn write(self: Byte, writer: *std.Io.Writer) !void {
        try writer.writeByte(@bitCast(self.value));
    }
};

pub const Short = struct {
    value: i16,

    pub fn read(self: *Short, reader: *std.Io.Reader) !void {
        self.value = try reader.takeInt(i16, .big);
    }

    pub fn write(self: Short, writer: *std.Io.Writer) !void {
        try writer.writeInt(i16, self.value, .big);
    }
};

pub const Int = struct {
    value: i32,

    pub fn read(self: *Int, reader: *std.Io.Reader) !void {
        self.value = try reader.takeInt(i32, .big);
    }

    pub fn write(self: Int, writer: *std.Io.Writer) !void {
        try writer.writeInt(i32, self.value, .big);
    }
};

pub const Long = struct {
    value: i64,

    pub fn read(self: *Long, reader: *std.Io.Reader) !void {
        self.value = try reader.takeInt(i64, .big);
    }

    pub fn write(self: Long, writer: *std.Io.Writer) !void {
        try writer.writeInt(i64, self.value, .big);
    }
};

pub const Float = struct {
    value: f32,

    pub fn read(self: *Float, reader: *std.Io.Reader) !void {
        const bits = try reader.takeInt(u32, .big);
        self.value = @bitCast(bits);
    }

    pub fn write(self: Float, writer: *std.Io.Writer) !void {
        try writer.writeInt(u32, @bitCast(self.value), .big);
    }
};

pub const Double = struct {
    value: f64,

    pub fn read(self: *Double, reader: *std.Io.Reader) !void {
        const bits = try reader.takeInt(u64, .big);
        self.value = @bitCast(bits);
    }

    pub fn write(self: Double, writer: *std.Io.Writer) !void {
        try writer.writeInt(u64, @bitCast(self.value), .big);
    }
};

pub const ByteArray = struct {
    value: []u8,

    pub fn read(self: *ByteArray, allocator: std.mem.Allocator, reader: *std.Io.Reader) !void {
        const length = try reader.takeInt(i32, .big);
        if (length < 0) return error.NegativeByteArray;

        self.value = try allocator.alloc(u8, @intCast(length));
        try reader.readSliceAll(self.value);
    }

    pub fn write(self: ByteArray, writer: *std.Io.Writer) !void {
        try writer.writeInt(i32, @intCast(self.value.len), .big);
        try writer.writeSliceEndian(u8, self.value, .big);
    }
};

pub const String = PrefixString;

pub const List = struct {
    value: []NBT,

    pub fn read(self: *List, allocator: std.mem.Allocator, reader: *std.Io.Reader, depth: u16) ReadError!void {
        if (depth >= MAX_DEPTH) return error.MaxDepthExceeded;

        const elem_tag = try read_tag(reader);

        const length = try reader.takeInt(i32, .big);
        if (length < 0) return error.NegativeListLength;

        self.value = try allocator.alloc(NBT, @intCast(length));
        for (self.value) |*item| {
            // List elements are unnamed on the wire.
            item.name = .{ .value = &.{} };
            try NBT.read_payload(&item.value, allocator, reader, elem_tag, depth + 1);
        }
    }

    pub fn write(self: List, writer: *std.Io.Writer) WriteError!void {
        // Empty lists encode TAG_End as the element type per spec.
        const elem_tag: Tag = if (self.value.len == 0) .end else std.meta.activeTag(self.value[0].value);
        try writer.writeInt(u8, @intFromEnum(elem_tag), .big);
        try writer.writeInt(i32, @intCast(self.value.len), .big);
        for (self.value) |item| {
            try NBT.write_payload(item.value, writer);
        }
    }
};

pub const Compound = struct {
    value: []NBT,

    pub fn read(self: *Compound, allocator: std.mem.Allocator, reader: *std.Io.Reader, depth: u16) ReadError!void {
        if (depth >= MAX_DEPTH) return error.MaxDepthExceeded;

        var items: std.ArrayList(NBT) = .empty;
        defer items.deinit(allocator);

        // Read named children until TAG_End terminator.
        while (true) {
            const child = try NBT.read_with_depth(allocator, reader, depth + 1);
            if (child.value == .end) break;
            try items.append(allocator, child);
        }

        self.value = try items.toOwnedSlice(allocator);
    }

    pub fn write(self: Compound, writer: *std.Io.Writer) WriteError!void {
        for (self.value) |item| {
            try item.write(writer);
        }
        try writer.writeInt(u8, @intFromEnum(Tag.end), .big);
    }
};

pub const NBT = struct {
    name: PrefixString,
    value: Value,

    pub const Value = union(Tag) {
        end: void,
        byte: Byte,
        short: Short,
        int: Int,
        long: Long,
        float: Float,
        double: Double,
        byte_array: ByteArray,
        string: String,
        list: List,
        compound: Compound,
    };

    pub fn read(allocator: std.mem.Allocator, reader: *std.Io.Reader) ReadError!NBT {
        return read_with_depth(allocator, reader, 0);
    }

    pub fn read_with_depth(allocator: std.mem.Allocator, reader: *std.Io.Reader, depth: u16) ReadError!NBT {
        if (depth >= MAX_DEPTH) return error.MaxDepthExceeded;

        const tag = try read_tag(reader);

        var nbt: NBT = undefined;
        if (tag == .end) {
            nbt.name = .{ .value = &.{} };
            nbt.value = .{ .end = {} };
            return nbt;
        }

        try nbt.name.read(allocator, reader);
        try read_payload(&nbt.value, allocator, reader, tag, depth);
        return nbt;
    }

    pub fn read_payload(value: *Value, allocator: std.mem.Allocator, reader: *std.Io.Reader, tag: Tag, depth: u16) ReadError!void {
        switch (tag) {
            .end => value.* = .{ .end = {} },
            .byte => {
                value.* = .{ .byte = undefined };
                try value.byte.read(reader);
            },
            .short => {
                value.* = .{ .short = undefined };
                try value.short.read(reader);
            },
            .int => {
                value.* = .{ .int = undefined };
                try value.int.read(reader);
            },
            .long => {
                value.* = .{ .long = undefined };
                try value.long.read(reader);
            },
            .float => {
                value.* = .{ .float = undefined };
                try value.float.read(reader);
            },
            .double => {
                value.* = .{ .double = undefined };
                try value.double.read(reader);
            },
            .byte_array => {
                value.* = .{ .byte_array = undefined };
                try value.byte_array.read(allocator, reader);
            },
            .string => {
                value.* = .{ .string = undefined };
                try value.string.read(allocator, reader);
            },
            .list => {
                value.* = .{ .list = undefined };
                try value.list.read(allocator, reader, depth + 1);
            },
            .compound => {
                value.* = .{ .compound = undefined };
                try value.compound.read(allocator, reader, depth + 1);
            },
        }
    }

    pub fn write(self: NBT, writer: *std.Io.Writer) WriteError!void {
        const tag = std.meta.activeTag(self.value);
        try writer.writeInt(u8, @intFromEnum(tag), .big);
        if (tag == .end) return;
        try self.name.write(writer);
        try write_payload(self.value, writer);
    }

    pub fn write_payload(value: Value, writer: *std.Io.Writer) WriteError!void {
        switch (value) {
            .end => {},
            .byte => |b| try b.write(writer),
            .short => |s| try s.write(writer),
            .int => |i| try i.write(writer),
            .long => |l| try l.write(writer),
            .float => |f| try f.write(writer),
            .double => |d| try d.write(writer),
            .byte_array => |ba| try ba.write(writer),
            .string => |s| try s.write(writer),
            .list => |l| try l.write(writer),
            .compound => |c| try c.write(writer),
        }
    }
};

const testing = std.testing;

fn roundtrip(alloc: std.mem.Allocator, original: NBT, buf: []u8) !NBT {
    var w = std.Io.Writer.fixed(buf);
    try original.write(&w);
    var r = std.Io.Reader.fixed(w.buffered());
    return NBT.read(alloc, &r);
}

fn named(alloc: std.mem.Allocator, name: []const u8, v: NBT.Value) !NBT {
    return .{ .name = .{ .value = try alloc.dupe(u8, name) }, .value = v };
}

test "round-trip byte" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const original = try named(alloc, "b", .{ .byte = .{ .value = -42 } });
    var buf: [64]u8 = undefined;
    const got = try roundtrip(alloc, original, &buf);

    try testing.expectEqualStrings("b", got.name.value);
    try testing.expectEqual(@as(i8, -42), got.value.byte.value);
}

test "round-trip numeric primitives" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var buf: [64]u8 = undefined;

    {
        const got = try roundtrip(alloc, try named(alloc, "s", .{ .short = .{ .value = -12345 } }), &buf);
        try testing.expectEqual(@as(i16, -12345), got.value.short.value);
    }
    {
        const got = try roundtrip(alloc, try named(alloc, "i", .{ .int = .{ .value = 0x7FEEDBEE } }), &buf);
        try testing.expectEqual(@as(i32, 0x7FEEDBEE), got.value.int.value);
    }
    {
        const got = try roundtrip(alloc, try named(alloc, "l", .{ .long = .{ .value = -0x1122334455667788 } }), &buf);
        try testing.expectEqual(@as(i64, -0x1122334455667788), got.value.long.value);
    }
    {
        const got = try roundtrip(alloc, try named(alloc, "f", .{ .float = .{ .value = 3.5 } }), &buf);
        try testing.expectEqual(@as(f32, 3.5), got.value.float.value);
    }
    {
        const got = try roundtrip(alloc, try named(alloc, "d", .{ .double = .{ .value = -1.0e100 } }), &buf);
        try testing.expectEqual(@as(f64, -1.0e100), got.value.double.value);
    }
}

test "round-trip string and byte_array" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var buf: [256]u8 = undefined;

    const s_val: String = .{ .value = try alloc.dupe(u8, "hello world") };
    const got_s = try roundtrip(alloc, try named(alloc, "msg", .{ .string = s_val }), &buf);
    try testing.expectEqualStrings("hello world", got_s.value.string.value);

    const ba_val: ByteArray = .{ .value = try alloc.dupe(u8, &[_]u8{ 0, 1, 2, 3, 250, 251, 252 }) };
    const got_ba = try roundtrip(alloc, try named(alloc, "arr", .{ .byte_array = ba_val }), &buf);
    try testing.expectEqualSlices(u8, &[_]u8{ 0, 1, 2, 3, 250, 251, 252 }, got_ba.value.byte_array.value);
}

test "round-trip empty compound" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var buf: [64]u8 = undefined;

    const original = try named(alloc, "empty", .{ .compound = .{ .value = &.{} } });
    const got = try roundtrip(alloc, original, &buf);
    try testing.expectEqualStrings("empty", got.name.value);
    try testing.expectEqual(@as(usize, 0), got.value.compound.value.len);
}

test "round-trip compound with children" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var buf: [256]u8 = undefined;

    var children = try alloc.alloc(NBT, 3);
    children[0] = try named(alloc, "a", .{ .byte = .{ .value = 1 } });
    children[1] = try named(alloc, "b", .{ .int = .{ .value = 99 } });
    children[2] = try named(alloc, "c", .{ .string = .{ .value = try alloc.dupe(u8, "hi") } });

    const original = try named(alloc, "root", .{ .compound = .{ .value = children } });
    const got = try roundtrip(alloc, original, &buf);

    try testing.expectEqual(@as(usize, 3), got.value.compound.value.len);
    try testing.expectEqualStrings("a", got.value.compound.value[0].name.value);
    try testing.expectEqual(@as(i8, 1), got.value.compound.value[0].value.byte.value);
    try testing.expectEqualStrings("b", got.value.compound.value[1].name.value);
    try testing.expectEqual(@as(i32, 99), got.value.compound.value[1].value.int.value);
    try testing.expectEqualStrings("c", got.value.compound.value[2].name.value);
    try testing.expectEqualStrings("hi", got.value.compound.value[2].value.string.value);
}

test "round-trip nested compound" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var buf: [256]u8 = undefined;

    var inner_children = try alloc.alloc(NBT, 1);
    inner_children[0] = try named(alloc, "n", .{ .int = .{ .value = 7 } });

    var outer_children = try alloc.alloc(NBT, 1);
    outer_children[0] = try named(alloc, "inner", .{ .compound = .{ .value = inner_children } });

    const original = try named(alloc, "outer", .{ .compound = .{ .value = outer_children } });
    const got = try roundtrip(alloc, original, &buf);

    const inner = got.value.compound.value[0];
    try testing.expectEqualStrings("inner", inner.name.value);
    try testing.expectEqual(@as(i32, 7), inner.value.compound.value[0].value.int.value);
}

test "round-trip empty list" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var buf: [64]u8 = undefined;

    const original = try named(alloc, "l", .{ .list = .{ .value = &.{} } });
    const got = try roundtrip(alloc, original, &buf);
    try testing.expectEqual(@as(usize, 0), got.value.list.value.len);
}

test "round-trip list of ints" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var buf: [256]u8 = undefined;

    const items = try alloc.alloc(NBT, 4);
    for (items, 0..) |*it, idx| {
        it.* = .{ .name = .{ .value = &.{} }, .value = .{ .int = .{ .value = @intCast(idx * 100) } } };
    }
    const original = try named(alloc, "ints", .{ .list = .{ .value = items } });
    const got = try roundtrip(alloc, original, &buf);

    try testing.expectEqual(@as(usize, 4), got.value.list.value.len);
    for (got.value.list.value, 0..) |it, idx| {
        try testing.expectEqual(@as(i32, @intCast(idx * 100)), it.value.int.value);
    }
}

test "round-trip list of compounds" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var buf: [512]u8 = undefined;

    const items = try alloc.alloc(NBT, 2);
    for (items, 0..) |*it, idx| {
        var children = try alloc.alloc(NBT, 1);
        children[0] = try named(alloc, "v", .{ .short = .{ .value = @intCast(idx + 1) } });
        it.* = .{ .name = .{ .value = &.{} }, .value = .{ .compound = .{ .value = children } } };
    }
    const original = try named(alloc, "xs", .{ .list = .{ .value = items } });
    const got = try roundtrip(alloc, original, &buf);

    try testing.expectEqual(@as(usize, 2), got.value.list.value.len);
    try testing.expectEqual(@as(i16, 1), got.value.list.value[0].value.compound.value[0].value.short.value);
    try testing.expectEqual(@as(i16, 2), got.value.list.value[1].value.compound.value[0].value.short.value);
}

test "MAX_DEPTH guards runaway nesting" {
    // Build a pathological byte stream of unterminated nested compounds
    // (tag 0x0A + empty name) and expect the depth check to trip.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const levels = MAX_DEPTH + 16;
    const bytes = try alloc.alloc(u8, levels * 3);
    var i: usize = 0;
    while (i < levels) : (i += 1) {
        bytes[i * 3 + 0] = @intFromEnum(Tag.compound);
        bytes[i * 3 + 1] = 0;
        bytes[i * 3 + 2] = 0;
    }

    var r = std.Io.Reader.fixed(bytes);
    try testing.expectError(error.MaxDepthExceeded, NBT.read(alloc, &r));
}
