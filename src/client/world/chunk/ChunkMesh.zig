const std = @import("std");
const ae = @import("aether");
const Math = ae.Math;
const Util = ae.Util;
const Rendering = ae.Rendering;

const Vertex = @import("../../graphics/Vertex.zig").Vertex;
const TextureAtlas = @import("../../graphics/TextureAtlas.zig").TextureAtlas;
const mesher = @import("mesher.zig");

pub const BatchMesh = Rendering.Mesh(Vertex);

/// One 16x16x16 section with 2 meshes:
///   opaque -- solid blocks + leaf shell faces
///   trans  -- outer leaves + water/glass/cross
/// Each mesh owns its vertex storage via the render allocator.
@"opaque": BatchMesh,
trans: BatchMesh,
cx: u32,
sy: u32,
cz: u32,

const Self = @This();

pub fn init(pipeline: Rendering.Pipeline.Handle, cx: u32, sy: u32, cz: u32) !Self {
    return .{
        .@"opaque" = try BatchMesh.new(pipeline),
        .trans = try BatchMesh.new(pipeline),
        .cx = cx,
        .sy = sy,
        .cz = cz,
    };
}

pub fn deinit(self: *Self) void {
    self.@"opaque".deinit();
    self.trans.deinit();
}

/// Release vertex data but keep GPU handles alive for reuse.
pub fn clear(self: *Self) void {
    const a = Util.allocator(.render);
    self.@"opaque".vertices.clearAndFree(a);
    self.trans.vertices.clearAndFree(a);
}

pub fn rebuild(self: *Self, atlas: *const TextureAtlas) error{OutOfMemory}!void {
    var buf: mesher.SectionBuf = undefined;
    mesher.pack_section(self.cx, self.sy, self.cz, &buf);
    const counts = mesher.count_section(&buf);

    const a = Util.allocator(.render);

    self.@"opaque".vertices.clearRetainingCapacity();
    self.trans.vertices.clearRetainingCapacity();

    try self.@"opaque".vertices.ensureTotalCapacity(a, counts.opaque_verts);
    try self.trans.vertices.ensureTotalCapacity(a, counts.transparent_verts);

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
