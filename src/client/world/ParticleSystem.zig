const std = @import("std");
const ae = @import("aether");
const Math = ae.Math;
const Rendering = ae.Rendering;

const World = @import("game").World;
const c = @import("common").consts;

const Vertex = @import("../graphics/Vertex.zig").Vertex;
const Camera = @import("../player/Camera.zig");
const TextureAtlas = @import("../graphics/TextureAtlas.zig").TextureAtlas;
const face_mod = @import("chunk/face.zig");
const Face = face_mod.Face;
const collision = @import("../player/collision.zig");

// --- Tunables ---

/// Hard cap on simultaneously alive particles. 6 verts each => 3072 verts.
const MAX_PARTICLES: u16 = 512;
/// Particles emitted per block break (clamped by remaining capacity).
const PER_BREAK: u16 = 48;
/// Particle lifetime range in seconds. Each spawn picks uniformly within
/// this window so a burst doesn't vanish all at once.
const LIFETIME_MIN: f32 = 0.3;
const LIFETIME_MAX: f32 = 1.0;
/// Default downward acceleration in blocks/s^2. Per-particle gravity is set
/// from this at spawn; lightweight materials (leaves, flowers) override it.
const GRAVITY: f32 = 16.0;
const GRAVITY_LEAVES: f32 = 10.0;
/// Half extent of a particle quad in blocks.
const HALF_SIZE: f32 = 0.06;
/// Subdivisions of the broken block's face tile; each particle samples one cell.
const SUBTILE_DIV: i16 = 4;
/// Verts per particle: two triangles (the gfx backend only supports
/// triangles/lines, so quads are expanded just like face.zig:emit_quad).
const VERTS_PER_PARTICLE: u16 = 6;

// --- Vertex/model space ---
//
// ChunkMesh encodes block-local positions as `local * 2048` (i16) and uses
// `Mat4.scaling(16) * translation(world)`. The shader applies SNORM dequant
// (`v / 32768`) before the model matrix, so 1 vertex unit there resolves to
// `2048 / 32768 * 16 = 1` block of world space.
//
// Particles live in absolute world coordinates that change every frame, so
// we can't reuse a per-section translation. Instead we bake world-space
// positions directly into the vertex buffer using a fixed scale factor.
//   v_i16 = round(world * POS_SCALE)
// To make `(v / 32768) * MODEL_SCALE = world`, we need
//   MODEL_SCALE = 32768 / POS_SCALE
// At POS_SCALE = 128 the i16 range covers ~256 blocks (the full Classic
// world) with ~8mm precision -- ample for sub-block sized shards.
const POS_SCALE: f32 = 128.0;
const MODEL_SCALE: f32 = 256.0;

// --- Types ---

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

fn gravity_for(block_id: c.Block) f32 {
    return switch (block_id.id) {
        .leaves => GRAVITY_LEAVES,
        else => GRAVITY,
    };
}

const Self = @This();

mesh: Rendering.Mesh(Vertex),
atlas: TextureAtlas,
particles: [MAX_PARTICLES]Particle,
count: u16,
rng: std.Random.DefaultPrng,
allocator: std.mem.Allocator,

// --- Lifecycle ---

pub fn init(allocator: std.mem.Allocator, pipeline: Rendering.Pipeline.Handle, atlas: TextureAtlas) !Self {
    var self: Self = .{
        .mesh = try Rendering.Mesh(Vertex).new(allocator, pipeline),
        .atlas = atlas,
        .particles = undefined,
        .count = 0,
        // Deterministic seed; "no std.os/std.c" rules out wall-clock seeding.
        .rng = std.Random.DefaultPrng.init(0xC0FFEE),
        .allocator = allocator,
    };
    // Pre-reserve the CPU vertex buffer so per-frame rebuilds don't allocate.
    try self.mesh.vertices.ensureTotalCapacity(
        allocator,
        MAX_PARTICLES * VERTS_PER_PARTICLE,
    );
    return self;
}

pub fn deinit(self: *Self) void {
    self.mesh.deinit(self.allocator);
}

// --- Spawn ---

/// Emit a burst of particles for a block that just got broken.
/// `bx/by/bz` are world block coordinates; `face` selects which atlas tile
/// (top/bottom/side) the shards sample from.
pub fn spawn_break(self: *Self, block_id: c.Block, bx: u16, by: u16, bz: u16, _: Face) void {
    std.debug.assert(!block_id.is_air());

    const face: Face = .x_neg;
    const tile = block_id.face_tile(face);
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

        // Spread spawn positions through most of the block volume (+/-0.45)
        // so the burst visibly fills the cube the player just removed.
        const ox = (rand.float(f32) - 0.5) * 0.9;
        const oy = (rand.float(f32) - 0.5) * 0.9;
        const oz = (rand.float(f32) - 0.5) * 0.9;
        // Velocity = outward from center along the spawn offset, plus a
        // small jitter so neighboring particles don't fly in lockstep.
        // The outward speed scales with offset magnitude (corner spawns fly
        // faster than near-center ones), giving a natural radial burst.
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

// --- Simulation ---

pub fn update(self: *Self, dt: f32) void {
    std.debug.assert(dt >= 0);

    var i: u16 = 0;
    while (i < self.count) {
        const p = &self.particles[i];
        p.life -= dt;
        if (p.life <= 0.0) {
            // Swap-remove: move the last live particle into this slot and
            // re-process the new occupant on the next iteration.
            self.count -= 1;
            self.particles[i] = self.particles[self.count];
            continue;
        }
        p.vy -= p.gravity * dt;
        // Per-axis voxel collision: integrate one axis at a time and revert
        // (zeroing the velocity component) on contact. Treats the particle
        // as a point - its visual extent is much smaller than a block.
        step_axis_x(p, p.vx * dt);
        step_axis_y(p, p.vy * dt);
        step_axis_z(p, p.vz * dt);
        // Kill particles that drift outside the i16-encodable range so
        // encode() doesn't overflow during rendering.
        if (!encodable(p.px) or !encodable(p.py) or !encodable(p.pz)) {
            self.count -= 1;
            self.particles[i] = self.particles[self.count];
            continue;
        }
        i += 1;
    }
}

// Particles spawn inside the block they came from (the local world isn't
// overwritten to Air until the server round-trips the break). To let them
// escape, each axis step only blocks when the destination AABB overlaps a
// solid voxel AND the current AABB doesn't -- i.e. we're trying to enter
// new solid geometry. Particles already embedded in a solid voxel pass
// through freely until they reach open space.
//
// Testing an AABB (instead of the center point) means a particle's center
// stops COLLISION_RADIUS away from any block face. The billboard quad
// extends at most HALF_SIZE per axis from the center, so a radius of
// HALF_SIZE guarantees the quad never clips terrain on any side -- floor,
// ceiling, or walls -- at typical viewing angles.
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
        // Downward Y collision == hit the floor: arrest the whole particle
        // so it sticks where it landed instead of sliding across the
        // surface. Upward collisions only stop vertical motion (lets the
        // particle ricochet sideways off a ceiling).
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

/// True when the axis-aligned box of half-extent COLLISION_RADIUS centered
/// at (wx,wy,wz) overlaps any solid voxel. Out-of-world voxels are treated
/// as non-solid so particles that drift past the edge don't pin to the
/// boundary. HALF_SIZE is small (~0.06), so the box spans at most 2 voxels
/// per axis -- the loop body runs 1-8 times in the worst case.
fn aabb_hits_solid(wx: f32, wy: f32, wz: f32) bool {
    const bx0: i32 = @intFromFloat(@floor(wx - COLLISION_RADIUS));
    const bx1: i32 = @intFromFloat(@floor(wx + COLLISION_RADIUS));
    const by0: i32 = @intFromFloat(@floor(wy - COLLISION_RADIUS));
    const by1: i32 = @intFromFloat(@floor(wy + COLLISION_RADIUS));
    const bz0: i32 = @intFromFloat(@floor(wz - COLLISION_RADIUS));
    const bz1: i32 = @intFromFloat(@floor(wz + COLLISION_RADIUS));

    var bx = bx0;
    while (bx <= bx1) : (bx += 1) {
        if (bx < 0 or bx >= c.WorldLength) continue;
        var by = by0;
        while (by <= by1) : (by += 1) {
            if (by < 0 or by >= c.WorldHeight) continue;
            var bz = bz0;
            while (bz <= bz1) : (bz += 1) {
                if (bz < 0 or bz >= c.WorldDepth) continue;
                const id = World.get_block(@intCast(bx), @intCast(by), @intCast(bz));
                if (collision.block_height(id) > 0.0) return true;
            }
        }
    }
    return false;
}

/// Match chunk/cross-plant shadowing for the voxel containing a particle.
/// Out-of-world positions are treated as sunlit, matching face_sunlit.
fn point_sunlit(wx: f32, wy: f32, wz: f32) bool {
    const bx: i32 = @intFromFloat(@floor(wx));
    const by: i32 = @intFromFloat(@floor(wy));
    const bz: i32 = @intFromFloat(@floor(wz));
    if (bx < 0 or bx >= c.WorldLength) return true;
    if (by < 0 or by >= c.WorldHeight) return true;
    if (bz < 0 or bz >= c.WorldDepth) return true;
    return World.is_sunlit(@intCast(bx), @intCast(by), @intCast(bz));
}

// --- Rendering ---

pub fn draw(self: *Self, camera: *const Camera) void {
    if (self.count == 0) return;

    // Camera basis for billboarding. Right is yaw-only so the quad never
    // rolls when the player tilts; up tilts with pitch so the quad still
    // faces the camera when looking up or down.
    //   forward = (-sin(yaw)*cos(pitch), -sin(pitch), -cos(yaw)*cos(pitch))
    //   right   = ( cos(yaw),            0,           -sin(yaw))
    //   up = right x forward
    //         = (-sin(yaw)*sin(pitch), cos(pitch), -cos(yaw)*sin(pitch))
    const cy = @cos(camera.yaw);
    const sy = @sin(camera.yaw);
    const cp = @cos(camera.pitch);
    const sp = @sin(camera.pitch);
    const rx = cy * HALF_SIZE;
    const rz = -sy * HALF_SIZE;
    const upx = -sy * sp * HALF_SIZE;
    const upy = cp * HALF_SIZE;
    const upz = -cy * sp * HALF_SIZE;

    self.mesh.vertices.clearRetainingCapacity();
    var i: u16 = 0;
    while (i < self.count) : (i += 1) {
        emit_particle(&self.mesh, &self.particles[i], rx, rz, upx, upy, upz);
    }
    self.mesh.update();

    const m = Math.Mat4.scaling(MODEL_SCALE, MODEL_SCALE, MODEL_SCALE);
    self.mesh.draw(&m);
}

/// Append the 6 verts (two triangles) of one billboarded particle quad.
/// `rx`/`rz` is the camera-right vector (XZ only, pre-scaled by HALF_SIZE);
/// `(upx,upy,upz)` is camera-up (pre-scaled). Capacity is reserved in init.
fn emit_particle(
    mesh: *Rendering.Mesh(Vertex),
    p: *const Particle,
    rx: f32,
    rz: f32,
    upx: f32,
    upy: f32,
    upz: f32,
) void {
    // Corners of the quad in world space, CCW from the camera:
    //   v0 bottom-left  (-r - up)
    //   v1 bottom-right ( r - up)
    //   v2 top-right    ( r + up)
    //   v3 top-left     (-r + up)
    // Shards render a touch darker than full-bright block faces so they read
    // as debris rather than bright specks against the broken voxel.
    const base: u32 = 0xFF999999;
    const color: u32 = if (point_sunlit(p.px, p.py, p.pz)) base else face_mod.apply_shadow(base);

    const v0 = make_vertex(p.px - rx - upx, p.py - upy, p.pz - rz - upz, p.u0, p.v1, color);
    const v1 = make_vertex(p.px + rx - upx, p.py - upy, p.pz + rz - upz, p.u1, p.v1, color);
    const v2 = make_vertex(p.px + rx + upx, p.py + upy, p.pz + rz + upz, p.u1, p.v0, color);
    const v3 = make_vertex(p.px - rx + upx, p.py + upy, p.pz - rz + upz, p.u0, p.v0, color);

    mesh.vertices.appendAssumeCapacity(v0);
    mesh.vertices.appendAssumeCapacity(v1);
    mesh.vertices.appendAssumeCapacity(v2);
    mesh.vertices.appendAssumeCapacity(v0);
    mesh.vertices.appendAssumeCapacity(v2);
    mesh.vertices.appendAssumeCapacity(v3);
}

fn make_vertex(wx: f32, wy: f32, wz: f32, u: i16, v: i16, color: u32) Vertex {
    return .{
        .pos = .{ encode(wx), encode(wy), encode(wz) },
        .uv = .{ u, v },
        .color = color,
    };
}

/// True when the world coordinate - plus billboard offsets - can be
/// losslessly encoded into an i16.  The billboard corners are at most
/// 2 * HALF_SIZE away from the particle center on any axis, so we
/// shrink the safe window by that margin.
fn encodable(world: f32) bool {
    const margin = 2.0 * HALF_SIZE * POS_SCALE; // billboard corner offset in scaled units
    const scaled = @round(world * POS_SCALE);
    return scaled >= -32768.0 + margin and scaled <= 32767.0 - margin;
}

fn encode(world: f32) i16 {
    return @intFromFloat(@round(world * POS_SCALE));
}
