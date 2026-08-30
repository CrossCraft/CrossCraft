const std = @import("std");
const ae = @import("aether");
const Math = ae.Math;
const Rendering = ae.Rendering;

const Vertex = @import("aether").Rendering.Vertex;
const TextureAtlas = @import("../../graphics/TextureAtlas.zig").TextureAtlas;
const mesher = @import("mesher.zig");
const World = @import("core").World;

pub const BatchMesh = Rendering.MeshType(Vertex);
pub const BatchMeshData = Rendering.MeshDataType(Vertex);

/// One 16x16x16 section with 3 meshes:
///   opaque -- solid blocks + buried (solid) leaf faces
///   trans  -- outer leaves + glass/cross
///   fluid  -- water/lava (drawn last with depth writes off)
/// Each mesh owns its vertex storage via the render allocator.
opaque_data: BatchMeshData,
@"opaque": BatchMesh,
trans_data: BatchMeshData,
trans: BatchMesh,
fluid_data: BatchMeshData,
fluid: BatchMesh,
cx: u32,
sy: u32,
cz: u32,
/// Whether this section was last rebuilt as "near LOD" (within
/// LOD_NEAR_RADIUS_BLOCKS of the camera). World owns the value: it
/// updates the field when the section transitions across the radius and
/// queues a rebuild so the mesher picks the new state up.
near_lod: bool,
/// Whether this section was last rebuilt with ambient occlusion on. Same
/// ownership pattern as `near_lod` - World flips it and marks dirty when
/// Options.current.ambient_occlusion changes.
ao_enabled: bool,
/// Bouncy-rise animation progress in [0, 1]. 1 means at rest; 0 means the
/// section is drawn 16 blocks below its natural Y. World kicks this to 0 the
/// first time a section is meshed when the bouncy_chunks option is enabled,
/// then advances toward 1 over 1 second via update_animation().
anim_progress: f32,
/// True until the first successful rebuild() -- used by World to distinguish
/// newly-meshed sections from dirty rebuilds.
first_build: bool,
allocator: std.mem.Allocator,

const Self = @This();

pub fn init(allocator: std.mem.Allocator, cx: u32, sy: u32, cz: u32) !Self {
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

/// Advance the bouncy rise animation. No-op once the section is at rest.
pub fn update_animation(self: *Self, dt: f32) void {
    if (self.anim_progress < 1.0) {
        self.anim_progress = @min(self.anim_progress + dt, 1.0);
    }
}

pub fn deinit(self: *Self) void {
    self.@"opaque".deinit();
    self.trans.deinit();
    self.fluid.deinit();
    self.opaque_data.deinit(self.allocator);
    self.trans_data.deinit(self.allocator);
    self.fluid_data.deinit(self.allocator);
}

/// Release vertex data but keep GPU handles alive for reuse.
pub fn clear(self: *Self) void {
    const a = self.allocator;
    self.opaque_data.clear_and_free(a);
    self.trans_data.clear_and_free(a);
    self.fluid_data.clear_and_free(a);
}

pub fn rebuild(self: *Self, atlas: *const TextureAtlas) error{ OutOfMemory, IndexOverflow }!void {
    // All-air chunks have no visible faces -- skip pack/count/emit entirely.
    if (World.data.is_chunk_all_air(self.cx, self.sy, self.cz)) {
        self.opaque_data.clear_retaining_capacity();
        self.trans_data.clear_retaining_capacity();
        self.fluid_data.clear_retaining_capacity();
        return;
    }

    var buf: mesher.SectionBuf = undefined;
    // pack_section bundles the count phase and returns per-mesh totals so
    // we can pre-allocate exact capacity before emit. emit_section then uses
    // assume-capacity mesh helpers -- no per-row growth, no realloc thrash.
    const counts = mesher.pack_section(self.cx, self.sy, self.cz, self.near_lod, &buf);

    const a = self.allocator;
    self.opaque_data.clear_retaining_capacity();
    self.trans_data.clear_retaining_capacity();
    self.fluid_data.clear_retaining_capacity();

    try self.opaque_data.ensure_quad_capacity(a, counts.opaque_verts / 6);
    try self.trans_data.ensure_quad_capacity(a, counts.transparent_verts / 6);
    try self.fluid_data.ensure_quad_capacity(a, counts.fluid_verts / 6);

    mesher.emit_section(&buf, self.cx, self.sy, self.cz, .{
        .@"opaque" = &self.opaque_data,
        .transparent = &self.trans_data,
        .fluid = &self.fluid_data,
    }, atlas, self.ao_enabled);

    inline for (&.{ .{ &self.opaque_data, &self.@"opaque" }, .{ &self.trans_data, &self.trans }, .{ &self.fluid_data, &self.fluid } }) |pair| {
        if (pair[0].vertices.items.len > 0) pair[1].update(pair[0]);
    }
}

pub fn center_x(self: *const Self) f32 {
    return @as(f32, @floatFromInt(self.cx * 16)) + 8.0;
}
pub fn center_y(self: *const Self) f32 {
    return @as(f32, @floatFromInt(self.sy * 16)) + 8.0;
}
pub fn center_z(self: *const Self) f32 {
    return @as(f32, @floatFromInt(self.cz * 16)) + 8.0;
}

/// Draw opaque geometry only. Call front-to-back.
pub fn draw_opaque(self: *Self) void {
    if (self.opaque_data.vertices.items.len == 0) return;
    const m = model_matrix(self, scale_opaque);
    self.@"opaque".draw(&m);
}

/// Draw transparent geometry (leaves, glass, cross-plants). Call back-to-front.
pub fn draw_transparent(self: *Self) void {
    if (self.trans_data.vertices.items.len == 0) return;
    const m = model_matrix(self, scale_trans);
    self.trans.draw(&m);
}

/// Draw fluid geometry (water, lava). Call back-to-front with depth writes off.
pub fn draw_fluid(self: *Self) void {
    if (self.fluid_data.vertices.items.len == 0) return;
    const m = model_matrix(self, scale_trans);
    self.fluid.draw(&m);
}

// SNORM dequant divides by 32768 (not 32767), so encode_pos(16) = 32767
// maps to 32767/32768 ~= 0.99997, not 1.0. Over-compensate slightly so
// chunk edges overlap by a sub-pixel amount rather than leaving a gap.
// Opaque geometry can use a larger overlap (depth test hides it);
// translucent needs a tighter fit to avoid double-blend artifacts.
const scale_opaque: f32 = if (ae.platform == .psp) 16.0 * 32768.0 / 32753.0 else 16.0;
const scale_trans: f32 = if (ae.platform == .psp) 16.0 * 32768.0 / 32763.0 else 16.0;

fn model_matrix(self: *const Self, s: f32) Math.Mat4 {
    const wx: f32 = @floatFromInt(self.cx * 16);
    const base_wy: f32 = @floatFromInt(self.sy * 16);
    const wz: f32 = @floatFromInt(self.cz * 16);
    // Bouncy rise: at anim_progress=0 the section sits 16 blocks below its
    // natural Y, reaching rest at anim_progress=1. Stays at 1 (no offset) on
    // rebuilds and when the option is disabled.
    const wy = base_wy - 16.0 * (1.0 - self.anim_progress);
    return Math.Mat4.scaling(s, s, s).mul(Math.Mat4.translation(wx, wy, wz));
}
