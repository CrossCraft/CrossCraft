const std = @import("std");
const zm = @import("zmath");
const Platform = @import("../platform/platform.zig");
const gfx = Platform.gfx.api;

pub const Handle = u32;

pub const AttributeFormat = enum(u8) {
    f32x3,
    unorm8x4,

    fn infer(comptime T: type) AttributeFormat {
        return switch (T) {
            [3]f32 => .f32x3,
            [4]u8 => .unorm8x4,
            else => @compileError("Unsupported attribute field type"),
        };
    }
};

pub const Attribute = struct {
    location: u8,
    binding: u8 = 0,
    offset: usize,
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

pub fn layout_from_struct(comptime V: type, comptime specs: []const AttributeSpec) VertexLayout {
    comptime var attrs: [specs.len]Attribute = undefined;

    inline for (specs, 0..) |s, i| {
        attrs[i] = .{
            .location = s.location,
            .binding = s.binding,
            .offset = @offsetOf(V, s.field),
            .format = AttributeFormat.infer(@FieldType(V, s.field)),
        };
    }

    return .{ .stride = @sizeOf(V), .attributes = &attrs };
}

pub fn Mesh(comptime V: type, comptime specs: []const AttributeSpec) type {
    return struct {
        const Self = @This();

        pub const Vertex = V;
        pub const Layout = layout_from_struct(V, specs);

        handle: Handle,
        vertices: std.ArrayList(Vertex),

        pub fn new(allocator: std.mem.Allocator) !Self {
            return .{
                .handle = try gfx.tab.create_mesh(gfx.ptr, Layout),
                .vertices = try std.ArrayList(V).initCapacity(allocator, 32),
            };
        }

        pub fn destroy(self: *Self, allocator: std.mem.Allocator) void {
            gfx.tab.destroy_mesh(gfx.ptr, self.handle);
            self.vertices.deinit(allocator);
            self.handle = 0;
        }

        pub fn update(self: *Self) void {
            gfx.tab.update_mesh(gfx.ptr, self.handle, 0, std.mem.asBytes(self.vertices.items));
        }

        pub fn update_range(self: *Self, offset: usize, len: usize) void {
            const offset_bytes = offset * @sizeOf(Vertex);
            const len_bytes = len * @sizeOf(Vertex);
            const vertex_bytes = std.mem.asBytes(self.vertices.items);

            gfx.tab.update_mesh(gfx.ptr, self.handle, offset_bytes, vertex_bytes[offset_bytes .. offset_bytes + len_bytes]);
        }

        pub fn draw(self: *Self, mat: *const zm.Mat) void {
            gfx.set_model_matrix(mat);
            gfx.tab.draw_mesh(gfx.ptr, self.handle);
        }
    };
}
