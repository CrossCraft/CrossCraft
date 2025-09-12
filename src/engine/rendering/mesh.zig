const std = @import("std");
const zm = @import("zmath");
const Pipeline = @import("pipeline.zig");
const Platform = @import("../platform/platform.zig");
const gfx = Platform.gfx;
pub const Handle = u32;

/// A generic mesh type that holds vertex data and interfaces with the graphics API.
/// The mesh is defined by a vertex struct type `V` and an array of attribute specifications.
/// The vertex struct `V` should contain fields that correspond to the attributes defined in `specs`.
/// The attribute specifications define how the fields of the vertex struct map to shader attribute locations.
/// The mesh provides methods to create, update, and draw the mesh using the underlying graphics API.
/// The vertex data is stored in a dynamic array, allowing for flexible mesh sizes.
/// The mesh must be initialized with an allocator to manage its vertex data.
/// The mesh must be deinitialized to free its resources when no longer needed.
pub fn Mesh(comptime V: type) type {
    return struct {
        const Self = @This();

        pub const Vertex = V;

        handle: Handle,
        vertices: std.ArrayList(Vertex),

        pub fn new(allocator: std.mem.Allocator, pipeline: Pipeline.Handle) !Self {
            return .{
                .handle = try gfx.api.tab.create_mesh(gfx.api.ptr, pipeline),
                .vertices = try std.ArrayList(V).initCapacity(allocator, 32),
            };
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            gfx.api.tab.destroy_mesh(gfx.api.ptr, self.handle);
            self.vertices.deinit(allocator);
            self.handle = 0;
        }

        pub fn update(self: *Self) void {
            gfx.api.tab.update_mesh(gfx.api.ptr, self.handle, std.mem.sliceAsBytes(self.vertices.items));
        }

        pub fn draw(self: *Self, mat: *const zm.Mat) void {
            gfx.api.tab.draw_mesh(gfx.api.ptr, self.handle, mat, self.vertices.items.len);
        }
    };
}
