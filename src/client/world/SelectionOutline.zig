const std = @import("std");
const ae = @import("aether");
const Rendering = ae.Rendering;
const Transform = Rendering.Transform;
const common = @import("common");
const SubvoxelBounds = common.BlockRegistry.SubvoxelBounds;

const Vertex = @import("../graphics/Vertex.zig").Vertex;

// Outline geometry lives in the same SNORM16 space as chunk meshes:
// 1 block = 2048 units (matches face.zig:encode_pos). The selection mesh
// is a unit cube (0..1 block) -- callers scale by the block's AABB size
// in 1/16 units in the model matrix to recover world units, mirroring
// ChunkMesh.model_matrix.
//
// The outline is built as 12 axis-aligned thin prisms (one per cube edge)
// rendered as triangles. Triangles are the one primitive every backend
// (OpenGL, Vulkan, PSP GE) rasterizes identically; the .lines primitive
// varies in width and anti-aliasing per backend.
//
// Each prism extends past both cube corners along its edge axis so
// adjacent edge prisms overlap at the 8 cube corners, producing a gap-free
// outline without needing separate corner geometry (tiled seams between
// boxes can leave sub-pixel hairlines at shared edges). The camera-ward
// nudge at the draw site resolves z-fighting both between the outline
// and neighbouring block faces and among the overlapping prism faces.
//
// Thickness is pre-compensated per-axis when the selected block's bounds
// change, so slabs and flowers get the same visible line width as full
// cubes (naive scaling would shrink the outline with the AABB). The mesh
// is rebuilt only when bounds differ from the previous frame's.
const LO: i16 = 0;
const HI: i16 = 2048;

// Per-axis SNORM thickness is `N / axis_size_in_sixteenths`. With
// SNORM-per-block = 32768 and model-matrix scale = axis_size, world value
// is `N * 16 / 32768` = constant regardless of the block's AABB.
//
// THICK_NUMERATOR drives the full cross-section width of the outline line
// (what you perceive as line thickness on a block face). PROTRUSION is how
// much of that cross-section sits *outside* the block; the rest (thick -
// protrusion) extends *into* the block (hidden by the opaque block face
// from every view except along the face plane itself, which is covered by
// the camera-ward nudge). This decouples visible line thickness from how
// much the outline inflates the block silhouette.
//
//   PROTRUSION = 80  => ~1/400 block outside each face -> ~1.005x block size.
//   THICK      = 384 => ~3/256 block visible on a face (~1 px on PSP).
//
// PSP bumps the protrusion because at 480x272 the sub-pixel outer extent
// is invisible; a slightly larger silhouette outline reads correctly.
const THICK_NUMERATOR: i32 = 384;
const PROTRUSION_NUMERATOR: i32 = if (ae.platform == .psp) 240 else 80;

const COLOR: u32 = 0xAA202020; // semi-transparent dark gray
// 12 edges * 6 faces * 2 triangles * 3 vertices.
const VERTEX_COUNT: usize = 432;

const Self = @This();

const Axis = enum(u2) { x, y, z };
const PerAxis = struct { x: i16, y: i16, z: i16 };
const Thickness = struct { thick: PerAxis, protrusion: PerAxis };

mesh: Rendering.Mesh(Vertex),
allocator: std.mem.Allocator,
last_bounds: ?SubvoxelBounds = null,

pub fn init(allocator: std.mem.Allocator, pipeline: Rendering.Pipeline.Handle) !Self {
    var self: Self = .{
        .mesh = try Rendering.Mesh(Vertex).new(allocator, pipeline),
        .allocator = allocator,
    };
    self.mesh.primitive = .triangles;
    try self.mesh.vertices.ensureTotalCapacity(allocator, VERTEX_COUNT);
    return self;
}

pub fn deinit(self: *Self) void {
    self.mesh.deinit(self.allocator);
}

/// Ensure the mesh matches `bounds`, rebuilding if they differ from the
/// last call. Caller should invoke this before `draw` each frame with the
/// selected block's bounds.
pub fn update(self: *Self, bounds: SubvoxelBounds) !void {
    if (self.last_bounds) |prev| {
        if (std.meta.eql(prev, bounds)) return;
    }
    self.last_bounds = bounds;
    self.mesh.vertices.clearRetainingCapacity();
    try build_edges(self.allocator, &self.mesh, compute_thick(bounds));
    std.debug.assert(self.mesh.vertices.items.len == VERTEX_COUNT);
    self.mesh.update();
}

/// Draw the outline at `transform`. Caller must have a 3D pipeline bound and
/// proj/view set; the model matrix comes from `transform.get_matrix()`.
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

/// Return the cross-section range [lo, hi] on a perpendicular axis for an
/// edge that sits at LO (at_hi = false) or HI (at_hi = true). The range is
/// `total` wide total, with `protrusion` outside the cube and (total -
/// protrusion) inside -- so the outline only inflates the cube silhouette
/// by `protrusion` per side while keeping `total` visible cross-section on
/// each face of the block.
fn outward_range(at_hi: bool, total: i16, protrusion: i16) struct { i16, i16 } {
    const inside = total - protrusion;
    return if (at_hi)
        .{ HI - inside, HI + protrusion }
    else
        .{ LO - protrusion, LO + inside };
}

fn build_edges(alloc: std.mem.Allocator, mesh: *Rendering.Mesh(Vertex), t: Thickness) !void {
    for (EDGES) |e| {
        const u_axis, const v_axis = perp_axes(e.axis);
        const u_lo, const u_hi = outward_range(e.u_hi, axis_thick(t.thick, u_axis), axis_thick(t.protrusion, u_axis));
        const v_lo, const v_hi = outward_range(e.v_hi, axis_thick(t.thick, v_axis), axis_thick(t.protrusion, v_axis));
        // Edge-axis extension: extend past the cube by the protrusion amount
        // only, so the outline's outer silhouette is 1 + 2*protrusion wide on
        // every axis. Neighbouring edge prisms still overlap because their
        // cross-sections span the same outer protrusion region.
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
