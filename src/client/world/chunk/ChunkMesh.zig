const std = @import("std");
const ae = @import("aether");
const Math = ae.Math;
const Rendering = ae.Rendering;

const Vertex = @import("../../graphics/Vertex.zig").Vertex;
const TextureAtlas = @import("../../graphics/TextureAtlas.zig").TextureAtlas;
const mesher = @import("mesher.zig");
const World = @import("game").World;

pub const BatchMesh = Rendering.Mesh(Vertex);

/// One 16x16x16 section with 3 meshes:
///   opaque -- solid blocks + buried (solid) leaf faces
///   trans  -- outer leaves + glass/cross
///   fluid  -- water/lava (drawn last with depth writes off)
/// Each mesh owns its vertex storage via the render allocator.
@"opaque": BatchMesh,
trans: BatchMesh,
fluid: BatchMesh,
cx: u32,
sy: u32,
cz: u32,
/// Whether this section was last rebuilt as "near LOD" (within
/// LOD_NEAR_RADIUS_BLOCKS of the camera). World owns the value: it
/// updates the field when the section transitions across the radius and
/// queues a rebuild so the mesher picks the new state up.
near_lod: bool,
/// Bouncy-rise animation progress in [0, 1]. 1 means at rest; 0 means the
/// section is drawn 16 blocks below its natural Y. World kicks this to 0 the
/// first time a section is meshed when the bouncy_chunks option is enabled,
/// then advances toward 1 over 1 second via update_animation().
anim_progress: f32,
/// True until the first successful rebuild() — used by World to distinguish
/// newly-meshed sections from dirty rebuilds.
first_build: bool,
allocator: std.mem.Allocator,

const Self = @This();

pub fn init(allocator: std.mem.Allocator, pipeline: Rendering.Pipeline.Handle, cx: u32, sy: u32, cz: u32) !Self {
    return .{
        .@"opaque" = try BatchMesh.new(allocator, pipeline),
        .trans = try BatchMesh.new(allocator, pipeline),
        .fluid = try BatchMesh.new(allocator, pipeline),
        .cx = cx,
        .sy = sy,
        .cz = cz,
        .near_lod = false,
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
    self.@"opaque".deinit(self.allocator);
    self.trans.deinit(self.allocator);
    self.fluid.deinit(self.allocator);
}

/// Release vertex data but keep GPU handles alive for reuse.
pub fn clear(self: *Self) void {
    const a = self.allocator;
    self.@"opaque".vertices.clearAndFree(a);
    self.trans.vertices.clearAndFree(a);
    self.fluid.vertices.clearAndFree(a);
}

pub fn rebuild(self: *Self, atlas: *const TextureAtlas) error{OutOfMemory}!void {
    // All-air chunks have no visible faces -- skip pack/count/emit entirely.
    if (World.is_chunk_all_air(self.cx, self.sy, self.cz)) {
        self.@"opaque".vertices.clearRetainingCapacity();
        self.trans.vertices.clearRetainingCapacity();
        self.fluid.vertices.clearRetainingCapacity();
        return;
    }

    var buf: mesher.SectionBuf = undefined;
    mesher.pack_section(self.cx, self.sy, self.cz, self.near_lod, &buf);

    const counts = mesher.count_section(&buf);
    const a = self.allocator;

    self.@"opaque".vertices.clearRetainingCapacity();
    self.trans.vertices.clearRetainingCapacity();
    self.fluid.vertices.clearRetainingCapacity();

    try self.@"opaque".vertices.ensureTotalCapacity(a, counts.opaque_verts);
    try self.trans.vertices.ensureTotalCapacity(a, counts.transparent_verts);
    try self.fluid.vertices.ensureTotalCapacity(a, counts.fluid_verts);

    mesher.emit_section(&buf, self.cx, self.sy, self.cz, .{
        .@"opaque" = &self.@"opaque".vertices,
        .transparent = &self.trans.vertices,
        .fluid = &self.fluid.vertices,
    }, atlas);

    inline for (&.{ &self.@"opaque", &self.trans, &self.fluid }) |mesh| {
        if (mesh.vertices.items.len > 0) mesh.update();
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
    if (self.@"opaque".vertices.items.len == 0) return;
    const m = model_matrix(self, scale_opaque);
    self.@"opaque".draw(&m);
}

/// Draw transparent geometry (leaves, glass, cross-plants). Call back-to-front.
pub fn draw_transparent(self: *Self) void {
    if (self.trans.vertices.items.len == 0) return;
    const m = model_matrix(self, scale_trans);
    self.trans.draw(&m);
}

/// Draw fluid geometry (water, lava). Call back-to-front with depth writes off.
pub fn draw_fluid(self: *Self) void {
    if (self.fluid.vertices.items.len == 0) return;
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
