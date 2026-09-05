//! Section meshes: opaque blocks and buried leaves, transparent blocks, and fluids.

const std = @import("std");
const assert = std.debug.assert;
const ae = @import("aether");
const caps = @import("capabilities").ClientType(ae);
const Math = ae.Math;
const Rendering = ae.Rendering;

const Vertex = @import("aether").Rendering.Vertex;
const TextureAtlas = @import("../../graphics/TextureAtlas.zig").TextureAtlas;
const mesher = @import("mesher.zig");
const World = @import("core").World;

pub const BatchMesh = Rendering.MeshType(Vertex);
pub const BatchMeshData = Rendering.MeshDataType(Vertex);

opaque_data: BatchMeshData,
@"opaque": BatchMesh,
trans_data: BatchMeshData,
trans: BatchMesh,
fluid_data: BatchMeshData,
fluid: BatchMesh,
cx: u32,
sy: u32,
cz: u32,
near_lod: bool,
ao_enabled: bool,
/// Rises from 16 blocks below its position at 0 to rest at 1.
anim_progress: f32,
first_build: bool,
allocator: std.mem.Allocator,

const ChunkMesh = @This();

pub fn init(allocator: std.mem.Allocator, cx: u32, sy: u32, cz: u32) !ChunkMesh {
    return .{
        .opaque_data = try BatchMeshData.init(allocator),
        .@"opaque" = try BatchMesh.init(&.{}),
        .trans_data = try BatchMeshData.init(allocator),
        .trans = try BatchMesh.init(&.{}),
        .fluid_data = try BatchMeshData.init(allocator),
        .fluid = try BatchMesh.init(&.{}),
        .cx = cx,
        .sy = sy,
        .cz = cz,
        .near_lod = false,
        .ao_enabled = false,
        .anim_progress = 1.0,
        .first_build = true,
        .allocator = allocator,
    };
}

pub fn update_animation(self: *ChunkMesh, dt: f32) void {
    assert(std.math.isFinite(dt) and dt >= 0.0);
    assert(self.anim_progress >= 0.0 and self.anim_progress <= 1.0);
    if (self.anim_progress < 1.0) {
        self.anim_progress = @min(self.anim_progress + dt, 1.0);
    }
}

pub fn deinit(self: *ChunkMesh) void {
    self.@"opaque".deinit();
    self.trans.deinit();
    self.fluid.deinit();
    self.opaque_data.deinit(self.allocator);
    self.trans_data.deinit(self.allocator);
    self.fluid_data.deinit(self.allocator);
    self.* = undefined;
}

/// Release vertex data but keep GPU handles alive for reuse.
pub fn clear(self: *ChunkMesh) void {
    const a = self.allocator;
    self.opaque_data.clear_and_free(a);
    self.trans_data.clear_and_free(a);
    self.fluid_data.clear_and_free(a);
}

pub fn rebuild(self: *ChunkMesh, atlas: *const TextureAtlas) error{ OutOfMemory, IndexOverflow }!void {
    self.opaque_data.clear_retaining_capacity();
    self.trans_data.clear_retaining_capacity();
    self.fluid_data.clear_retaining_capacity();
    {
        // Network block updates must not change the world between counting
        // faces and emitting their geometry.
        World.lock_world_shared();
        defer World.unlock_world_shared();

        if (World.data.is_chunk_all_air(self.cx, self.sy, self.cz)) return;

        var buf: mesher.SectionBuf = undefined;
        const counts = mesher.pack_section(self.cx, self.sy, self.cz, self.near_lod, &buf);
        assert(counts.opaque_verts % 6 == 0);
        assert(counts.transparent_verts % 6 == 0);
        assert(counts.fluid_verts % 6 == 0);
        const a = self.allocator;
        try self.opaque_data.ensure_quad_capacity(a, counts.opaque_verts / 6);
        try self.trans_data.ensure_quad_capacity(a, counts.transparent_verts / 6);
        try self.fluid_data.ensure_quad_capacity(a, counts.fluid_verts / 6);

        mesher.emit_section(&buf, self.cx, self.sy, self.cz, .{
            .@"opaque" = &self.opaque_data,
            .transparent = &self.trans_data,
            .fluid = &self.fluid_data,
        }, atlas, self.ao_enabled);

        // Counting and emission must agree, including double-sided fluid faces.
        const verts_per_quad: usize = if (Rendering.mesh.indexing_enabled) 4 else 6;
        assert(self.opaque_data.vertices.items.len == counts.opaque_verts / 6 * verts_per_quad);
        assert(self.trans_data.vertices.items.len == counts.transparent_verts / 6 * verts_per_quad);
        assert(self.fluid_data.vertices.items.len == counts.fluid_verts / 6 * verts_per_quad);
    }

    inline for (&.{ .{ &self.opaque_data, &self.@"opaque" }, .{ &self.trans_data, &self.trans }, .{ &self.fluid_data, &self.fluid } }) |pair| {
        if (pair[0].vertices.items.len > 0) pair[1].update(pair[0]);
    }
}

/// Draw opaque geometry only. Call front-to-back.
pub fn draw_opaque(self: *ChunkMesh) void {
    if (self.opaque_data.vertices.items.len == 0) return;
    const m = model_matrix(self, scale_opaque);
    self.@"opaque".draw(&m);
}

/// Draw transparent geometry (leaves, glass, cross-plants). Call back-to-front.
pub fn draw_transparent(self: *ChunkMesh) void {
    if (self.trans_data.vertices.items.len == 0) return;
    const m = model_matrix(self, scale_trans);
    self.trans.draw(&m);
}

/// Draw fluid geometry (water, lava). Call back-to-front with depth writes off.
pub fn draw_fluid(self: *ChunkMesh) void {
    if (self.fluid_data.vertices.items.len == 0) return;
    const m = model_matrix(self, scale_trans);
    self.fluid.draw(&m);
}

// Compensate for PSP SNORM dequantization gaps. Translucent geometry needs
// less overlap to avoid double blending.
const scale_opaque: f32 = caps.render.opaque_chunk_scale;
const scale_trans: f32 = caps.render.translucent_chunk_scale;

fn model_matrix(self: *const ChunkMesh, s: f32) Math.Mat4 {
    const wx: f32 = @floatFromInt(self.cx * 16);
    const base_wy: f32 = @floatFromInt(self.sy * 16);
    const wz: f32 = @floatFromInt(self.cz * 16);
    const wy = base_wy - 16.0 * (1.0 - self.anim_progress);
    return Math.Mat4.scaling(s, s, s).mul(Math.Mat4.translation(wx, wy, wz));
}
