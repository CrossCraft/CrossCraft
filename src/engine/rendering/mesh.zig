const std = @import("std");
const zm = @import("zmath");
const Platform = @import("../platform/platform.zig");
const gfx = Platform.gfx;

pub const Handle = u32;

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

/// A generic mesh type that holds vertex data and interfaces with the graphics API.
/// The mesh is defined by a vertex struct type `V` and an array of attribute specifications.
/// The vertex struct `V` should contain fields that correspond to the attributes defined in `specs`.
/// The attribute specifications define how the fields of the vertex struct map to shader attribute locations.
/// The mesh provides methods to create, update, and draw the mesh using the underlying graphics API.
/// The vertex data is stored in a dynamic array, allowing for flexible mesh sizes.
/// The mesh must be initialized with an allocator to manage its vertex data.
/// The mesh must be deinitialized to free its resources when no longer needed.
pub fn Mesh(comptime V: type, comptime specs: []const AttributeSpec) type {
    return struct {
        const Self = @This();

        pub const Vertex = V;
        pub const Attributes = attributes_from_struct(V, specs);
        pub const Layout = layout_from_struct(V, &Attributes);

        handle: Handle,
        vertices: std.ArrayList(Vertex),

        pub fn new(allocator: std.mem.Allocator) !Self {
            return .{
                .handle = try gfx.api.tab.create_mesh(gfx.api.ptr, Layout),
                .vertices = try std.ArrayList(V).initCapacity(allocator, 32),
            };
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            gfx.api.tab.destroy_mesh(gfx.api.ptr, self.handle);
            self.vertices.deinit(allocator);
            self.handle = 0;
        }

        pub fn update(self: *Self) void {
            gfx.api.tab.update_mesh(gfx.api.ptr, self.handle, 0, std.mem.sliceAsBytes(self.vertices.items));
        }

        pub fn update_range(self: *Self, offset: usize, len: usize) void {
            const offset_bytes = offset * @sizeOf(Vertex);
            const len_bytes = len * @sizeOf(Vertex);
            const vertex_bytes = std.mem.asBytes(self.vertices.items);

            gfx.api.tab.update_mesh(gfx.api.ptr, self.handle, offset_bytes, vertex_bytes[offset_bytes .. offset_bytes + len_bytes]);
        }

        pub fn draw(self: *Self, mat: *const zm.Mat) void {
            gfx.api.set_model_matrix(mat);
            gfx.api.tab.draw_mesh(gfx.api.ptr, self.handle, self.vertices.items.len);
        }
    };
}
