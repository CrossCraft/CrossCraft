// --- World geometry ---
const std = @import("std");
const assert = std.debug.assert;

/// Chunks per axis is always 16 voxels. See the module comment.
pub const chunk_size: u32 = 16;
pub const chunk_volume: u32 = chunk_size * chunk_size * chunk_size; // 4096
pub const log2_chunk_size: u5 = 4;
pub const chunk_mask: u32 = chunk_size - 1;

/// Bounds on the live world. The Menu offers X/Z in {128, 256, 512} crossed
/// with Y in {64, 128}; everything outside that range is a bug or hostile
/// input, not a size to try. `max_height` is 128 because `WorldData.light_map`
/// stores Y+1 in a u8.
pub const min_length: u32 = 128;
pub const min_height: u32 = 64;
pub const min_depth: u32 = 128;
pub const max_length: u32 = 512;
pub const max_height: u32 = 128;
pub const max_depth: u32 = 512;

/// Power-of-two axis -> the shift that divides by it. `std.math.log2_int` is
/// unusable here because it demands a comptime argument and these axes are
/// runtime values; `@ctz` is a single instruction on the targets we ship.
fn shift_of(v: u32) u5 {
    assert(v != 0 and @popCount(v) == 1);
    return @intCast(@ctz(v));
}

pub const WorldDims = struct {
    length: u32,
    height: u32,
    depth: u32,

    /// Chunks per axis; each is an axis divided by `chunk_size`.
    chunks_x: u32,
    chunks_y: u32,
    chunks_z: u32,

    /// `light_map` is column-major in X, so its index is a shift-and-or.
    log2_length: u5,
    /// Chunk-linear index = (cy << shift_cy) | (cz << shift_cz) | cx.
    shift_cz: u5,
    shift_cy: u5,
    /// Rows per Y-slab in the wire layout = depth * chunks_x.
    shift_slab: u5,

    pub fn init(length: u32, height: u32, depth: u32) WorldDims {
        assert(min_length <= length and length <= max_length);
        assert(min_height <= height and height <= max_height);
        assert(min_depth <= depth and depth <= max_depth);
        assert(@popCount(length) == 1 and @popCount(height) == 1 and @popCount(depth) == 1);

        const chunks_x = length >> log2_chunk_size;
        const chunks_z = depth >> log2_chunk_size;
        const shift_cz = shift_of(chunks_x);
        return .{
            .length = length,
            .height = height,
            .depth = depth,
            .chunks_x = chunks_x,
            .chunks_y = height >> log2_chunk_size,
            .chunks_z = chunks_z,
            .log2_length = shift_of(length),
            .shift_cz = shift_cz,
            .shift_cy = shift_cz + shift_of(chunks_z),
            .shift_slab = shift_of(depth) + shift_cz,
        };
    }

    pub fn volume(self: WorldDims) usize {
        return @as(usize, self.length) * self.height * self.depth;
    }

    pub fn chunk_count(self: WorldDims) usize {
        return @as(usize, self.chunks_x) * self.chunks_y * self.chunks_z;
    }

    pub fn band_len(self: WorldDims) usize {
        return @as(usize, self.length) * chunk_size;
    }

    pub fn block_index(self: WorldDims, x: u32, y: u32, z: u32) u32 {
        const local = ((y & chunk_mask) << (2 * log2_chunk_size)) |
            ((z & chunk_mask) << log2_chunk_size) | (x & chunk_mask);
        return (self.chunk_index(x, y, z) << (3 * log2_chunk_size)) | local;
    }

    pub fn chunk_index(self: WorldDims, x: u32, y: u32, z: u32) u32 {
        return self.chunk_at(x >> log2_chunk_size, y >> log2_chunk_size, z >> log2_chunk_size);
    }

    pub fn chunk_at(self: WorldDims, cx: u32, cy: u32, cz: u32) u32 {
        return (cy << self.shift_cy) | (cz << self.shift_cz) | cx;
    }

    pub fn to_array(self: WorldDims) [3]u16 {
        return .{ @intCast(self.length), @intCast(self.height), @intCast(self.depth) };
    }

    pub fn valid(dims: [3]u16) bool {
        const length: u32 = dims[0];
        const height: u32 = dims[1];
        const depth: u32 = dims[2];
        return min_length <= length and length <= max_length and
            min_height <= height and height <= max_height and
            min_depth <= depth and depth <= max_depth and
            std.math.isPowerOfTwo(length) and
            std.math.isPowerOfTwo(height) and
            std.math.isPowerOfTwo(depth);
    }

    pub fn from_array(dims: [3]u16) ?WorldDims {
        if (!valid(dims)) return null;
        return init(dims[0], dims[1], dims[2]);
    }

    pub fn matches(self: WorldDims, dims: [3]u16) bool {
        return self.length == dims[0] and self.height == dims[1] and self.depth == dims[2];
    }
};

pub const default: WorldDims = WorldDims.init(256, 64, 256);

/// Named X/Z footprint presets. The discriminant doubles as an offset from
/// log2 128, so preset geometry is pure shift math: `edge()` is one `shl`.
pub const WorldSize = enum(u8) {
    tiny,
    normal,
    huge,

    /// log2 of the edge length: tiny = 7 (128), normal = 8 (256), huge = 9 (512).
    pub fn log2_edge(self: WorldSize) u5 {
        return 7 + @as(u5, @intCast(@intFromEnum(self)));
    }

    /// Edge length in blocks: 128, 256, or 512 (applied to both X and Z).
    pub fn edge(self: WorldSize) u32 {
        return @as(u32, 1) << self.log2_edge();
    }

    pub fn label(self: WorldSize) []const u8 {
        return switch (self) {
            .tiny => "Tiny",
            .normal => "Normal",
            .huge => "Huge",
        };
    }

    /// Parse a `world-size` value from server.properties.
    pub fn parse(text: []const u8) ?WorldSize {
        inline for (@typeInfo(WorldSize).@"enum".fields) |field| {
            if (std.mem.eql(u8, text, field.name)) return @enumFromInt(field.value);
        }
        return null;
    }
};

/// Named height presets. Normal matches Classic's 64-block worlds; tall doubles it.
pub const WorldHeight = enum(u8) {
    normal,
    tall,

    /// log2 of the height: normal = 6 (64), tall = 7 (128).
    pub fn log2_height(self: WorldHeight) u5 {
        return 6 + @as(u5, @intCast(@intFromEnum(self)));
    }

    /// Height in blocks: 64 or 128.
    pub fn height(self: WorldHeight) u32 {
        return @as(u32, 1) << self.log2_height();
    }

    pub fn label(self: WorldHeight) []const u8 {
        return switch (self) {
            .normal => "Normal",
            .tall => "Tall",
        };
    }

    /// Parse a `world-height` value from server.properties.
    pub fn parse(text: []const u8) ?WorldHeight {
        inline for (@typeInfo(WorldHeight).@"enum".fields) |field| {
            if (std.mem.eql(u8, text, field.name)) return @enumFromInt(field.value);
        }
        return null;
    }
};

/// Geometry for a size x height pair: a square footprint crossed with the
/// preset height. The image is exactly the supported world lattice -- the
/// same six geometries `WorldDims.valid` accepts.
pub fn from_presets(size: WorldSize, height: WorldHeight) WorldDims {
    return WorldDims.init(size.edge(), height.height(), size.edge());
}

test "presets cover the supported lattice" {
    const cases = [_]struct { size: WorldSize, height: WorldHeight, dims: [3]u16 }{
        .{ .size = .tiny, .height = .normal, .dims = .{ 128, 64, 128 } },
        .{ .size = .tiny, .height = .tall, .dims = .{ 128, 128, 128 } },
        .{ .size = .normal, .height = .normal, .dims = .{ 256, 64, 256 } },
        .{ .size = .normal, .height = .tall, .dims = .{ 256, 128, 256 } },
        .{ .size = .huge, .height = .normal, .dims = .{ 512, 64, 512 } },
        .{ .size = .huge, .height = .tall, .dims = .{ 512, 128, 512 } },
    };
    for (cases) |case| {
        const dims = from_presets(case.size, case.height);
        try std.testing.expectEqualStrings(case.size.label(), switch (dims.length) {
            128 => "Tiny",
            256 => "Normal",
            512 => "Huge",
            else => unreachable,
        });
        try std.testing.expectEqual(WorldDims.from_array(case.dims).?, dims);
    }
    try std.testing.expectEqual(default, from_presets(.normal, .normal));
    try std.testing.expectEqual(@as(u32, 128), WorldSize.tiny.edge());
    try std.testing.expectEqual(@as(u5, 9), WorldSize.huge.log2_edge());
    try std.testing.expectEqual(@as(u32, 128), WorldHeight.tall.height());
}

test "preset parse is exact" {
    try std.testing.expectEqual(WorldSize.tiny, WorldSize.parse("tiny").?);
    try std.testing.expectEqual(WorldSize.normal, WorldSize.parse("normal").?);
    try std.testing.expectEqual(WorldSize.huge, WorldSize.parse("huge").?);
    try std.testing.expectEqual(WorldHeight.normal, WorldHeight.parse("normal").?);
    try std.testing.expectEqual(WorldHeight.tall, WorldHeight.parse("tall").?);

    try std.testing.expect(WorldSize.parse("256x64x256") == null);
    try std.testing.expect(WorldSize.parse("Tiny") == null);
    try std.testing.expect(WorldSize.parse("") == null);
    try std.testing.expect(WorldHeight.parse("huge") == null);
    try std.testing.expect(WorldHeight.parse("banana") == null);
}

test "block_index" {
    const dims = default;
    try std.testing.expectEqual(@as(u32, 0), dims.block_index(0, 0, 0));
    try std.testing.expectEqual(@as(u32, 4095), dims.block_index(15, 15, 15));
    try std.testing.expectEqual(@as(u32, 4096), dims.block_index(16, 0, 0));
    try std.testing.expectEqual(@as(u32, 4194303), dims.block_index(255, 63, 255));

    const base = dims.block_index(0, 5, 7);
    try std.testing.expectEqual(base + 1, dims.block_index(1, 5, 7));
    try std.testing.expectEqual(base + 15, dims.block_index(15, 5, 7));
}

/// Independent divide/multiply form of `block_index`, sharing no code with it.
fn reference_index(dims: WorldDims, x: u32, y: u32, z: u32) u32 {
    const chunk = (y / chunk_size * dims.chunks_z + z / chunk_size) * dims.chunks_x + x / chunk_size;
    const local = (y % chunk_size) * chunk_size * chunk_size + (z % chunk_size) * chunk_size + (x % chunk_size);
    return chunk * chunk_volume + local;
}

test "block_index matches an independent reference on every preset" {
    const presets = [6][3]u16{
        .{ 128, 64, 128 },
        .{ 128, 128, 128 },
        .{ 256, 64, 256 },
        .{ 256, 128, 256 },
        .{ 512, 64, 512 },
        .{ 512, 128, 512 },
    };
    for (presets) |preset| {
        const dims = WorldDims.from_array(preset) orelse return error.TestUnexpectedResult;
        var x: u32 = 0;
        while (x < dims.length) : (x += 5) {
            var y: u32 = 0;
            while (y < dims.height) : (y += 3) {
                var z: u32 = 0;
                while (z < dims.depth) : (z += 7) {
                    try std.testing.expectEqual(reference_index(dims, x, y, z), dims.block_index(x, y, z));
                    try std.testing.expectEqual(dims.block_index(x, y, z) >> (3 * log2_chunk_size), dims.chunk_index(x, y, z));
                }
            }
        }
        // The far corner must be the last voxel, so the field widths are
        // sufficient and no two voxels can collide.
        const last = dims.block_index(dims.length - 1, dims.height - 1, dims.depth - 1);
        try std.testing.expectEqual(dims.volume() - 1, last);
    }
}

test "block_index is a bijection over a whole world" {
    const dims = WorldDims.from_array(.{ 128, 64, 128 }) orelse return error.TestUnexpectedResult;
    var seen = try std.testing.allocator.alloc(bool, dims.volume());
    defer std.testing.allocator.free(seen);
    @memset(seen, false);

    for (0..dims.length) |x| for (0..dims.height) |y| for (0..dims.depth) |z| {
        const i = dims.block_index(@intCast(x), @intCast(y), @intCast(z));
        try std.testing.expect(i < dims.volume());
        if (seen[i]) return error.TestUnexpectedResult;
        seen[i] = true;
    };
    for (seen) |hit| try std.testing.expect(hit);
}

test "a taller world relocates chunks by its own chunk grid" {
    const dims = WorldDims.from_array(.{ 512, 128, 512 }) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 32 * 8 * 32), dims.chunk_count());
    try std.testing.expectEqual(@as(u32, 32 * 32 * chunk_volume), dims.block_index(0, 16, 0));
}

test "valid rejects anything the encodings cannot carry" {
    try std.testing.expect(WorldDims.valid(default.to_array()));
    try std.testing.expect(WorldDims.valid(.{ 512, 128, 512 }));
    try std.testing.expect(WorldDims.valid(.{ 128, 64, 128 }));

    try std.testing.expect(!WorldDims.valid(.{ 64, 64, 128 })); // below min_length
    try std.testing.expect(!WorldDims.valid(.{ 1024, 64, 128 })); // above max_length
    try std.testing.expect(!WorldDims.valid(.{ 256, 256, 256 })); // above max_height
    try std.testing.expect(!WorldDims.valid(.{ 256, 64, 1024 })); // above max_depth
    try std.testing.expect(!WorldDims.valid(.{ 192, 64, 128 })); // not a power of two

    try std.testing.expect(WorldDims.from_array(.{ 320, 64, 256 }) == null);
}

test "derived geometry" {
    const dims = WorldDims.from_array(.{ 256, 128, 512 }) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u32, 16), dims.chunks_x);
    try std.testing.expectEqual(@as(u32, 8), dims.chunks_y);
    try std.testing.expectEqual(@as(u32, 32), dims.chunks_z);
    try std.testing.expectEqual(@as(u32, 4), dims.shift_cz);
    try std.testing.expectEqual(@as(u32, 9), dims.shift_cy);
    try std.testing.expectEqual(@as(usize, 256 * 128 * 512), dims.volume());
    try std.testing.expectEqual(@as(usize, 16 * 8 * 32), dims.chunk_count());
    try std.testing.expectEqual(@as(usize, 256 * chunk_size), dims.band_len());
    try std.testing.expect(dims.matches(.{ 256, 128, 512 }));
    try std.testing.expect(!dims.matches(.{ 256, 64, 512 }));
}
