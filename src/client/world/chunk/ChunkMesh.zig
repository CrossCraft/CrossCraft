//! Section meshes: opaque blocks and buried leaves, transparent blocks, and fluids.
const std = @import("std");
const ae = @import("aether");
const Vertex = @import("aether").Rendering.Vertex;
const capabilities = @import("capabilities");
const mesher = @import("meshing").mesher;

const assert = std.debug.assert;
const caps = capabilities.ClientType(ae);
const Math = ae.Math;
const Rendering = ae.Rendering;

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
/// Face pairs joined through non-opaque cells, for cave culling. Unbuilt sections stay fully connected so culling never hides them.
connectivity: u16,
/// First opaque quad of each face direction in mesher.opaque_dir_faces order, then the opaque quad count.
opaque_dir_start: [7]u16,
/// GPU fence of the last frame that drew this section; its buffers must not be rewritten or freed before it passes.
drawn_fence: u32,
/// Rises from 16 blocks below its position at 0 to rest at 1.
anim_progress: f32,
first_build: bool,
allocator: std.mem.Allocator,

const ChunkMesh = @This();

const fenced_desc: Rendering.mesh.Desc = .{ .retention = .fenced };

pub fn init(allocator: std.mem.Allocator, cx: u32, sy: u32, cz: u32) !ChunkMesh {
    return .{
        .opaque_data = try BatchMeshData.init(allocator),
        .@"opaque" = try BatchMesh.init(&fenced_desc),
        .trans_data = try BatchMeshData.init(allocator),
        .trans = try BatchMesh.init(&fenced_desc),
        .fluid_data = try BatchMeshData.init(allocator),
        .fluid = try BatchMesh.init(&fenced_desc),
        .cx = cx,
        .sy = sy,
        .cz = cz,
        .near_lod = false,
        .ao_enabled = false,
        .connectivity = mesher.all_faces_connected,
        .opaque_dir_start = @splat(0),
        .drawn_fence = 0,
        .anim_progress = 1.0,
        .first_build = true,
        .allocator = allocator,
    };
}

pub fn update_animation(self: *ChunkMesh, dt: f32) void {
    assert(std.math.isFinite(dt) and dt >= 0.0);
    assert(self.anim_progress >= 0.0 and self.anim_progress <= 1.0);
    if (self.anim_progress < 1.0) {
        self.anim_progress = Math.min(self.anim_progress + dt, 1.0);
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

/// Empty without clear_retaining_capacity, whose safe-build memset of the old contents cost up to ~0.7 ms per section on PSP.
pub fn truncate(data: *BatchMeshData) void {
    data.vertices.items.len = 0;
    data.indices.items.len = 0;
}

/// Draw opaque geometry only. Call front-to-back. Directions whose faces all point away from `eye` are skipped.
pub fn draw_opaque(self: *ChunkMesh, eye: [3]f32) void {
    if (self.opaque_data.vertices.items.len == 0) return;
    self.drawn_fence = Rendering.gfx.api.gpu_fence();
    const m = model_matrix(self, scale_opaque);
    // The bounce animation moves the section off its grid bounds.
    if (self.anim_progress < 1.0) {
        self.@"opaque".draw(&m);
        return;
    }
    const lo = [3]f32{
        @floatFromInt(self.cx * 16),
        @floatFromInt(self.sy * 16),
        @floatFromInt(self.cz * 16),
    };

    // A face toward -axis can only be seen from before the section's far side on that axis, and a face toward +axis only from beyond its near side.
    var keep: [7]bool = undefined;
    for (0..3) |axis| {
        keep[axis * 2] = eye[axis] < lo[axis] + 16.0;
        keep[axis * 2 + 1] = eye[axis] > lo[axis];
    }
    keep[6] = false;
    var d: usize = 0;
    while (d < 6) {
        if (!keep[d]) {
            d += 1;
            continue;
        }
        const first = self.opaque_dir_start[d];
        while (keep[d]) d += 1;
        const quads: u32 = self.opaque_dir_start[d] - first;
        if (quads == 0) continue;
        // Six elements per quad: indices when indexed, vertices otherwise.
        self.@"opaque".draw_range(&m, @as(u32, first) * 6, quads * 6);
    }
}

/// Draw transparent geometry (leaves, glass, cross-plants). Call back-to-front.
pub fn draw_transparent(self: *ChunkMesh) void {
    if (self.trans_data.vertices.items.len == 0) return;
    self.drawn_fence = Rendering.gfx.api.gpu_fence();
    const m = model_matrix(self, scale_trans);
    self.trans.draw(&m);
}

/// Draw fluid geometry (water, lava). Call back-to-front with depth writes off.
pub fn draw_fluid(self: *ChunkMesh) void {
    if (self.fluid_data.vertices.items.len == 0) return;
    self.drawn_fence = Rendering.gfx.api.gpu_fence();
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
