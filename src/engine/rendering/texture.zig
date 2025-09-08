const std = @import("std");
const zstbi = @import("zstbi");
const Platform = @import("../platform/platform.zig");
const gfx = Platform.gfx;

pub const Handle = u32;
pub const Image = struct {
    width: u32,
    height: u32,
    data: []u8,
    handle: Handle,

    pub fn load(allocator: std.mem.Allocator, path: []const u8) !Image {
        var file = try std.fs.cwd().openFile(path, .{});
        defer file.close();

        const buffer = try file.readToEndAlloc(allocator, std.math.maxInt(u24));
        defer allocator.free(buffer);

        var img_width: c_int = 0;
        var img_height: c_int = 0;
        var channels: c_int = 0;

        var result_buffer = zstbi.stbi_load_from_memory(buffer.ptr, @intCast(buffer.len), &img_width, &img_height, &channels, 4) orelse return error.LoadFailed;
        const result = result_buffer[0..@as(usize, @intCast((img_height * img_width * 4)))];

        return Image{
            .width = @intCast(img_width),
            .height = @intCast(img_height),
            .data = result,
            .handle = try gfx.api.tab.create_texture(gfx.api.ptr, @intCast(img_width), @intCast(img_height), result),
        };
    }

    // This is a hack to avoid zstbi's weirdness.
    extern fn stbi_image_free(image_data: ?[*]u8) void;
    pub fn deinit(self: *Image, _: std.mem.Allocator) void {
        stbi_image_free(self.data.ptr);
    }

    pub fn bind(self: *const Image) void {
        gfx.api.tab.bind_texture(gfx.api.ptr, self.handle);
    }
};
