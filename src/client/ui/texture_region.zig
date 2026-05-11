//! Texel-space rects and the sizing modes that map them to logical-pixel
//! destinations.

const std = @import("std");

/// Texel-space rect inside a texture atlas. Kept distinct from logical-pixel
/// destination rects so the two domains can't silently interconvert.
pub const TextureRegion = struct {
    x: i16,
    y: i16,
    w: i16,
    h: i16,

    pub fn init(x: i16, y: i16, w: i16, h: i16) TextureRegion {
        return .{ .x = x, .y = y, .w = w, .h = h };
    }
};

/// Endpoints render at native scale; middle pixels of the source are dropped
/// so a wide region shrinks to any width in [min_w, max_w] without stretching.
pub const CenterElide = struct {
    min_w: i16 = 2,
    max_w: i16 = 200,
};

pub const NineSlice = struct {
    left: i16,
    right: i16,
    top: i16,
    bottom: i16,
};

pub const TextureSizing = union(enum) {
    stretch,
    center_elide: CenterElide,
    nine_slice: NineSlice,
};

pub const ElidedSpans = struct {
    left: TextureRegion,
    right: TextureRegion,
};

/// Source spans for a center-elided draw of `region` into width `dst_w`.
/// Asymmetric split (left = dst_w/2, right = dst_w - left) keeps odd
/// destinations exact.
pub fn elide_center(region: TextureRegion, dst_w: i16, params: CenterElide) ElidedSpans {
    std.debug.assert(region.w >= params.min_w);
    std.debug.assert(region.w <= params.max_w);
    std.debug.assert(dst_w >= params.min_w);
    std.debug.assert(dst_w <= params.max_w);
    std.debug.assert(dst_w <= region.w);

    const left_w: i16 = @divTrunc(dst_w, 2);
    const right_w: i16 = dst_w - left_w;

    std.debug.assert(left_w >= 1);
    std.debug.assert(right_w >= 1);
    std.debug.assert(left_w + right_w == dst_w);

    return .{
        .left = .{ .x = region.x, .y = region.y, .w = left_w, .h = region.h },
        .right = .{
            .x = region.x + region.w - right_w,
            .y = region.y,
            .w = right_w,
            .h = region.h,
        },
    };
}
