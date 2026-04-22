const std = @import("std");
const ae = @import("aether");
const Rendering = ae.Rendering;
const Transform = Rendering.Transform;

const Vertex = @import("../graphics/Vertex.zig").Vertex;

// Outline geometry lives in the same SNORM16 space as chunk meshes:
// 1 block = 2048 units (matches face.zig:encode_pos). The selection mesh
// is a unit cube (0..1 block) -- callers scale by 16 in the model matrix to
// recover world units, mirroring ChunkMesh.model_matrix.
//
// The outline is built as 12 axis-aligned thin prisms (one per cube edge)
// rendered as triangles. Triangles are the one primitive every backend
// (OpenGL, Vulkan, PSP GE) rasterizes identically; the .lines primitive
// varies in width and anti-aliasing per backend.
//
// Each prism extends THICK past both cube corners along its edge axis so
// adjacent edge prisms overlap at the 8 cube corners, producing a gap-free
// outline without needing separate corner geometry (tiled seams between
// boxes can leave sub-pixel hairlines at shared edges). The camera-ward
// nudge at the draw site resolves z-fighting both between the outline
// and neighbouring block faces and among the overlapping prism faces.
const LO: i16 = 0;
const HI: i16 = 2048;
// 1/128 block in SNORM16 units (2048 / 128 = 16). Reads as a thin line at
// typical play distance without looking like a picture frame at close range.
const THICK: i16 = 32;

const COLOR: u32 = 0xAA202020; // opaque dark gray
// 12 edges * 6 faces * 2 triangles * 3 vertices.
const VERTEX_COUNT: usize = 432;

const Self = @This();

mesh: Rendering.Mesh(Vertex),
allocator: std.mem.Allocator,

pub fn init(allocator: std.mem.Allocator, pipeline: Rendering.Pipeline.Handle) !Self {
    var self: Self = .{
        .mesh = try Rendering.Mesh(Vertex).new(allocator, pipeline),
        .allocator = allocator,
    };
    self.mesh.primitive = .triangles;
    try self.mesh.vertices.ensureTotalCapacity(allocator, VERTEX_COUNT);
    try build_edges(allocator, &self.mesh);
    std.debug.assert(self.mesh.vertices.items.len == VERTEX_COUNT);
    self.mesh.update();
    return self;
}

pub fn deinit(self: *Self) void {
    self.mesh.deinit(self.allocator);
}

/// Draw the outline at `transform`. Caller must have a 3D pipeline bound and
/// proj/view set; the model matrix comes from `transform.get_matrix()`.
pub fn draw(self: *Self, transform: *const Transform) void {
    const m = transform.get_matrix();
    self.mesh.draw(&m);
}

const Axis = enum(u2) { x, y, z };

/// Descriptor for one cube edge: the axis it runs along, and which of the
/// two perpendicular coordinates are at the HI corner (vs LO).
const EdgeSpec = struct { axis: Axis, u_hi: bool, v_hi: bool };

// 12 edges: for each of the 3 axes, 4 edges at the 4 corners of the
// perpendicular LO/HI x LO/HI plane.
const EDGES = [_]EdgeSpec{
    // Along X: perpendicular axes are (Y, Z).
    .{ .axis = .x, .u_hi = false, .v_hi = false },
    .{ .axis = .x, .u_hi = false, .v_hi = true },
    .{ .axis = .x, .u_hi = true, .v_hi = false },
    .{ .axis = .x, .u_hi = true, .v_hi = true },
    // Along Y: perpendicular axes are (X, Z).
    .{ .axis = .y, .u_hi = false, .v_hi = false },
    .{ .axis = .y, .u_hi = false, .v_hi = true },
    .{ .axis = .y, .u_hi = true, .v_hi = false },
    .{ .axis = .y, .u_hi = true, .v_hi = true },
    // Along Z: perpendicular axes are (X, Y).
    .{ .axis = .z, .u_hi = false, .v_hi = false },
    .{ .axis = .z, .u_hi = false, .v_hi = true },
    .{ .axis = .z, .u_hi = true, .v_hi = false },
    .{ .axis = .z, .u_hi = true, .v_hi = true },
};

/// Return the outward offset range [lo, hi] for a cube-axis coordinate that
/// sits at LO (at_hi = false) or HI (at_hi = true). The range is THICK wide
/// and lies strictly outside the cube on the chosen side.
fn outward_range(at_hi: bool) struct { i16, i16 } {
    return if (at_hi) .{ HI, HI + THICK } else .{ LO - THICK, LO };
}

fn build_edges(alloc: std.mem.Allocator, mesh: *Rendering.Mesh(Vertex)) !void {
    for (EDGES) |e| {
        // Cross-section along the two non-edge axes is T wide, sitting
        // outside the cube on each side. Along the edge axis the prism
        // extends THICK past both cube corners so neighbouring edge
        // prisms overlap at the 8 cube corners -- no seam, no separate
        // corner geometry. The camera-ward nudge at the draw site keeps
        // the overlap from producing visible z-fight.
        const u_lo, const u_hi = outward_range(e.u_hi);
        const v_lo, const v_hi = outward_range(e.v_hi);
        const edge_lo: i16 = LO - THICK;
        const edge_hi: i16 = HI + THICK;

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
        try emit_box(alloc, mesh, c0, c1);
    }
}

/// Emit the 6 outward-facing quads (12 triangles, 36 vertices) of an AABB
/// from c0 to c1 (componentwise c0 < c1). Winding matches chunk face.zig
/// (outward normals, CCW from outside) so default backface culling hides
/// the inward-facing quads on all three backends.
fn emit_box(alloc: std.mem.Allocator, mesh: *Rendering.Mesh(Vertex), c0: [3]i16, c1: [3]i16) !void {
    const x0 = c0[0];
    const x1 = c1[0];
    const y0 = c0[1];
    const y1 = c1[1];
    const z0 = c0[2];
    const z1 = c1[2];

    // Helper: emit a quad as two triangles with the (0,2,1)(0,3,2) winding
    // used by emit_quad_uniform in chunk/face.zig.
    try append_quad(alloc, mesh, .{
        // x_pos
        v(x1, y0, z0), v(x1, y0, z1), v(x1, y1, z1), v(x1, y1, z0),
    });
    try append_quad(alloc, mesh, .{
        // x_neg
        v(x0, y0, z1), v(x0, y0, z0), v(x0, y1, z0), v(x0, y1, z1),
    });
    try append_quad(alloc, mesh, .{
        // y_pos
        v(x0, y1, z0), v(x1, y1, z0), v(x1, y1, z1), v(x0, y1, z1),
    });
    try append_quad(alloc, mesh, .{
        // y_neg
        v(x0, y0, z1), v(x1, y0, z1), v(x1, y0, z0), v(x0, y0, z0),
    });
    try append_quad(alloc, mesh, .{
        // z_pos
        v(x1, y0, z1), v(x0, y0, z1), v(x0, y1, z1), v(x1, y1, z1),
    });
    try append_quad(alloc, mesh, .{
        // z_neg
        v(x0, y0, z0), v(x1, y0, z0), v(x1, y1, z0), v(x0, y1, z0),
    });
}

fn v(x: i16, y: i16, z: i16) Vertex {
    return .{ .pos = .{ x, y, z }, .uv = .{ 0, 0 }, .color = COLOR };
}

fn append_quad(alloc: std.mem.Allocator, mesh: *Rendering.Mesh(Vertex), q: [4]Vertex) !void {
    try mesh.append(alloc, &.{ q[0], q[2], q[1], q[0], q[3], q[2] });
}
