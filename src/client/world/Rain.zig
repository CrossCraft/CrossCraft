const std = @import("std");
const assert = std.debug.assert;
const ae = @import("aether");
const caps = @import("capabilities").ClientType(ae);
const Math = ae.Math;
const Rendering = ae.Rendering;

const core = @import("core");
const World = core.World;

const Vertex = @import("aether").Rendering.Vertex;
const Colors = @import("../graphics/Color.zig");
const Color = Colors.Color;
const Camera = @import("../player/Camera.zig");
const TextureAtlas = @import("../graphics/TextureAtlas.zig").TextureAtlas;
const Options = @import("../Options.zig");

const Extent: i32 = 4;
const ExtentU: u32 = @intCast(Extent);
const ExtentF: f32 = @floatFromInt(Extent);

// Sections keep their dense V span representable as positive SNORM16.
const SectionHeight: f32 = 8.0;
const VPerBlockF: f32 = 4000.0;
const SectionVDiff: i32 = @intFromFloat(SectionHeight * VPerBlockF);
comptime {
    assert(SectionVDiff > 0 and SectionVDiff <= 32767);
}
const FallSpeed: i32 = @intFromFloat(12.0 * VPerBlockF);
const StreakWidth: f32 = 1.0;
const StreakHalf: f32 = StreakWidth * 0.5;
const USpan: i32 = @intFromFloat(32767.0 * StreakWidth);
const BaseAlpha: f32 = 255.0;

const SplashMax: u16 = 192;
const SplashSpawnsPerSec: f32 = caps.render.rain_splashes_per_second;
const SplashGravity: f32 = 12.0;
const SplashLifeMin: f32 = 0.25;
const SplashLifeMax: f32 = 0.55;
const SplashHalfSize: f32 = 0.12;
// Must exceed the collision radius to avoid an immediate floor hit.
const SplashSpawnOffset: f32 = 0.18;

const ParticleAtlasTiles: u32 = 16;
const DropTileCol: u32 = 0;
const DropTileRow: u32 = 1;

// Shared with ParticleSystem; meshes remain camera-local to fit i16.
const PosScale: f32 = 128.0;
const ModelScale: f32 = 256.0;

const QuadsPerSection: u32 = 2;
const ColumnsDiam: u32 = 2 * ExtentU + 1;
const MaxColumns: u32 = ColumnsDiam * ColumnsDiam;
const SplashMaxQuads: u32 = @as(u32, SplashMax);

fn streak_max_quads() u32 {
    const base: u32 = @intFromFloat(@ceil(@as(f32, @floatFromInt(World.data.dims.height)) / SectionHeight));
    return MaxColumns * (base * 2) * QuadsPerSection;
}

const Splash = struct {
    px: f32,
    py: f32,
    pz: f32,
    vx: f32,
    vy: f32,
    vz: f32,
    life: f32,
};

const Rain = @This();

streak_data: Rendering.MeshDataType(Vertex),
streak_mesh: Rendering.MeshType(Vertex),
splash_data: Rendering.MeshDataType(Vertex),
splash_mesh: Rendering.MeshType(Vertex),
splash_origin: Math.Vec3,
particle_atlas: TextureAtlas,
scroll_v: i32,
streak_mesh_dirty: bool,
streak_cam_tile_x: i32,
streak_cam_tile_z: i32,
spawn_accum: f32,
splashes: [SplashMax]Splash,
splash_count: u16,
rng: std.Random.DefaultPrng,
allocator: std.mem.Allocator,

pub fn init(allocator: std.mem.Allocator) !Rain {
    var self: Rain = .{
        .streak_data = try Rendering.MeshDataType(Vertex).init(allocator),
        .streak_mesh = try Rendering.MeshType(Vertex).init(&.{}),
        .splash_data = try Rendering.MeshDataType(Vertex).init(allocator),
        .splash_mesh = try Rendering.MeshType(Vertex).init(&.{}),
        .splash_origin = Math.Vec3.zero(),
        .particle_atlas = TextureAtlas.init(ParticleAtlasTiles, ParticleAtlasTiles),
        .scroll_v = 0,
        .streak_mesh_dirty = true,
        .streak_cam_tile_x = 0,
        .streak_cam_tile_z = 0,
        .spawn_accum = 0,
        .splashes = undefined,
        .splash_count = 0,
        .rng = std.Random.DefaultPrng.init(0xDA1ADA1ADA1ADA1A),
        .allocator = allocator,
    };
    try self.streak_data.ensure_quad_capacity(allocator, streak_max_quads());
    try self.splash_data.ensure_quad_capacity(allocator, SplashMaxQuads);
    return self;
}

pub fn deinit(self: *Rain) void {
    self.streak_mesh.deinit();
    self.streak_data.deinit(self.allocator);
    self.splash_mesh.deinit();
    self.splash_data.deinit(self.allocator);
    self.* = undefined;
}

pub fn mark_dirty(self: *Rain) void {
    self.streak_mesh_dirty = true;
}

pub fn update(self: *Rain, dt: f32, camera: *const Camera) void {
    if (!Options.current.rain) {
        self.splash_count = 0;
        self.spawn_accum = 0;
        return;
    }

    const dv: i32 = @intFromFloat(@as(f32, @floatFromInt(FallSpeed)) * dt);
    self.scroll_v +%= dv;

    self.update_splashes(dt);

    self.spawn_accum += dt * SplashSpawnsPerSec;
    while (self.spawn_accum >= 1.0) {
        self.spawn_accum -= 1.0;
        if (self.splash_count >= SplashMax) break;
        self.maybe_spawn_splash(camera);
    }
    if (self.spawn_accum > 64.0) self.spawn_accum = 0;

    self.rebuild_streak_mesh(camera);
    self.rebuild_splash_mesh(camera);
    if (self.splash_data.vertices.items.len != 0) self.splash_mesh.update(&self.splash_data);
}

fn update_splashes(self: *Rain, dt: f32) void {
    var i: u16 = 0;
    while (i < self.splash_count) {
        const p = &self.splashes[i];
        p.life -= dt;
        if (p.life <= 0.0) {
            self.splash_count -= 1;
            self.splashes[i] = self.splashes[self.splash_count];
            continue;
        }
        p.vy -= SplashGravity * dt;
        const nx = p.px + p.vx * dt;
        const ny = p.py + p.vy * dt;
        const nz = p.pz + p.vz * dt;
        if (out_of_world(nx, ny, nz) or aabb_hits_solid(nx, ny, nz)) {
            self.splash_count -= 1;
            self.splashes[i] = self.splashes[self.splash_count];
            continue;
        }
        p.px = nx;
        p.py = ny;
        p.pz = nz;
        i += 1;
    }
}

fn maybe_spawn_splash(self: *Rain, camera: *const Camera) void {
    var rand = self.rng.random();
    const cam_tile_x: i32 = @intFromFloat(@floor(camera.x));
    const cam_tile_z: i32 = @intFromFloat(@floor(camera.z));
    const dx = @as(i32, @intCast(rand.intRangeLessThan(u32, 0, ColumnsDiam))) - Extent;
    const dz = @as(i32, @intCast(rand.intRangeLessThan(u32, 0, ColumnsDiam))) - Extent;
    const gx = cam_tile_x + dx;
    const gz = cam_tile_z + dz;
    if (gx < 0 or gx >= World.data.dims.length) return;
    if (gz < 0 or gz >= World.data.dims.depth) return;

    const surface: i32 = rain_surface_at(gx, gz);
    if (surface <= 0 or surface >= World.data.dims.height) return;
    if (camera.y < @as(f32, @floatFromInt(surface))) return;

    self.splashes[self.splash_count] = .{
        .px = @as(f32, @floatFromInt(gx)) + rand.float(f32),
        .py = @as(f32, @floatFromInt(surface)) + SplashSpawnOffset,
        .pz = @as(f32, @floatFromInt(gz)) + rand.float(f32),
        .vx = (rand.float(f32) - 0.5) * 4.0,
        .vy = 2.0 + rand.float(f32) * 2.5,
        .vz = (rand.float(f32) - 0.5) * 4.0,
        .life = SplashLifeMin + rand.float(f32) * (SplashLifeMax - SplashLifeMin),
    };
    self.splash_count += 1;
}

/// Caller must bind rain.png.
pub fn draw_streaks(self: *Rain, camera: *const Camera) void {
    if (!Options.current.rain) return;
    const cam_tile_x_i: i32 = @intFromFloat(@floor(camera.x));
    const cam_tile_z_i: i32 = @intFromFloat(@floor(camera.z));
    if (self.streak_data.vertices.items.len == 0) return;

    const cam_tile_x: f32 = @floatFromInt(cam_tile_x_i);
    const cam_tile_z: f32 = @floatFromInt(cam_tile_z_i);

    Rendering.gfx.api.set_alpha_blend(true);
    Rendering.gfx.api.set_depth_write(false);
    defer Rendering.gfx.api.set_depth_write(true);

    Rendering.gfx.api.set_clip_planes(true);
    defer Rendering.gfx.api.set_clip_planes(false);

    Rendering.gfx.api.set_culling(false);
    defer Rendering.gfx.api.set_culling(true);

    Rendering.gfx.api.set_uv_offset(0.0, @as(f32, @floatFromInt(@mod(self.scroll_v, 32768))) / 32768.0);
    defer Rendering.gfx.api.set_uv_offset(0.0, 0.0);

    const m = Math.Mat4.scaling(ModelScale, ModelScale, ModelScale)
        .mul(Math.Mat4.translation(cam_tile_x, 0, cam_tile_z));
    self.streak_mesh.draw(&m);
}

/// Caller must bind particles.png.
pub fn draw_splashes(self: *Rain) void {
    if (!Options.current.rain) return;
    if (self.splash_data.vertices.items.len == 0) return;

    Rendering.gfx.api.set_alpha_blend(true);
    Rendering.gfx.api.set_depth_write(true);
    Rendering.gfx.api.set_culling(false);
    defer Rendering.gfx.api.set_culling(true);

    Rendering.gfx.api.set_uv_offset(0.0, 0.0);
    const m = Math.Mat4.scaling(ModelScale, ModelScale, ModelScale)
        .mul(Math.Mat4.translation(self.splash_origin.x, self.splash_origin.y, self.splash_origin.z));
    self.splash_mesh.draw(&m);
}

fn rebuild_streak_mesh(self: *Rain, camera: *const Camera) void {
    const cam_tile_x_i: i32 = @intFromFloat(@floor(camera.x));
    const cam_tile_z_i: i32 = @intFromFloat(@floor(camera.z));
    if (!self.streak_mesh_dirty and
        cam_tile_x_i == self.streak_cam_tile_x and
        cam_tile_z_i == self.streak_cam_tile_z)
    {
        return;
    }

    self.streak_data.clear_retaining_capacity();
    build_streaks(&self.streak_data, cam_tile_x_i, cam_tile_z_i);
    self.streak_mesh.update(&self.streak_data);
    self.streak_cam_tile_x = cam_tile_x_i;
    self.streak_cam_tile_z = cam_tile_z_i;
    self.streak_mesh_dirty = false;
}

fn rebuild_splash_mesh(self: *Rain, camera: *const Camera) void {
    self.splash_data.clear_retaining_capacity();
    self.splash_origin = Math.Vec3.new(@floor(camera.x), @floor(camera.y), @floor(camera.z));
    if (self.splash_count == 0) return;

    const cy = @cos(camera.yaw);
    const sy = @sin(camera.yaw);
    const cp = @cos(camera.pitch);
    const sp = @sin(camera.pitch);
    const rx = cy * SplashHalfSize;
    const rz = -sy * SplashHalfSize;
    const upx = -sy * sp * SplashHalfSize;
    const upy = cp * SplashHalfSize;
    const upz = -cy * sp * SplashHalfSize;

    const tu0 = self.particle_atlas.tile_u(DropTileCol);
    const tv0 = self.particle_atlas.tile_v(DropTileRow);
    const tu1 = tu0 + self.particle_atlas.tile_width();
    const tv1 = tv0 + self.particle_atlas.tile_height();
    const color: u32 = @bitCast(Color.rgba(180, 180, 220, 255));

    var i: u16 = 0;
    while (i < self.splash_count) : (i += 1) {
        emit_splash(&self.splash_data, &self.splashes[i], self.splash_origin, rx, rz, upx, upy, upz, tu0, tv0, tu1, tv1, color);
    }
}

fn build_streaks(mesh: *Rendering.MeshDataType(Vertex), cam_tile_x: i32, cam_tile_z: i32) void {
    const world_ceiling: f32 = @as(f32, @floatFromInt(World.data.dims.height));

    var dz: i32 = -Extent;
    while (dz <= Extent) : (dz += 1) {
        var dx: i32 = -Extent;
        while (dx <= Extent) : (dx += 1) {
            const gx = cam_tile_x + dx;
            const gz = cam_tile_z + dz;
            if (gx < 0 or gx >= World.data.dims.length) continue;
            if (gz < 0 or gz >= World.data.dims.depth) continue;

            const surface_i: i32 = rain_surface_at(gx, gz);
            if (surface_i >= World.data.dims.height) continue;
            const surface_f: f32 = @as(f32, @floatFromInt(surface_i));
            if (world_ceiling <= surface_f) continue;

            const dist_sq: f32 = @as(f32, @floatFromInt(dx * dx + dz * dz));
            const dist: f32 = @sqrt(dist_sq);
            const fade = @max(0.0, 1.0 - dist / ExtentF);
            if (fade <= 0.0) continue;
            const alpha_byte: u8 = @intFromFloat(fade * BaseAlpha);
            const color: u32 = @bitCast(Color.rgba(255, 255, 255, alpha_byte));

            emit_column_quads(mesh, dx, dz, surface_f, world_ceiling, color);
        }
    }
}

// Split sections at SNORM16 wrap points so interpolated V stays monotonic.
fn emit_column_quads(
    mesh: *Rendering.MeshDataType(Vertex),
    dx: i32,
    dz: i32,
    bottom_y: f32,
    top_y: f32,
    color: u32,
) void {
    const fx: f32 = @floatFromInt(dx);
    const fz: f32 = @floatFromInt(dz);
    const x_ctr = fx + 0.5;
    const z_ctr = fz + 0.5;

    var section_bottom: f32 = bottom_y;
    while (section_bottom < top_y) {
        const section_top: f32 = @min(section_bottom + SectionHeight, top_y);
        const section_h: f32 = section_top - section_bottom;
        if (section_h <= 0.0) break;
        const section_diff: i32 = @intFromFloat(@round(section_h * VPerBlockF));
        assert(section_diff >= 0 and section_diff <= 32767);

        const v_bot_raw: i32 = @intFromFloat(@round(section_bottom * VPerBlockF));
        const v_bot_mod: i32 = @mod(v_bot_raw, 32768);
        const v_top_from_bot: i32 = v_bot_mod + section_diff;

        if (v_top_from_bot <= 32767) {
            emit_section_geom(
                mesh,
                x_ctr,
                z_ctr,
                section_bottom,
                section_top,
                @intCast(v_bot_mod),
                @intCast(v_top_from_bot),
                color,
            );
        } else {
            const wrap_offset: f32 = @floatFromInt(32768 - v_bot_mod);
            const section_diff_f: f32 = @floatFromInt(section_diff);
            const wrap_y: f32 = section_bottom + (wrap_offset / section_diff_f) * section_h;

            emit_section_geom(
                mesh,
                x_ctr,
                z_ctr,
                section_bottom,
                wrap_y,
                @intCast(v_bot_mod),
                32767,
                color,
            );
            emit_section_geom(
                mesh,
                x_ctr,
                z_ctr,
                wrap_y,
                section_top,
                0,
                @intCast(v_top_from_bot - 32768),
                color,
            );
        }

        section_bottom = section_top;
    }
}

fn emit_section_geom(
    mesh: *Rendering.MeshDataType(Vertex),
    x_ctr: f32,
    z_ctr: f32,
    y_bot: f32,
    y_top: f32,
    v_bot: i16,
    v_top: i16,
    color: u32,
) void {
    const x_lo = x_ctr - StreakHalf;
    const x_hi = x_ctr + StreakHalf;
    const z_lo = z_ctr - StreakHalf;
    const z_hi = z_ctr + StreakHalf;
    const u_left: i16 = 0;
    const u_right: i16 = @intCast(USpan);

    const by = encode(y_bot);
    const ty = encode(y_top);
    const uvs: [4][2]i16 = .{
        .{ u_left, v_bot },
        .{ u_right, v_bot },
        .{ u_right, v_top },
        .{ u_left, v_top },
    };

    emit_quad(mesh, .{
        .{ encode(x_lo), by, encode(z_lo) },
        .{ encode(x_hi), by, encode(z_hi) },
        .{ encode(x_hi), ty, encode(z_hi) },
        .{ encode(x_lo), ty, encode(z_lo) },
    }, uvs, color);

    emit_quad(mesh, .{
        .{ encode(x_lo), by, encode(z_hi) },
        .{ encode(x_hi), by, encode(z_lo) },
        .{ encode(x_hi), ty, encode(z_lo) },
        .{ encode(x_lo), ty, encode(z_hi) },
    }, uvs, color);
}

fn emit_quad(
    mesh: *Rendering.MeshDataType(Vertex),
    positions: [4][3]i16,
    uvs: [4][2]i16,
    color: u32,
) void {
    var vertices: [4]Vertex = undefined;
    inline for (&vertices, positions, uvs) |*vertex, pos, uv| {
        vertex.* = .{ .pos = pos, .uv = uv, .color = color };
    }
    mesh.add_quad_assume_capacity(vertices[0], vertices[1], vertices[2], vertices[3]);
}

fn emit_splash(
    mesh: *Rendering.MeshDataType(Vertex),
    p: *const Splash,
    origin: Math.Vec3,
    rx: f32,
    rz: f32,
    upx: f32,
    upy: f32,
    upz: f32,
    tu0: i16,
    tv0: i16,
    tu1: i16,
    tv1: i16,
    color: u32,
) void {
    const px = p.px - origin.x;
    const py = p.py - origin.y;
    const pz = p.pz - origin.z;
    const limit = 32767.0 / PosScale - 2.0 * SplashHalfSize;
    if (@abs(px) > limit or @abs(py) > limit or @abs(pz) > limit) return;

    const bl: Vertex = .{ .pos = .{ encode(px - rx - upx), encode(py - upy), encode(pz - rz - upz) }, .uv = .{ tu0, tv1 }, .color = color };
    const br: Vertex = .{ .pos = .{ encode(px + rx - upx), encode(py - upy), encode(pz + rz - upz) }, .uv = .{ tu1, tv1 }, .color = color };
    const tr: Vertex = .{ .pos = .{ encode(px + rx + upx), encode(py + upy), encode(pz + rz + upz) }, .uv = .{ tu1, tv0 }, .color = color };
    const tl: Vertex = .{ .pos = .{ encode(px - rx + upx), encode(py + upy), encode(pz - rz + upz) }, .uv = .{ tu0, tv0 }, .color = color };
    mesh.add_quad_assume_capacity(bl, br, tr, tl);
}

fn encode(world: f32) i16 {
    const scaled = @round(world * PosScale);
    const clamped = @max(-32768.0, @min(32767.0, scaled));
    return @intFromFloat(clamped);
}

fn light_map_at(x: i32, z: i32) i32 {
    assert(x >= 0 and x < World.data.dims.length);
    assert(z >= 0 and z < World.data.dims.depth);
    const idx: u32 = @intCast(z * @as(i32, @intCast(World.data.dims.length)) + x);
    return @intCast(World.data.light_map[idx]);
}

// Leaves and glass stop rain despite not appearing in the light map.
fn rain_surface_at(x: i32, z: i32) i32 {
    const light_surface: i32 = light_map_at(x, z);
    var y: i32 = @as(i32, @intCast(World.data.dims.height)) - 1;
    while (y >= light_surface) : (y -= 1) {
        const id = World.data.get_block(@intCast(x), @intCast(y), @intCast(z));
        if (id.collision_height() > 0.0) return y + 1;
    }
    return light_surface;
}

fn out_of_world(wx: f32, wy: f32, wz: f32) bool {
    if (wy < 0.0 or wy >= @as(f32, @floatFromInt(World.data.dims.height))) return true;
    if (wx < 0.0 or wx >= @as(f32, @floatFromInt(World.data.dims.length))) return true;
    if (wz < 0.0 or wz >= @as(f32, @floatFromInt(World.data.dims.depth))) return true;
    return false;
}

fn aabb_hits_solid(wx: f32, wy: f32, wz: f32) bool {
    const r: f32 = SplashHalfSize;
    const bx0: i32 = @intFromFloat(@floor(wx - r));
    const bx1: i32 = @intFromFloat(@floor(wx + r));
    const by0: i32 = @intFromFloat(@floor(wy - r));
    const by1: i32 = @intFromFloat(@floor(wy + r));
    const bz0: i32 = @intFromFloat(@floor(wz - r));
    const bz1: i32 = @intFromFloat(@floor(wz + r));
    var bx = bx0;
    while (bx <= bx1) : (bx += 1) {
        if (bx < 0 or bx >= World.data.dims.length) continue;
        var by = by0;
        while (by <= by1) : (by += 1) {
            if (by < 0 or by >= World.data.dims.height) continue;
            var bz = bz0;
            while (bz <= bz1) : (bz += 1) {
                if (bz < 0 or bz >= World.data.dims.depth) continue;
                const id = World.data.get_block(@intCast(bx), @intCast(by), @intCast(bz));
                if (id.collision_height() > 0.0) return true;
            }
        }
    }
    return false;
}

test "rain splash particles retain their shape across 512 block worlds" {
    const allocator = std.testing.allocator;
    try World.data.init_in_place(allocator, core.world_dims.WorldDims.init(512, 128, 512), 0);
    defer World.data.deinit();

    // Initialize only the state used by CPU splash simulation and meshing.
    var rain: Rain = undefined;
    rain.splash_data = try Rendering.MeshDataType(Vertex).init(allocator);
    defer rain.splash_data.deinit(allocator);

    try rain.splash_data.ensure_quad_capacity(allocator, 1);
    rain.particle_atlas = TextureAtlas.init(ParticleAtlasTiles, ParticleAtlasTiles);

    const positions = [_][2]f32{ .{ 0, 0 }, .{ 255, 255 }, .{ 256, 32 }, .{ 32, 256 }, .{ 256, 256 }, .{ 511, 511 } };
    const verts_per_quad: usize = if (Rendering.mesh.indexing_enabled) 4 else 6;
    for (positions) |pos| {
        const x, const z = pos;
        rain.splash_count = 1;
        rain.splashes[0] = .{ .px = x + 0.5, .py = 64.5, .pz = z + 0.5, .vx = 0, .vy = 2, .vz = 0, .life = 0.5 };
        rain.update_splashes(1.0 / 60.0);
        try std.testing.expectEqual(1, rain.splash_count);
        const p = rain.splashes[0];
        for ([_]f32{ 0.0, 1.75, -2.5 }) |camera_offset| {
            const camera = Camera.init(x + camera_offset, 65.5, z - camera_offset);
            rain.rebuild_splash_mesh(&camera);
            try std.testing.expectEqual(verts_per_quad, rain.splash_data.vertices.items.len);
            const expected = [_][3]f32{
                .{ p.px - SplashHalfSize, p.py - SplashHalfSize, p.pz },
                .{ p.px + SplashHalfSize, p.py - SplashHalfSize, p.pz },
                .{ p.px + SplashHalfSize, p.py + SplashHalfSize, p.pz },
            };
            const origin = rain.splash_origin;
            for (rain.splash_data.vertices.items[0..3], expected) |vertex, corner| {
                for (vertex.pos, corner, [3]f32{ origin.x, origin.y, origin.z }) |encoded, world, offset| {
                    const decoded = @as(f32, @floatFromInt(encoded)) / PosScale + offset;
                    try std.testing.expectApproxEqAbs(world, decoded, 0.5 / PosScale);
                }
            }
        }

        var camera = Camera.init(x + 512.0, 65.5, z);
        rain.rebuild_splash_mesh(&camera);
        try std.testing.expectEqual(0, rain.splash_data.vertices.items.len);
        try std.testing.expectEqual(1, rain.splash_count);
        camera.x = x;
        rain.rebuild_splash_mesh(&camera);
        try std.testing.expectEqual(verts_per_quad, rain.splash_data.vertices.items.len);
    }
}
