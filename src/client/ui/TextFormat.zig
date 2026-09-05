//! Classic protocol color codes and the game's font configuration.
const std = @import("std");
const ae = @import("aether");
const FontBatcher = ae.Ui.FontBatcher;
const Color = ae.Ui.Color;

pub fn control_length(text: []const u8) usize {
    if (text.len < 2 or text[0] != '&') return 0;
    const code = text[1];
    return if ((code >= '0' and code <= '9') or (code >= 'a' and code <= 'f')) 2 else 0;
}

pub fn parse(text: []const u8) ?FontBatcher.StyleControl {
    if (control_length(text) == 0) return null;
    const colors = switch (text[1]) {
        '0' => .{ Color.rgba(0, 0, 0, 255), Color.rgba(0, 0, 0, 255) },
        '1' => .{ Color.rgba(0, 0, 170, 255), Color.rgba(0, 0, 42, 255) },
        '2' => .{ Color.rgba(0, 170, 0, 255), Color.rgba(0, 42, 0, 255) },
        '3' => .{ Color.rgba(0, 170, 170, 255), Color.rgba(0, 42, 42, 255) },
        '4' => .{ Color.rgba(170, 0, 0, 255), Color.rgba(42, 0, 0, 255) },
        '5' => .{ Color.rgba(170, 0, 170, 255), Color.rgba(42, 0, 42, 255) },
        '6' => .{ Color.rgba(170, 170, 0, 255), Color.rgba(42, 42, 0, 255) },
        '7' => .{ Color.rgba(170, 170, 170, 255), Color.rgba(42, 42, 42, 255) },
        '8' => .{ Color.rgba(85, 85, 85, 255), Color.rgba(21, 21, 21, 255) },
        '9' => .{ Color.rgba(85, 85, 255, 255), Color.rgba(21, 21, 63, 255) },
        'a' => .{ Color.rgba(85, 255, 85, 255), Color.rgba(21, 63, 21, 255) },
        'b' => .{ Color.rgba(85, 255, 255, 255), Color.rgba(21, 63, 63, 255) },
        'c' => .{ Color.rgba(255, 85, 85, 255), Color.rgba(63, 21, 21, 255) },
        'd' => .{ Color.rgba(255, 85, 255, 255), Color.rgba(63, 21, 63, 255) },
        'e' => .{ Color.rgba(255, 255, 85, 255), Color.rgba(63, 63, 21, 255) },
        'f' => .{ Color.rgba(255, 255, 255, 255), Color.rgba(63, 63, 63, 255) },
        else => unreachable,
    };
    return .{ .length = 2, .color = colors[0], .shadow_color = colors[1] };
}

pub fn init_font(allocator: std.mem.Allocator, texture: *const ae.Rendering.Texture) !FontBatcher {
    var font = try FontBatcher.init(allocator, texture);
    font.style_parser = parse;
    return font;
}

test "Classic text formatting recognizes only lowercase protocol color codes" {
    for ([_][]const u8{ "", "&", "&g", "&A", "plain", "&&" }) |text| {
        try std.testing.expectEqual(0, control_length(text));
        try std.testing.expect(parse(text) == null);
    }
    for ("0123456789abcdef") |code| {
        const input = [_]u8{ '&', code, 'X' };
        const style = parse(&input).?;
        try std.testing.expectEqual(2, style.length);
        try std.testing.expectEqual(255, style.color.?.a);
        try std.testing.expectEqual(255, style.shadow_color.?.a);
    }
    try std.testing.expectEqual(Color.rgba(170, 170, 0, 255), parse("&6").?.color.?);
    try std.testing.expectEqual(Color.rgba(63, 21, 21, 255), parse("&c").?.shadow_color.?);
}

test "Classic text formatting preserves width fitting and screen geometry colors" {
    var font: FontBatcher = undefined;
    font.glyph_widths = @splat(8);
    font.atlas = ae.Ui.TextureAtlas.init_grid(16, 16);
    font.style_parser = parse;
    try std.testing.expectEqual(17, font.string_width("&cA&bB&f", 0, 1));
    try std.testing.expectEqual(5, font.fit_width("&cA&bB", 8, 0, 1));
    try std.testing.expectEqual(5, font.fit_width("&cA&b", 8, 0, 1));
    try std.testing.expectEqual(17, font.string_width("&cA&", 0, 1));
    try std.testing.expectEqual(26, font.string_width("&AA", 0, 1));

    var data = try FontBatcher.BatchMeshData.init(std.testing.allocator);
    defer data.deinit(std.testing.allocator);

    try data.ensure_quad_capacity(std.testing.allocator, 4);
    font.append_geometry(&data, &.{
        .str = "&cA&bB&f",
        .color = Color.white,
        .shadow_color = Color.black,
        .pos_x = 10,
        .pos_y = 10,
        .spacing = 0,
        .layer = 0,
        .reference = .top_left,
        .origin = .top_left,
    }, 100, 100, 1);
    const quad_vertices: usize = if (ae.Rendering.mesh.indexing_enabled) 4 else 6;
    try std.testing.expectEqual(4 * quad_vertices, data.vertices.items.len);
    const expected = [_]Color{
        Color.rgba(63, 21, 21, 255),
        Color.rgba(21, 63, 63, 255),
        Color.rgba(255, 85, 85, 255),
        Color.rgba(85, 255, 255, 255),
    };
    for (expected, 0..) |color, quad| {
        for (data.vertices.items[quad * quad_vertices ..][0..quad_vertices]) |vertex| {
            try std.testing.expectEqual(@as(u32, @bitCast(color)), vertex.color);
        }
    }
}

test "Classic text formatting is installed on game fonts and exported meshes" {
    if (!@import("capabilities").ClientType(ae).render.headless) return error.SkipZigTest;
    const pixels: [128 * 128 * 4]u8 = @splat(255);
    var texture = try ae.Rendering.Texture.load_from_data(std.testing.allocator, 128, 128, &pixels, &.{ .cpu_access = .read });
    defer texture.deinit(std.testing.allocator);

    var font = try init_font(std.testing.allocator, &texture);
    defer font.deinit();

    try std.testing.expectEqual(8, font.string_width("&cA", 0, 1));
    var mesh = try font.build_mesh("&cA&b", Color.white, Color.black, 0, 1);
    defer mesh.deinit(std.testing.allocator);

    const quad_vertices: usize = if (ae.Rendering.mesh.indexing_enabled) 4 else 6;
    try std.testing.expectEqual(2 * quad_vertices, mesh.data.vertices.items.len);
    for (mesh.data.vertices.items[0..quad_vertices]) |vertex| {
        try std.testing.expectEqual(@as(u32, @bitCast(Color.rgba(63, 21, 21, 255))), vertex.color);
    }
    for (mesh.data.vertices.items[quad_vertices..]) |vertex| {
        try std.testing.expectEqual(@as(u32, @bitCast(Color.rgba(255, 85, 85, 255))), vertex.color);
    }
}
