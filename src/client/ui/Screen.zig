const ae = @import("aether");

const Rendering = ae.Rendering;
const SpriteBatcher = ae.Ui.SpriteBatcher;
const Scaling = ae.Ui.Scaling;
const layout = ae.Ui.layout;

const Colors = @import("../graphics/Color.zig");

pub fn logical_rect() layout.LogicalRect {
    const width = Rendering.gfx.surface.get_width();
    const height = Rendering.gfx.surface.get_height();
    const scale = Scaling.compute(width, height);
    return .{
        .x0 = 0,
        .y0 = 0,
        .x1 = @intCast((width + scale - 1) / scale),
        .y1 = @intCast((height + scale - 1) / scale),
    };
}

pub fn add_dirt_background(batcher: *SpriteBatcher, dirt: *const Rendering.Texture) void {
    const rect = logical_rect();
    const tile_size: i16 = 32;
    var y: i16 = 0;
    while (y < rect.y1) : (y += tile_size) {
        var x: i16 = 0;
        while (x < rect.x1) : (x += tile_size) {
            batcher.add_sprite(&.{
                .texture = dirt,
                .pos_offset = .{ .x = x, .y = y },
                .pos_extent = .{ .x = tile_size, .y = tile_size },
                .tex_offset = .{ .x = 0, .y = 0 },
                .tex_extent = .{ .x = @intCast(dirt.width), .y = @intCast(dirt.height) },
                .color = Colors.menu_tiles,
                .layer = 0,
            });
        }
    }
}
