const std = @import("std");
const ae = @import("aether");
const Math = ae.Math;
const Util = ae.Util;
const Rendering = ae.Rendering;

const Vertex = @import("../../graphics/Vertex.zig").Vertex;
const TextureAtlas = @import("../../graphics/TextureAtlas.zig").TextureAtlas;
const mesher = @import("mesher.zig");
pub const MeshPool = @import("MeshPool.zig").MeshPool;

pub const BatchMesh = Rendering.Mesh(Vertex);

/// One 16x16x16 section with 2 meshes:
///   opaque -- solid blocks + leaf shell faces
///   trans  -- outer leaves + water/glass/cross
@"opaque": BatchMesh,
trans: BatchMesh,
cx: u32,
sy: u32,
cz: u32,

const Self = @This();

pub fn init(pipeline: Rendering.Pipeline.Handle, cx: u32, sy: u32, cz: u32) !Self {
    var self = Self{
        .@"opaque" = undefined, .trans = undefined,
        .cx = cx, .sy = sy, .cz = cz,
    };
    self.@"opaque" = try BatchMesh.new(pipeline);
    self.trans = try BatchMesh.new(pipeline);
    const a = Util.allocator(.render);
    self.@"opaque".vertices.deinit(a);
    self.trans.vertices.deinit(a);
    self.clear_meshes();
    return self;
}

pub fn deinit(self: *Self) void {
    self.clear_meshes();
    self.@"opaque".deinit();
    self.trans.deinit();
}

fn clear_meshes(self: *Self) void {
    inline for (&.{ &self.@"opaque", &self.trans }) |mesh| {
        mesh.vertices.items = &.{};
        mesh.vertices.capacity = 0;
    }
}

fn bind_mesh(mesh: *BatchMesh, pool: *MeshPool, count: u32) bool {
    if (count == 0) {
        mesh.vertices.items = &.{};
        mesh.vertices.capacity = 0;
        return true;
    }
    const ptr = pool.alloc(count) orelse return false;
    mesh.vertices.items.ptr = ptr;
    mesh.vertices.items.len = 0;
    mesh.vertices.capacity = count;
    return true;
}

pub fn rebuild(self: *Self, pool: *MeshPool, atlas: *const TextureAtlas) void {
    var buf: mesher.SectionBuf = undefined;
    mesher.pack_section(self.cx, self.sy, self.cz, &buf);
    const counts = mesher.count_section(&buf);

    if (!bind_mesh(&self.@"opaque", pool, counts.opaque_verts) or
        !bind_mesh(&self.trans, pool, counts.transparent_verts))
    {
        self.clear_meshes();
        return;
    }

    mesher.emit_section(&buf, self.cx, self.sy, self.cz, .{
        .@"opaque" = &self.@"opaque".vertices,
        .transparent = &self.trans.vertices,
    }, atlas);

    inline for (&.{ &self.@"opaque", &self.trans }) |mesh| {
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
    const m = model_matrix(self);
    self.@"opaque".draw(&m);
}

/// Draw transparent geometry. Call back-to-front.
pub fn draw_transparent(self: *Self) void {
    if (self.trans.vertices.items.len == 0) return;
    const m = model_matrix(self);
    self.trans.draw(&m);
}

fn model_matrix(self: *const Self) Math.Mat4 {
    const wx: f32 = @floatFromInt(self.cx * 16);
    const wy: f32 = @floatFromInt(self.sy * 16);
    const wz: f32 = @floatFromInt(self.cz * 16);
    return Math.Mat4.scaling(16.0, 16.0, 16.0).mul(Math.Mat4.translation(wx, wy, wz));
}
