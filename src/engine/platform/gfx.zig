const GraphicsAPI = @import("platform.zig").GraphicsAPI;

const Surface = @import("surface.zig");
const GFXAPI = @import("gfx_api.zig");

const Util = @import("../util/util.zig");

const zstbi = @import("zstbi");

pub var surface: Surface = undefined;
pub var api: GFXAPI = undefined;
pub fn init(width: u32, height: u32, title: [:0]const u8, sync: bool, comptime graphics_api: GraphicsAPI) !void {
    zstbi.init(Util.allocator());

    surface = try Surface.make_surface();
    try surface.init(width, height, title, sync, @intFromEnum(graphics_api));

    api = try GFXAPI.make_api(graphics_api);
    try api.init();
}

pub fn deinit() void {
    api.deinit();
    surface.deinit();
    zstbi.deinit();
}
