const std = @import("std");
const ae = @import("aether");
const Math = ae.Math;
const Rendering = ae.Rendering;

const core = @import("core");
const World = core.World;

const Vertex = @import("aether").Rendering.Vertex;
const Camera = @import("../player/Camera.zig");
const TextureAtlas = @import("../graphics/TextureAtlas.zig").TextureAtlas;
const face_mod = @import("chunk/face.zig");
const collision = @import("../player/collision.zig");
const Block = core.blocks.Block;

const MAX_PARTICLES: u16 = 512;
const PER_BREAK: u16 = 48;
const LIFETIME_MIN: f32 = 0.3;
const LIFETIME_MAX: f32 = 1.0;
const GRAVITY: f32 = 16.0;
const GRAVITY_LEAVES: f32 = 10.0;
const HALF_SIZE: f32 = 0.06;
const SUBTILE_DIV: i16 = 4;

// Bake moving world positions into SNORM16: 128 vertex units per block,
// then restore world units with a 256x model scale.
const POS_SCALE: f32 = 128.0;
const MODEL_SCALE: f32 = 256.0;

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
        .leaves => GRAVITY_LEAVES,
        else => GRAVITY,
    };
}

const Self = @This();

mesh_data: Rendering.MeshDataType(Vertex),
mesh: Rendering.MeshType(Vertex),
atlas: TextureAtlas,
particles: [MAX_PARTICLES]Particle,
count: u16,
rng: std.Random.DefaultPrng,
allocator: std.mem.Allocator,

pub fn init(allocator: std.mem.Allocator, atlas: TextureAtlas) !Self {
    var self: Self = .{
        .mesh_data = try Rendering.MeshDataType(Vertex).init(allocator),
        .mesh = try Rendering.MeshType(Vertex).init(&.{}),
        .atlas = atlas,
        .particles = undefined,
        .count = 0,
        .rng = std.Random.DefaultPrng.init(0xC0FFEE),
        .allocator = allocator,
    };
    try self.mesh_data.ensure_quad_capacity(allocator, MAX_PARTICLES);
    return self;
}

pub fn deinit(self: *Self) void {
    self.mesh.deinit();
    self.mesh_data.deinit(self.allocator);
}

pub fn spawn_break(self: *Self, block_id: Block, bx: u16, by: u16, bz: u16) void {
    std.debug.assert(!block_id.is_air());

    const tile = block_id.face_tile(.x_neg);
    const tu = self.atlas.tileU(tile.col);
    const tv = self.atlas.tileV(tile.row);
    const tw = self.atlas.tileWidth();
    const th = self.atlas.tileHeight();
    const du: i16 = @divTrunc(tw, SUBTILE_DIV);
    const dv: i16 = @divTrunc(th, SUBTILE_DIV);

    const cx: f32 = @as(f32, @floatFromInt(bx)) + 0.5;
    const cy: f32 = @as(f32, @floatFromInt(by)) + 0.5;
    const cz: f32 = @as(f32, @floatFromInt(bz)) + 0.5;

    var rand = self.rng.random();
    const gravity = gravity_for(block_id);

    var i: u16 = 0;
    while (i < PER_BREAK) : (i += 1) {
        if (self.count >= MAX_PARTICLES) break;

        const sx: i16 = @intCast(rand.intRangeLessThan(u8, 0, @intCast(SUBTILE_DIV)));
        const sy: i16 = @intCast(rand.intRangeLessThan(u8, 0, @intCast(SUBTILE_DIV)));

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
            .life = LIFETIME_MIN + rand.float(f32) * (LIFETIME_MAX - LIFETIME_MIN),
            .gravity = gravity,
        };
        self.count += 1;
    }
}

pub fn update(self: *Self, dt: f32, camera: *const Camera) void {
    std.debug.assert(dt >= 0);

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
        if (!encodable(p.px) or !encodable(p.py) or !encodable(p.pz)) {
            self.count -= 1;
            self.particles[i] = self.particles[self.count];
            continue;
        }
        i += 1;
    }

    self.rebuild_mesh(camera);
}

// Only block entry into new solid geometry: particles initially spawn before
// the server's air update has round-tripped to the client.
const COLLISION_RADIUS: f32 = HALF_SIZE;

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
    const bx0: i32 = @intFromFloat(@floor(wx - COLLISION_RADIUS));
    const bx1: i32 = @intFromFloat(@floor(wx + COLLISION_RADIUS));
    const by0: i32 = @intFromFloat(@floor(wy - COLLISION_RADIUS));
    const by1: i32 = @intFromFloat(@floor(wy + COLLISION_RADIUS));
    const bz0: i32 = @intFromFloat(@floor(wz - COLLISION_RADIUS));
    const bz1: i32 = @intFromFloat(@floor(wz + COLLISION_RADIUS));

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
                if (collision.block_height(id) > 0.0) return true;
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

pub fn draw(self: *Self) void {
    if (self.count == 0) return;
    const m = Math.Mat4.scaling(MODEL_SCALE, MODEL_SCALE, MODEL_SCALE);
    self.mesh.draw(&m);
}

fn rebuild_mesh(self: *Self, camera: *const Camera) void {
    self.mesh_data.clear_retaining_capacity();
    if (self.count == 0) return;

    // Yaw-only right vector prevents roll; pitched up vector faces the camera.
    const cy = @cos(camera.yaw);
    const sy = @sin(camera.yaw);
    const cp = @cos(camera.pitch);
    const sp = @sin(camera.pitch);
    const rx = cy * HALF_SIZE;
    const rz = -sy * HALF_SIZE;
    const upx = -sy * sp * HALF_SIZE;
    const upy = cp * HALF_SIZE;
    const upz = -cy * sp * HALF_SIZE;

    var i: u16 = 0;
    while (i < self.count) : (i += 1) {
        emit_particle(&self.mesh_data, &self.particles[i], rx, rz, upx, upy, upz);
    }
    self.mesh.update(&self.mesh_data);
}

fn emit_particle(
    mesh: *Rendering.MeshDataType(Vertex),
    p: *const Particle,
    rx: f32,
    rz: f32,
    upx: f32,
    upy: f32,
    upz: f32,
) void {
    const base: u32 = 0xFF999999;
    const color: u32 = if (point_sunlit(p.px, p.py, p.pz)) base else face_mod.apply_shadow(base);

    const v0 = make_vertex(p.px - rx - upx, p.py - upy, p.pz - rz - upz, p.u0, p.v1, color);
    const v1 = make_vertex(p.px + rx - upx, p.py - upy, p.pz + rz - upz, p.u1, p.v1, color);
    const v2 = make_vertex(p.px + rx + upx, p.py + upy, p.pz + rz + upz, p.u1, p.v0, color);
    const v3 = make_vertex(p.px - rx + upx, p.py + upy, p.pz - rz + upz, p.u0, p.v0, color);

    mesh.add_quad_assume_capacity(v0, v1, v2, v3);
}

fn make_vertex(wx: f32, wy: f32, wz: f32, u: i16, v: i16, color: u32) Vertex {
    return .{
        .pos = .{ encode(wx), encode(wy), encode(wz) },
        .uv = .{ u, v },
        .color = color,
    };
}

fn encodable(world: f32) bool {
    const margin = 2.0 * HALF_SIZE * POS_SCALE;
    const scaled = @round(world * POS_SCALE);
    return scaled >= -32768.0 + margin and scaled <= 32767.0 - margin;
}

fn encode(world: f32) i16 {
    return @intFromFloat(@round(world * POS_SCALE));
}
