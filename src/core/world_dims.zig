const std = @import("std");
const assert = std.debug.assert;

pub const chunk_size: u32 = 16;
pub const chunk_volume: u32 = chunk_size * chunk_size * chunk_size;
pub const log2_chunk_size: u5 = 4;
pub const chunk_mask: u32 = chunk_size - 1;

/// Supported menu/save dimensions. Height stays below 255 because the light
/// map stores Y+1 in a byte.
pub const min_length: u32 = 128;
pub const min_height: u32 = 64;
pub const min_depth: u32 = 128;
pub const max_length: u32 = 512;
pub const max_height: u32 = 128;
pub const max_depth: u32 = 512;

fn shift_of(v: u32) u5 {
    assert(v != 0 and @popCount(v) == 1);
    return @intCast(@ctz(v));
}

pub const WorldDims = struct {
    length: u32,
    height: u32,
    depth: u32,

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
        // Out-of-range components alias other chunks in the packed index.
        assert(cx < self.chunks_x);
        assert(cy < self.chunks_y);
        assert(cz < self.chunks_z);
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

pub const WorldSize = enum(u8) {
    tiny,
    normal,
    huge,

    pub fn edge(self: WorldSize) u32 {
        return @as(u32, 128) << @intCast(@intFromEnum(self));
    }

    pub fn label(self: WorldSize) []const u8 {
        return switch (self) {
            .tiny => "Tiny",
            .normal => "Normal",
            .huge => "Huge",
        };
    }

    pub fn parse(text: []const u8) ?WorldSize {
        return std.meta.stringToEnum(WorldSize, text);
    }
};

pub const WorldHeight = enum(u8) {
    normal,
    tall,

    pub fn height(self: WorldHeight) u32 {
        return @as(u32, 64) << @intCast(@intFromEnum(self));
    }

    pub fn label(self: WorldHeight) []const u8 {
        return switch (self) {
            .normal => "Normal",
            .tall => "Tall",
        };
    }

    pub fn parse(text: []const u8) ?WorldHeight {
        return std.meta.stringToEnum(WorldHeight, text);
    }
};

pub fn from_presets(size: WorldSize, height: WorldHeight) WorldDims {
    return WorldDims.init(size.edge(), height.height(), size.edge());
}
