const std = @import("std");

pub const TextureAtlas = @import("aether").Ui.TextureAtlas;

test "atlas tiles stay inside sampling boundaries" {
    const atlas = TextureAtlas.init_grid(16, 16);
    const stride: i16 = 2048;

    try std.testing.expectEqual(@as(i16, 1), atlas.tile_u(0));
    try std.testing.expectEqual(@as(i16, 1), atlas.tile_v(0));
    try std.testing.expectEqual(stride + 1, atlas.tile_u(1));
    try std.testing.expectEqual(stride - 3, atlas.tile_width());
    try std.testing.expectEqual(stride - 3, atlas.tile_height());
    try std.testing.expectEqual(@as(i16, 32766), atlas.tile_u(15) + atlas.tile_width());
}
