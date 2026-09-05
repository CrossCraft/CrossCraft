const std = @import("std");
const assert = std.debug.assert;
const ae = @import("aether");
const Math = ae.Math;
const Rendering = ae.Rendering;

const core = @import("core");
const World = core.World;

const Vertex = @import("aether").Rendering.Vertex;
const Camera = @import("../player/Camera.zig");
const TextureAtlas = @import("../graphics/TextureAtlas.zig").TextureAtlas;
const face_mod = @import("chunk/face.zig");
const Block = core.blocks.Block;

const MaxParticles: u16 = 512;
const PerBreak: u16 = 48;
const LifetimeMin: f32 = 0.3;
const LifetimeMax: f32 = 1.0;
const Gravity: f32 = 16.0;
const GravityLeaves: f32 = 10.0;
const HalfSize: f32 = 0.06;
const SubtileDiv: i16 = 4;

// Encode positions relative to the mesh origin at 128 vertex units per block,
// then restore world units with a 256x model scale and origin translation.
const PosScale: f32 = 128.0;
const ModelScale: f32 = 256.0;

const Particle = struct {
    px: f32,
    py: f32,
    pz: f32,
    vx: f32,
    vy: f32,
    vz: f32,
    u0: i16,
    v0: i16,
    u1: i16,
    v1: i16,
    life: f32,
    gravity: f32,
};

fn gravity_for(block_id: Block) f32 {
    return switch (block_id) {
        .leaves => GravityLeaves,
        else => Gravity,
    };
}

const ParticleSystem = @This();

mesh_data: Rendering.MeshDataType(Vertex),
mesh: Rendering.MeshType(Vertex),
mesh_origin: Math.Vec3,
atlas: TextureAtlas,
particles: [MaxParticles]Particle,
count: u16,
rng: std.Random.DefaultPrng,
allocator: std.mem.Allocator,

pub fn init(allocator: std.mem.Allocator, atlas: TextureAtlas) !ParticleSystem {
    var self: ParticleSystem = .{
        .mesh_data = try Rendering.MeshDataType(Vertex).init(allocator),
        .mesh = try Rendering.MeshType(Vertex).init(&.{}),
        .mesh_origin = Math.Vec3.zero(),
        .atlas = atlas,
        .particles = undefined,
        .count = 0,
        .rng = std.Random.DefaultPrng.init(0xC0FFEE),
        .allocator = allocator,
    };
    try self.mesh_data.ensure_quad_capacity(allocator, MaxParticles);
    return self;
}

pub fn deinit(self: *ParticleSystem) void {
    self.mesh.deinit();
    self.mesh_data.deinit(self.allocator);
    self.* = undefined;
}

pub fn spawn_break(self: *ParticleSystem, block_id: Block, bx: u16, by: u16, bz: u16) void {
    assert(!block_id.is_air());
    assert(bx < World.data.dims.length);
    assert(by < World.data.dims.height);
    assert(bz < World.data.dims.depth);

    const tile = block_id.face_tile(.x_neg);
    const tu = self.atlas.tile_u(tile.col);
    const tv = self.atlas.tile_v(tile.row);
    const tw = self.atlas.tile_width();
    const th = self.atlas.tile_height();
    const du: i16 = @divTrunc(tw, SubtileDiv);
    const dv: i16 = @divTrunc(th, SubtileDiv);

    const cx: f32 = @as(f32, @floatFromInt(bx)) + 0.5;
    const cy: f32 = @as(f32, @floatFromInt(by)) + 0.5;
    const cz: f32 = @as(f32, @floatFromInt(bz)) + 0.5;

    var rand = self.rng.random();
    const gravity = gravity_for(block_id);

    var i: u16 = 0;
    while (i < PerBreak) : (i += 1) {
        if (self.count >= MaxParticles) break;

        const sx: i16 = @intCast(rand.intRangeLessThan(u8, 0, @intCast(SubtileDiv)));
        const sy: i16 = @intCast(rand.intRangeLessThan(u8, 0, @intCast(SubtileDiv)));

        const ox = (rand.float(f32) - 0.5) * 0.9;
        const oy = (rand.float(f32) - 0.5) * 0.9;
        const oz = (rand.float(f32) - 0.5) * 0.9;
        const burst_speed: f32 = 4.0;
        const jitter: f32 = 0.4;
        const upward_bias: f32 = 2.0;
        self.particles[self.count] = .{
            .px = cx + ox,
            .py = cy + oy,
            .pz = cz + oz,
            .vx = ox * burst_speed + (rand.float(f32) - 0.5) * jitter,
            .vy = oy * burst_speed + (rand.float(f32) - 0.5) * jitter + upward_bias,
            .vz = oz * burst_speed + (rand.float(f32) - 0.5) * jitter,
            .u0 = tu + sx * du,
            .v0 = tv + sy * dv,
            .u1 = tu + (sx + 1) * du,
            .v1 = tv + (sy + 1) * dv,
            .life = LifetimeMin + rand.float(f32) * (LifetimeMax - LifetimeMin),
            .gravity = gravity,
        };
        self.count += 1;
    }
}

pub fn update(self: *ParticleSystem, dt: f32, camera: *const Camera) void {
    self.update_particles(dt);
    self.rebuild_mesh(camera);
    if (self.mesh_data.vertices.items.len != 0) self.mesh.update(&self.mesh_data);
}

fn update_particles(self: *ParticleSystem, dt: f32) void {
    assert(dt >= 0);
    assert(std.math.isFinite(dt));
    assert(self.count <= self.particles.len);

    var i: u16 = 0;
    while (i < self.count) {
        const p = &self.particles[i];
        p.life -= dt;
        if (p.life <= 0.0) {
            self.count -= 1;
            self.particles[i] = self.particles[self.count];
            continue;
        }
        p.vy -= p.gravity * dt;
        step_axis_x(p, p.vx * dt);
        step_axis_y(p, p.vy * dt);
        step_axis_z(p, p.vz * dt);
        i += 1;
    }
}

// Only block entry into new solid geometry: particles initially spawn before
// the server's air update has round-tripped to the client.
const CollisionRadius: f32 = HalfSize;

fn step_axis_x(p: *Particle, dx: f32) void {
    const nx = p.px + dx;
    if (aabb_hits_solid(nx, p.py, p.pz) and !aabb_hits_solid(p.px, p.py, p.pz)) {
        p.vx = 0;
        return;
    }
    p.px = nx;
}

fn step_axis_y(p: *Particle, dy: f32) void {
    const ny = p.py + dy;
    if (aabb_hits_solid(p.px, ny, p.pz) and !aabb_hits_solid(p.px, p.py, p.pz)) {
        if (dy < 0.0) {
            p.vx = 0;
            p.vz = 0;
        }
        p.vy = 0;
        return;
    }
    p.py = ny;
}

fn step_axis_z(p: *Particle, dz: f32) void {
    const nz = p.pz + dz;
    if (aabb_hits_solid(p.px, p.py, nz) and !aabb_hits_solid(p.px, p.py, p.pz)) {
        p.vz = 0;
        return;
    }
    p.pz = nz;
}

fn aabb_hits_solid(wx: f32, wy: f32, wz: f32) bool {
    const bx0: i32 = @intFromFloat(@floor(wx - CollisionRadius));
    const bx1: i32 = @intFromFloat(@floor(wx + CollisionRadius));
    const by0: i32 = @intFromFloat(@floor(wy - CollisionRadius));
    const by1: i32 = @intFromFloat(@floor(wy + CollisionRadius));
    const bz0: i32 = @intFromFloat(@floor(wz - CollisionRadius));
    const bz1: i32 = @intFromFloat(@floor(wz + CollisionRadius));

    const dims = World.data.dims;
    const max_x: i32 = @intCast(dims.length);
    const max_y: i32 = @intCast(dims.height);
    const max_z: i32 = @intCast(dims.depth);

    var bx = bx0;
    while (bx <= bx1) : (bx += 1) {
        if (bx < 0 or bx >= max_x) continue;
        var by = by0;
        while (by <= by1) : (by += 1) {
            if (by < 0 or by >= max_y) continue;
            var bz = bz0;
            while (bz <= bz1) : (bz += 1) {
                if (bz < 0 or bz >= max_z) continue;
                const id = World.get_block(@intCast(bx), @intCast(by), @intCast(bz));
                if (id.collision_height() > 0.0) return true;
            }
        }
    }
    return false;
}

fn point_sunlit(wx: f32, wy: f32, wz: f32) bool {
    const bx: i32 = @intFromFloat(@floor(wx));
    const by: i32 = @intFromFloat(@floor(wy));
    const bz: i32 = @intFromFloat(@floor(wz));
    const dims = World.data.dims;
    if (bx < 0 or bx >= @as(i32, @intCast(dims.length))) return true;
    if (by < 0 or by >= @as(i32, @intCast(dims.height))) return true;
    if (bz < 0 or bz >= @as(i32, @intCast(dims.depth))) return true;
    return World.is_sunlit(@intCast(bx), @intCast(by), @intCast(bz));
}

pub fn draw(self: *ParticleSystem) void {
    if (self.mesh_data.vertices.items.len == 0) return;
    const m = Math.Mat4.scaling(ModelScale, ModelScale, ModelScale)
        .mul(Math.Mat4.translation(self.mesh_origin.x, self.mesh_origin.y, self.mesh_origin.z));
    self.mesh.draw(&m);
}

fn rebuild_mesh(self: *ParticleSystem, camera: *const Camera) void {
    self.mesh_data.clear_retaining_capacity();
    self.mesh_origin = Math.Vec3.new(@floor(camera.x), @floor(camera.y), @floor(camera.z));
    if (self.count == 0) return;

    // Yaw-only right vector prevents roll; pitched up vector faces the camera.
    const cy = @cos(camera.yaw);
    const sy = @sin(camera.yaw);
    const cp = @cos(camera.pitch);
    const sp = @sin(camera.pitch);
    const rx = cy * HalfSize;
    const rz = -sy * HalfSize;
    const upx = -sy * sp * HalfSize;
    const upy = cp * HalfSize;
    const upz = -cy * sp * HalfSize;

    var i: u16 = 0;
    while (i < self.count) : (i += 1) {
        emit_particle(&self.mesh_data, &self.particles[i], self.mesh_origin, rx, rz, upx, upy, upz);
    }
}

fn emit_particle(
    mesh: *Rendering.MeshDataType(Vertex),
    p: *const Particle,
    origin: Math.Vec3,
    rx: f32,
    rz: f32,
    upx: f32,
    upy: f32,
    upz: f32,
) void {
    const px = p.px - origin.x;
    const py = p.py - origin.y;
    const pz = p.pz - origin.z;
    // Cull distant geometry without ending the particle's simulation.
    if (!encodable(px) or !encodable(py) or !encodable(pz)) return;

    const base: u32 = 0xFF999999;
    const color: u32 = if (point_sunlit(p.px, p.py, p.pz)) base else face_mod.apply_shadow(base);

    const v0 = make_vertex(px - rx - upx, py - upy, pz - rz - upz, p.u0, p.v1, color);
    const v1 = make_vertex(px + rx - upx, py - upy, pz + rz - upz, p.u1, p.v1, color);
    const v2 = make_vertex(px + rx + upx, py + upy, pz + rz + upz, p.u1, p.v0, color);
    const v3 = make_vertex(px - rx + upx, py + upy, pz - rz + upz, p.u0, p.v0, color);

    mesh.add_quad_assume_capacity(v0, v1, v2, v3);
}

fn make_vertex(wx: f32, wy: f32, wz: f32, u: i16, v: i16, color: u32) Vertex {
    return .{
        .pos = .{ encode(wx), encode(wy), encode(wz) },
        .uv = .{ u, v },
        .color = color,
    };
}

fn encodable(local: f32) bool {
    const margin = 2.0 * HalfSize * PosScale;
    const scaled = @round(local * PosScale);
    return scaled >= -32768.0 + margin and scaled <= 32767.0 - margin;
}

fn encode(local: f32) i16 {
    assert(std.math.isFinite(local));
    assert(@round(local * PosScale) >= -32768.0 and @round(local * PosScale) <= 32767.0);
    return @intFromFloat(@round(local * PosScale));
}

test "particles survive and render across 512 block worlds" {
    const allocator = std.testing.allocator;
    try World.data.init_in_place(allocator, core.world_dims.WorldDims.init(512, 128, 512), 0);
    defer World.data.deinit();

    // Exercise CPU simulation and mesh generation without a graphics context.
    var particles: ParticleSystem = .{
        .mesh_data = try Rendering.MeshDataType(Vertex).init(allocator),
        .mesh = undefined,
        .mesh_origin = Math.Vec3.zero(),
        .atlas = TextureAtlas.init(16, 16),
        .particles = undefined,
        .count = 0,
        .rng = std.Random.DefaultPrng.init(0xC0FFEE),
        .allocator = allocator,
    };
    defer particles.mesh_data.deinit(allocator);

    try particles.mesh_data.ensure_quad_capacity(allocator, MaxParticles);

    const positions = [_][2]u16{ .{ 0, 0 }, .{ 255, 255 }, .{ 256, 32 }, .{ 32, 256 }, .{ 256, 256 }, .{ 511, 511 } };
    const verts_per_quad: usize = if (Rendering.mesh.indexing_enabled) 4 else 6;
    for (positions) |pos| {
        const bx, const bz = pos;
        const x: f32 = @floatFromInt(bx);
        const z: f32 = @floatFromInt(bz);
        // Only the world-space spawn column is shaded.
        @memset(World.data.light_map, 0);
        World.data.light_map[@as(usize, bz) * 512 + bx] = 128;
        particles.spawn_break(.stone, bx, 64, bz);
        particles.update_particles(1.0 / 60.0);
        try std.testing.expectEqual(PerBreak, particles.count);

        for ([_]f32{ 0.0, 1.75, -2.5 }) |camera_offset| {
            var camera = Camera.init(x + camera_offset, 65.5, z - camera_offset);
            particles.rebuild_mesh(&camera);
            try std.testing.expectEqual(PerBreak * verts_per_quad, particles.mesh_data.vertices.items.len);
            for (particles.particles[0..particles.count], 0..) |p, i| {
                const vertices = particles.mesh_data.vertices.items[i * verts_per_quad ..][0..3];
                const expected = [_][3]f32{
                    .{ p.px - HalfSize, p.py - HalfSize, p.pz },
                    .{ p.px + HalfSize, p.py - HalfSize, p.pz },
                    .{ p.px + HalfSize, p.py + HalfSize, p.pz },
                };
                const origin = particles.mesh_origin;
                for (vertices, expected) |vertex, corner| {
                    for (vertex.pos, corner, [3]f32{ origin.x, origin.y, origin.z }) |encoded, world, offset| {
                        const decoded = @as(f32, @floatFromInt(encoded)) / PosScale + offset;
                        try std.testing.expectApproxEqAbs(world, decoded, 0.5 / PosScale);
                    }
                    try std.testing.expectEqual(face_mod.apply_shadow(0xFF999999), vertex.color);
                }
            }
        }

        var camera = Camera.init(x + 512.0, 65.5, z);
        particles.rebuild_mesh(&camera);
        try std.testing.expectEqual(0, particles.mesh_data.vertices.items.len);
        try std.testing.expectEqual(PerBreak, particles.count);
        camera.x = x;
        particles.rebuild_mesh(&camera);
        try std.testing.expectEqual(PerBreak * verts_per_quad, particles.mesh_data.vertices.items.len);

        particles.update_particles(LifetimeMax);
        particles.rebuild_mesh(&camera);
        try std.testing.expectEqual(0, particles.count);
        try std.testing.expectEqual(0, particles.mesh_data.vertices.items.len);
    }
}
