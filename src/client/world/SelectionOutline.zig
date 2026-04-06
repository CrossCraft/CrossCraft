const std = @import("std");
const ae = @import("aether");
const Rendering = ae.Rendering;
const Transform = Rendering.Transform;

const Vertex = @import("../graphics/Vertex.zig").Vertex;

// Outline geometry lives in the same SNORM16 space as chunk meshes:
// 1 block = 2048 units (matches face.zig:encode_pos). The selection mesh
// is a unit cube (0..1 block) -- callers scale by 16 in the model matrix to
// recover world units, mirroring ChunkMesh.model_matrix.
const LO: i16 = 0;
const HI: i16 = 2048;

const COLOR: u32 = 0xAA202020; // opaque dark gray
const VERTEX_COUNT: usize = 24; // 12 edges * 2 endpoints

const Self = @This();

mesh: Rendering.Mesh(Vertex),

pub fn init(pipeline: Rendering.Pipeline.Handle) !Self {
    var self: Self = .{ .mesh = try Rendering.Mesh(Vertex).new(pipeline) };
    self.mesh.primitive = .lines;
    try build_edges(&self.mesh);
    std.debug.assert(self.mesh.vertices.items.len == VERTEX_COUNT);
    self.mesh.update();
    return self;
}

pub fn deinit(self: *Self) void {
    self.mesh.deinit();
}

/// Draw the outline at `transform`. Caller must have a 3D pipeline bound and
/// proj/view set; the model matrix comes from `transform.get_matrix()`.
pub fn draw(self: *Self, transform: *const Transform) void {
    const m = transform.get_matrix();
    self.mesh.draw(&m);
}

fn edge(mesh: *Rendering.Mesh(Vertex), x0: i16, y0: i16, z0: i16, x1: i16, y1: i16, z1: i16) !void {
    try mesh.append(&.{
        .{ .pos = .{ x0, y0, z0 }, .uv = .{ 0, 0 }, .color = COLOR },
        .{ .pos = .{ x1, y1, z1 }, .uv = .{ 0, 0 }, .color = COLOR },
    });
}

fn build_edges(mesh: *Rendering.Mesh(Vertex)) !void {
    // Bottom rectangle (y = LO)
    try edge(mesh, LO, LO, LO, HI, LO, LO);
    try edge(mesh, HI, LO, LO, HI, LO, HI);
    try edge(mesh, HI, LO, HI, LO, LO, HI);
    try edge(mesh, LO, LO, HI, LO, LO, LO);
    // Top rectangle (y = HI)
    try edge(mesh, LO, HI, LO, HI, HI, LO);
    try edge(mesh, HI, HI, LO, HI, HI, HI);
    try edge(mesh, HI, HI, HI, LO, HI, HI);
    try edge(mesh, LO, HI, HI, LO, HI, LO);
    // Vertical pillars
    try edge(mesh, LO, LO, LO, LO, HI, LO);
    try edge(mesh, HI, LO, LO, HI, HI, LO);
    try edge(mesh, HI, LO, HI, HI, HI, HI);
    try edge(mesh, LO, LO, HI, LO, HI, HI);
}
