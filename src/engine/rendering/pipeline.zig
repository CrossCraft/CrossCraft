const Platform = @import("../platform/platform.zig");
const gfx = Platform.gfx;

pub const Handle = u32;

// TODO: support more attribute formats
pub const AttributeFormat = enum(u8) {
    f32x2,
    f32x3,
    unorm8x4,

    fn infer(comptime T: type) AttributeFormat {
        return switch (T) {
            [2]f32 => .f32x2,
            [3]f32 => .f32x3,
            [4]u8 => .unorm8x4,
            else => @compileError("Unsupported attribute field type"),
        };
    }

    pub fn count(self: AttributeFormat) usize {
        return switch (self) {
            .f32x2 => 2,
            .f32x3 => 3,
            .unorm8x4 => 4,
        };
    }
};

pub const Attribute = struct {
    location: u8,
    binding: u8 = 0,
    offset: usize,
    size: usize,
    format: AttributeFormat,
};

pub const VertexLayout = struct {
    stride: usize,
    attributes: []const Attribute,
};

pub const AttributeSpec = struct {
    field: []const u8,
    location: u8,
    binding: u8 = 0,
};

pub fn attributes_from_struct(comptime V: type, comptime specs: []const AttributeSpec) [specs.len]Attribute {
    comptime var attrs: [specs.len]Attribute = undefined;

    inline for (specs, 0..) |s, i| {
        const format = AttributeFormat.infer(@FieldType(V, s.field));
        attrs[i] = .{
            .location = s.location,
            .binding = s.binding,
            .size = format.count(),
            .offset = @offsetOf(V, s.field),
            .format = format,
        };
    }

    return attrs;
}

pub fn layout_from_struct(comptime V: type, comptime attrs: []const Attribute) VertexLayout {
    return .{ .stride = @sizeOf(V), .attributes = attrs };
}

handle: Handle,

pub fn new(layout: VertexLayout, vs: ?[:0]align(4) const u8, fs: ?[:0]align(4) const u8) !Handle {
    return gfx.api.tab.create_pipeline(gfx.api.ptr, layout, vs, fs);
}

pub fn deinit(handle: Handle) void {
    gfx.api.tab.destroy_pipeline(gfx.api.ptr, handle);
}

pub fn bind(handle: Handle) void {
    gfx.api.tab.bind_pipeline(gfx.api.ptr, handle);
}
