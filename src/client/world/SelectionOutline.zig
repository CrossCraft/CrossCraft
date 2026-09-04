const std = @import("std");
const ae = @import("aether");
const Rendering = ae.Rendering;
const Transform = Rendering.Transform;
const SubvoxelBounds = @import("core").blocks.SubvoxelBounds;

const Vertex = @import("aether").Rendering.Vertex;

// Twelve overlapping prisms form a backend-independent block outline.
// Geometry uses the chunk mesh SNORM16 scale (one block = 2048 units).
// Per-axis thickness compensation keeps partial blocks visually consistent.
const LO: i16 = 0;
const HI: i16 = 2048;

// Dividing by each AABB axis size cancels the model matrix's later scaling.
// Protrusion controls silhouette inflation independently of line thickness.
const THICK_NUMERATOR: i32 = 384;
const PROTRUSION_NUMERATOR: i32 = if (ae.platform == .psp) 240 else 80;

const COLOR: u32 = 0xAA202020;
const QUAD_COUNT: usize = 72;
const VERTEX_COUNT: usize = QUAD_COUNT * 6;

const Self = @This();

const Axis = enum(u2) { x, y, z };
const PerAxis = struct { x: i16, y: i16, z: i16 };
const Thickness = struct { thick: PerAxis, protrusion: PerAxis };

mesh_data: Rendering.MeshDataType(Vertex),
mesh: Rendering.MeshType(Vertex),
allocator: std.mem.Allocator,
last_bounds: ?SubvoxelBounds = null,

pub fn init(allocator: std.mem.Allocator) !Self {
    var self: Self = .{
        .mesh_data = try Rendering.MeshDataType(Vertex).init(allocator),
        .mesh = try Rendering.MeshType(Vertex).init(&.{}),
        .allocator = allocator,
    };
    try self.mesh_data.ensure_quad_capacity(allocator, QUAD_COUNT);
    return self;
}

pub fn deinit(self: *Self) void {
    self.mesh.deinit();
    self.mesh_data.deinit(self.allocator);
}

pub fn update(self: *Self, bounds: SubvoxelBounds) !void {
    if (self.last_bounds) |prev| {
        if (std.meta.eql(prev, bounds)) return;
    }
    self.last_bounds = bounds;
    self.mesh_data.clear_retaining_capacity();
    build_edges(&self.mesh_data, compute_thick(bounds));
    const expected_verts: usize = if (Rendering.mesh.indexing_enabled) QUAD_COUNT * 4 else VERTEX_COUNT;
    std.debug.assert(self.mesh_data.vertices.items.len == expected_verts);
    self.mesh.update(&self.mesh_data);
}

pub fn draw(self: *Self, transform: *const Transform) void {
    const m = transform.get_matrix();
    self.mesh.draw(&m);
}

fn axis_size(bounds: SubvoxelBounds, axis: Axis) i32 {
    return switch (axis) {
        .x => @as(i32, bounds.max_x) - @as(i32, bounds.min_x),
        .y => @as(i32, bounds.max_y) - @as(i32, bounds.min_y),
        .z => @as(i32, bounds.max_z) - @as(i32, bounds.min_z),
    };
}

fn compute_thick(bounds: SubvoxelBounds) Thickness {
    const sx = @max(axis_size(bounds, .x), 1);
    const sy = @max(axis_size(bounds, .y), 1);
    const sz = @max(axis_size(bounds, .z), 1);
    return .{
        .thick = .{
            .x = @intCast(@divTrunc(THICK_NUMERATOR, sx)),
            .y = @intCast(@divTrunc(THICK_NUMERATOR, sy)),
            .z = @intCast(@divTrunc(THICK_NUMERATOR, sz)),
        },
        .protrusion = .{
            .x = @intCast(@divTrunc(PROTRUSION_NUMERATOR, sx)),
            .y = @intCast(@divTrunc(PROTRUSION_NUMERATOR, sy)),
            .z = @intCast(@divTrunc(PROTRUSION_NUMERATOR, sz)),
        },
    };
}

const EdgeSpec = struct { axis: Axis, u_hi: bool, v_hi: bool };

const EDGES = [_]EdgeSpec{
    .{ .axis = .x, .u_hi = false, .v_hi = false },
    .{ .axis = .x, .u_hi = false, .v_hi = true },
    .{ .axis = .x, .u_hi = true, .v_hi = false },
    .{ .axis = .x, .u_hi = true, .v_hi = true },
    .{ .axis = .y, .u_hi = false, .v_hi = false },
    .{ .axis = .y, .u_hi = false, .v_hi = true },
    .{ .axis = .y, .u_hi = true, .v_hi = false },
    .{ .axis = .y, .u_hi = true, .v_hi = true },
    .{ .axis = .z, .u_hi = false, .v_hi = false },
    .{ .axis = .z, .u_hi = false, .v_hi = true },
    .{ .axis = .z, .u_hi = true, .v_hi = false },
    .{ .axis = .z, .u_hi = true, .v_hi = true },
};

fn perp_axes(axis: Axis) struct { Axis, Axis } {
    return switch (axis) {
        .x => .{ .y, .z },
        .y => .{ .x, .z },
        .z => .{ .x, .y },
    };
}

fn axis_thick(t: PerAxis, axis: Axis) i16 {
    return switch (axis) {
        .x => t.x,
        .y => t.y,
        .z => t.z,
    };
}

fn outward_range(at_hi: bool, total: i16, protrusion: i16) struct { i16, i16 } {
    const inside = total - protrusion;
    return if (at_hi)
        .{ HI - inside, HI + protrusion }
    else
        .{ LO - protrusion, LO + inside };
}

fn build_edges(mesh: *Rendering.MeshDataType(Vertex), t: Thickness) void {
    for (EDGES) |e| {
        const u_axis, const v_axis = perp_axes(e.axis);
        const u_lo, const u_hi = outward_range(e.u_hi, axis_thick(t.thick, u_axis), axis_thick(t.protrusion, u_axis));
        const v_lo, const v_hi = outward_range(e.v_hi, axis_thick(t.thick, v_axis), axis_thick(t.protrusion, v_axis));
        const t_edge_prot = axis_thick(t.protrusion, e.axis);
        const edge_lo: i16 = LO - t_edge_prot;
        const edge_hi: i16 = HI + t_edge_prot;

        var c0: [3]i16 = undefined;
        var c1: [3]i16 = undefined;
        switch (e.axis) {
            .x => {
                c0 = .{ edge_lo, u_lo, v_lo };
                c1 = .{ edge_hi, u_hi, v_hi };
            },
            .y => {
                c0 = .{ u_lo, edge_lo, v_lo };
                c1 = .{ u_hi, edge_hi, v_hi };
            },
            .z => {
                c0 = .{ u_lo, v_lo, edge_lo };
                c1 = .{ u_hi, v_hi, edge_hi };
            },
        }
        emit_box(mesh, c0, c1);
    }
}

fn emit_box(mesh: *Rendering.MeshDataType(Vertex), c0: [3]i16, c1: [3]i16) void {
    const x0 = c0[0];
    const x1 = c1[0];
    const y0 = c0[1];
    const y1 = c1[1];
    const z0 = c0[2];
    const z1 = c1[2];

    append_quad(mesh, .{
        // x_pos
        v(x1, y0, z0), v(x1, y0, z1), v(x1, y1, z1), v(x1, y1, z0),
    });
    append_quad(mesh, .{
        // x_neg
        v(x0, y0, z1), v(x0, y0, z0), v(x0, y1, z0), v(x0, y1, z1),
    });
    append_quad(mesh, .{
        // y_pos
        v(x0, y1, z0), v(x1, y1, z0), v(x1, y1, z1), v(x0, y1, z1),
    });
    append_quad(mesh, .{
        // y_neg
        v(x0, y0, z1), v(x1, y0, z1), v(x1, y0, z0), v(x0, y0, z0),
    });
    append_quad(mesh, .{
        // z_pos
        v(x1, y0, z1), v(x0, y0, z1), v(x0, y1, z1), v(x1, y1, z1),
    });
    append_quad(mesh, .{
        // z_neg
        v(x0, y0, z0), v(x1, y0, z0), v(x1, y1, z0), v(x0, y1, z0),
    });
}

fn v(x: i16, y: i16, z: i16) Vertex {
    return .{ .pos = .{ x, y, z }, .uv = .{ 0, 0 }, .color = COLOR };
}

fn append_quad(mesh: *Rendering.MeshDataType(Vertex), q: [4]Vertex) void {
    mesh.add_quad_assume_capacity(q[0], q[3], q[2], q[1]);
}
