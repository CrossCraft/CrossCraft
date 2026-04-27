const std = @import("std");
const ae = @import("aether");
const Math = ae.Math;
const Rendering = ae.Rendering;

const World = @import("game").World;
const c = @import("common").consts;

const Vertex = @import("../graphics/Vertex.zig").Vertex;
const Color = @import("../graphics/Color.zig").Color;
const Camera = @import("../player/Camera.zig");
const TextureAtlas = @import("../graphics/TextureAtlas.zig").TextureAtlas;
const Options = @import("../Options.zig");
const collision = @import("../player/collision.zig");

// --- Tunables ---

/// Half-extent of the rain column grid in blocks.  Grid is (2*EXTENT+1)^2.
/// PSP halves the grid radius to drop the streak column count from 81 to 25
/// (5x5 vs 9x9), keeping the streak mesh build + fill in budget.
const EXTENT: i32 = if (ae.platform == .psp) 2 else 4;
const EXTENT_U: u32 = @intCast(EXTENT);
const EXTENT_F: f32 = @floatFromInt(EXTENT);

/// Streak extends from camera.y - RAIN_BELOW up to camera.y + RAIN_ABOVE,
/// clipped against surface and world ceiling.  PSP uses a shorter overhead
/// span so fewer vertical sections fit inside the PSP 4096 virtual viewport
/// after MODEL_SCALE, keeping per-frame vertex counts manageable.
const RAIN_BELOW: f32 = 6.0;
const RAIN_ABOVE: f32 = if (ae.platform == .psp) 4.0 else 16.0;
/// Streak is cut into SECTION_HEIGHT-tall quad slices stacked vertically so
/// V_PER_BLOCK can be much larger than a single i16 would allow across the
/// full streak, giving a proper drop density instead of ~1 repeat per 30
/// blocks.  Each section covers close to one texture repeat and tiles
/// seamlessly into its neighbors via SNORM16 wrap.
const SECTION_HEIGHT: f32 = 8.0;
const V_PER_BLOCK_F: f32 = 4000.0;
/// Per-section V delta must fit signed i16.  SECTION_HEIGHT * V_PER_BLOCK_F
/// = 32000 which sits safely inside [0, 32767].
const SECTION_V_DIFF: i32 = @intFromFloat(SECTION_HEIGHT * V_PER_BLOCK_F);
comptime {
    std.debug.assert(SECTION_V_DIFF > 0 and SECTION_V_DIFF <= 32767);
}
/// V scroll rate (SNORM16 units per second).  FALL_SPEED / V_PER_BLOCK_F
/// is the visual fall speed in blocks/second.
const FALL_SPEED: i32 = @intFromFloat(12.0 * V_PER_BLOCK_F);
/// Streak plane width in world blocks.  Two X-shaped crossed planes per
/// column already double up at every viewing angle, so keep width ~1
/// block so drop pixels aren't smeared across extra world space.
const STREAK_WIDTH: f32 = 1.0;
/// Horizontal half-offset: plane spans [cx - STREAK_HALF, cx + STREAK_HALF]
/// around each column's center (so total width = STREAK_WIDTH).
const STREAK_HALF: f32 = STREAK_WIDTH * 0.5;
/// SNORM16 U units across the streak width.  Chosen proportional to
/// STREAK_WIDTH so drop aspect stays consistent regardless of how wide the
/// quad extends.  Full SNORM16 range (32767) shows the whole texture's
/// horizontal extent across the quad -- larger U range compresses more
/// drop pixels into the same world distance, giving thinner drops.
const U_SPAN: i32 = @intFromFloat(32767.0 * STREAK_WIDTH);
/// Peak alpha at grid center (out of 255).  Held at full 255 so drop
/// pixels from rain.png render at their texture-native alpha -- anything
/// less multiplies every pixel's alpha down and lets semi-transparent
/// between-drop pixels pass the 0.1 discard threshold as a gray wash,
/// which makes closer planes visually block the planes behind them.
const BASE_ALPHA: f32 = 255.0;

/// Impact splash pool size.
const SPLASH_MAX: u16 = 192;
/// Particles spawned per second (subject to column availability).  With
/// ~0.4 s life the steady-state onscreen count settles near SPLASH_MAX.
/// PSP runs a much lower spawn rate to keep splash mesh build / fill cost
/// in budget; ~150 spawns/s gives a sparse but still visible splash field.
const SPLASH_SPAWNS_PER_SEC: f32 = if (ae.platform == .psp) 150.0 else 500.0;
const SPLASH_GRAVITY: f32 = 12.0;
const SPLASH_LIFE_MIN: f32 = 0.25;
const SPLASH_LIFE_MAX: f32 = 0.55;
/// Billboard + collision radius.
const SPLASH_HALF_SIZE: f32 = 0.12;
/// Small vertical offset above the surface at spawn -- must exceed
/// SPLASH_HALF_SIZE so the AABB-based collision test doesn't immediately
/// intersect the floor block and kill the particle on frame 1.
const SPLASH_SPAWN_OFFSET: f32 = 0.18;

/// particles.png is 128x128 arranged as a 16x16 grid of 8x8-pixel tiles --
/// the Minecraft Classic convention.  The raindrop sprite sits at
/// tile (col=0, row=1).
const PARTICLE_ATLAS_SIZE: u32 = 128;
const PARTICLE_ATLAS_TILES: u32 = 16;
const DROP_TILE_COL: u32 = 0;
const DROP_TILE_ROW: u32 = 1;

/// Absolute-world i16 encoding shared with ParticleSystem: vertex = world * 128,
/// shader dequantizes / 32768 then model scale * 256 reproduces the value.
/// Rain encodes positions in a camera-local window (origin = cam tile) so
/// the used range stays tiny (EXTENT blocks) and comfortably in i16.
const POS_SCALE: f32 = 128.0;
const MODEL_SCALE: f32 = 256.0;

const VERTS_PER_QUAD: u32 = 12; // two windings -> visible from both sides
const QUADS_PER_SECTION: u32 = 2; // crossed X-plane + Z-plane per section
const COLUMNS_DIAM: u32 = 2 * EXTENT_U + 1;
const MAX_COLUMNS: u32 = COLUMNS_DIAM * COLUMNS_DIAM;
/// Upper bound on sections per column: ceil((RAIN_BELOW+RAIN_ABOVE)/SECTION_HEIGHT)
/// plus slack for fractional endpoints.  Each section may be split once at
/// the SNORM V wrap to keep stored UVs non-negative (PSP texture pipeline
/// doesn't interpolate across the wrap cleanly), so budget 2x after the
/// base count.
const MAX_SECTIONS_BASE: u32 = @intFromFloat(@ceil((RAIN_BELOW + RAIN_ABOVE) / SECTION_HEIGHT) + 1.0);
const MAX_SECTIONS_PER_COLUMN: u32 = MAX_SECTIONS_BASE * 2;
const STREAK_MAX_VERTS: u32 = MAX_COLUMNS * MAX_SECTIONS_PER_COLUMN * QUADS_PER_SECTION * VERTS_PER_QUAD;
const SPLASH_MAX_VERTS: u32 = @as(u32, SPLASH_MAX) * 6;

// --- Types ---

const Splash = struct {
    px: f32,
    py: f32,
    pz: f32,
    vx: f32,
    vy: f32,
    vz: f32,
    life: f32,
};

const Self = @This();

streak_mesh: Rendering.Mesh(Vertex),
splash_mesh: Rendering.Mesh(Vertex),
particle_atlas: TextureAtlas,
scroll_v: i32,
spawn_accum: f32,
splashes: [SPLASH_MAX]Splash,
splash_count: u16,
rng: std.Random.DefaultPrng,
allocator: std.mem.Allocator,

// --- Lifecycle ---

pub fn init(allocator: std.mem.Allocator, pipeline: Rendering.Pipeline.Handle) !Self {
    var self: Self = .{
        .streak_mesh = try Rendering.Mesh(Vertex).new(allocator, pipeline),
        .splash_mesh = try Rendering.Mesh(Vertex).new(allocator, pipeline),
        .particle_atlas = TextureAtlas.init(PARTICLE_ATLAS_SIZE, PARTICLE_ATLAS_SIZE, PARTICLE_ATLAS_TILES, PARTICLE_ATLAS_TILES),
        .scroll_v = 0,
        .spawn_accum = 0,
        .splashes = undefined,
        .splash_count = 0,
        .rng = std.Random.DefaultPrng.init(0xDA1ADA1ADA1ADA1A),
        .allocator = allocator,
    };
    try self.streak_mesh.vertices.ensureTotalCapacity(allocator, STREAK_MAX_VERTS);
    try self.splash_mesh.vertices.ensureTotalCapacity(allocator, SPLASH_MAX_VERTS);
    return self;
}

pub fn deinit(self: *Self) void {
    self.streak_mesh.deinit(self.allocator);
    self.splash_mesh.deinit(self.allocator);
}

// --- Update ---

pub fn update(self: *Self, dt: f32, camera: *const Camera) void {
    if (!Options.current.rain) {
        self.splash_count = 0;
        self.spawn_accum = 0;
        return;
    }

    // V scroll: i32 accumulates; build_streaks takes @mod(scroll_v, 32768)
    // so every frame's v_bottom/v_top stay on the same i16 side -- no wrap
    // flip, consistent gradient direction.
    const dv: i32 = @intFromFloat(@as(f32, @floatFromInt(FALL_SPEED)) * dt);
    self.scroll_v +%= dv;

    self.update_splashes(dt);

    // Spawn fractional accumulator: rate * dt particles per frame.
    self.spawn_accum += dt * SPLASH_SPAWNS_PER_SEC;
    while (self.spawn_accum >= 1.0) {
        self.spawn_accum -= 1.0;
        if (self.splash_count >= SPLASH_MAX) break;
        self.maybe_spawn_splash(camera);
    }
    // Guard against huge dt (pause, load stall) piling a burst.
    if (self.spawn_accum > 64.0) self.spawn_accum = 0;
}

fn update_splashes(self: *Self, dt: f32) void {
    var i: u16 = 0;
    while (i < self.splash_count) {
        const p = &self.splashes[i];
        p.life -= dt;
        if (p.life <= 0.0) {
            self.splash_count -= 1;
            self.splashes[i] = self.splashes[self.splash_count];
            continue;
        }
        p.vy -= SPLASH_GRAVITY * dt;
        const nx = p.px + p.vx * dt;
        const ny = p.py + p.vy * dt;
        const nz = p.pz + p.vz * dt;
        // Splashes pass through air and die on first terrain contact or exit.
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

fn maybe_spawn_splash(self: *Self, camera: *const Camera) void {
    var rand = self.rng.random();
    const cam_tile_x: i32 = @intFromFloat(@floor(camera.x));
    const cam_tile_z: i32 = @intFromFloat(@floor(camera.z));
    const dx = @as(i32, @intCast(rand.intRangeLessThan(u32, 0, COLUMNS_DIAM))) - EXTENT;
    const dz = @as(i32, @intCast(rand.intRangeLessThan(u32, 0, COLUMNS_DIAM))) - EXTENT;
    const gx = cam_tile_x + dx;
    const gz = cam_tile_z + dz;
    if (gx < 0 or gx >= c.WorldLength) return;
    if (gz < 0 or gz >= c.WorldDepth) return;

    const surface: i32 = rain_surface_at(gx, gz);
    if (surface <= 0 or surface >= c.WorldHeight) return;
    if (camera.y < @as(f32, @floatFromInt(surface))) return; // camera under a roof here

    self.splashes[self.splash_count] = .{
        .px = @as(f32, @floatFromInt(gx)) + rand.float(f32),
        .py = @as(f32, @floatFromInt(surface)) + SPLASH_SPAWN_OFFSET,
        .pz = @as(f32, @floatFromInt(gz)) + rand.float(f32),
        .vx = (rand.float(f32) - 0.5) * 4.0,
        .vy = 2.0 + rand.float(f32) * 2.5,
        .vz = (rand.float(f32) - 0.5) * 4.0,
        .life = SPLASH_LIFE_MIN + rand.float(f32) * (SPLASH_LIFE_MAX - SPLASH_LIFE_MIN),
    };
    self.splash_count += 1;
}

// --- Drawing ---

/// Build and draw the scrolling streak planes.  Caller must bind rain.png.
pub fn draw_streaks(self: *Self, camera: *const Camera) void {
    if (!Options.current.rain) return;

    self.streak_mesh.vertices.clearRetainingCapacity();
    build_streaks(&self.streak_mesh, camera, self.scroll_v);
    if (self.streak_mesh.vertices.items.len == 0) return;
    self.streak_mesh.update();

    const cam_tile_x: f32 = @floor(camera.x);
    const cam_tile_z: f32 = @floor(camera.z);

    // Transparent sheet: alpha blend on, depth write off so overlapping
    // quads don't occlude each other on the depth buffer.
    Rendering.gfx.api.set_alpha_blend(true);
    Rendering.gfx.api.set_depth_write(false);
    // Streaks sit close to the camera and span tall vertical columns; on PSP
    // the MODEL_SCALE * world coordinate can exit the 4096 virtual viewport,
    // so enable hardware clip planes to guarantee correct GU clipping.
    Rendering.gfx.api.set_clip_planes(true);

    const m = Math.Mat4.scaling(MODEL_SCALE, MODEL_SCALE, MODEL_SCALE)
        .mul(Math.Mat4.translation(cam_tile_x, 0, cam_tile_z));
    self.streak_mesh.draw(&m);

    Rendering.gfx.api.set_clip_planes(false);
    Rendering.gfx.api.set_depth_write(true);
}

/// Build and draw impact splashes.  Caller must bind particles.png.
pub fn draw_splashes(self: *Self, camera: *const Camera) void {
    if (!Options.current.rain) return;
    if (self.splash_count == 0) return;

    // Same billboard basis as ParticleSystem: right is yaw-only (no roll),
    // up tilts with pitch so quads face the camera when looking up/down.
    const cy = @cos(camera.yaw);
    const sy = @sin(camera.yaw);
    const cp = @cos(camera.pitch);
    const sp = @sin(camera.pitch);
    const rx = cy * SPLASH_HALF_SIZE;
    const rz = -sy * SPLASH_HALF_SIZE;
    const upx = -sy * sp * SPLASH_HALF_SIZE;
    const upy = cp * SPLASH_HALF_SIZE;
    const upz = -cy * sp * SPLASH_HALF_SIZE;

    const tu0 = self.particle_atlas.tileU(DROP_TILE_COL);
    const tv0 = self.particle_atlas.tileV(DROP_TILE_ROW);
    const tu1 = tu0 + self.particle_atlas.tileWidth();
    const tv1 = tv0 + self.particle_atlas.tileHeight();
    const color: u32 = @bitCast(Color.rgba(180, 180, 220, 255));

    self.splash_mesh.vertices.clearRetainingCapacity();
    var i: u16 = 0;
    while (i < self.splash_count) : (i += 1) {
        emit_splash(&self.splash_mesh, &self.splashes[i], rx, rz, upx, upy, upz, tu0, tv0, tu1, tv1, color);
    }
    self.splash_mesh.update();

    // Splashes use absolute-world encoding (no translation) so we can share
    // MODEL_SCALE with ParticleSystem and use a plain scaling matrix.
    Rendering.gfx.api.set_alpha_blend(true);
    const m = Math.Mat4.scaling(MODEL_SCALE, MODEL_SCALE, MODEL_SCALE);
    self.splash_mesh.draw(&m);
}

// --- Streak mesh build ---

fn build_streaks(mesh: *Rendering.Mesh(Vertex), camera: *const Camera, scroll_v: i32) void {
    const cam_tile_x: i32 = @intFromFloat(@floor(camera.x));
    const cam_tile_z: i32 = @intFromFloat(@floor(camera.z));
    const world_ceiling: f32 = @as(f32, @floatFromInt(c.WorldHeight));
    const top_y: f32 = @min(camera.y + RAIN_ABOVE, world_ceiling);
    const cam_floor: f32 = camera.y - RAIN_BELOW;

    var dz: i32 = -EXTENT;
    while (dz <= EXTENT) : (dz += 1) {
        var dx: i32 = -EXTENT;
        while (dx <= EXTENT) : (dx += 1) {
            const gx = cam_tile_x + dx;
            const gz = cam_tile_z + dz;
            if (gx < 0 or gx >= c.WorldLength) continue;
            if (gz < 0 or gz >= c.WorldDepth) continue;

            const surface_i: i32 = rain_surface_at(gx, gz);
            if (surface_i >= c.WorldHeight) continue; // sky-blocked to ceiling
            const surface_f: f32 = @as(f32, @floatFromInt(surface_i));
            if (camera.y < surface_f) continue; // camera below surface -> in a cave
            // Clip streak to the [camera - RAIN_BELOW, camera + RAIN_ABOVE]
            // window so the V delta across the quad fits comfortably in i16.
            const bottom_y: f32 = @max(surface_f, cam_floor);
            if (top_y <= bottom_y) continue;

            // Linear fade from 1 at center to 0 at grid edge.  Columns past
            // EXTENT blocks horizontally disappear entirely.
            const dist_sq: f32 = @as(f32, @floatFromInt(dx * dx + dz * dz));
            const dist: f32 = @sqrt(dist_sq);
            const fade = @max(0.0, 1.0 - dist / EXTENT_F);
            if (fade <= 0.0) continue;
            const alpha_byte: u8 = @intFromFloat(fade * BASE_ALPHA);
            const color: u32 = @bitCast(Color.rgba(255, 255, 255, alpha_byte));

            emit_column_quads(mesh, dx, dz, bottom_y, top_y, scroll_v, color);
        }
    }
}

/// Emit the streak's crossed vertical quads for a column.  To keep V_PER_BLOCK
/// high (dense drops) while the per-quad SNORM16 delta stays within i16, the
/// streak is stacked as SECTION_HEIGHT-tall quads.  Section boundaries share
/// the same i32 V value (computed from world Y via a single linear formula),
/// so their @mod(32768) SNORM16s tile seamlessly across the seam.  Within a
/// section the UV span crosses the SNORM16 wrap only if scroll_v happens to
/// land so; in that case we split the section at the wrap Y and emit two
/// sub-quads whose UVs both stay in [0, 32767] (PSP interpolation across a
/// positive->negative UV produces a visible "bouncing" glitch that OpenGL
/// REPEAT handles transparently).
fn emit_column_quads(
    mesh: *Rendering.Mesh(Vertex),
    dx: i32,
    dz: i32,
    bottom_y: f32,
    top_y: f32,
    scroll_v: i32,
    color: u32,
) void {
    const fx: f32 = @floatFromInt(dx);
    const fz: f32 = @floatFromInt(dz);
    const x_ctr = fx + 0.5;
    const z_ctr = fz + 0.5;

    var section_bottom: f32 = bottom_y;
    while (section_bottom < top_y) {
        const section_top: f32 = @min(section_bottom + SECTION_HEIGHT, top_y);
        const section_h: f32 = section_top - section_bottom;
        if (section_h <= 0.0) break;
        const section_diff: i32 = @intFromFloat(@round(section_h * V_PER_BLOCK_F));
        std.debug.assert(section_diff >= 0 and section_diff <= 32767);

        // V(y) = scroll_v + y * V_PER_BLOCK (in i32).  Pinning the section's
        // low-Y V to @mod(., 32768) puts it in [0, 32767]; the high-Y V sits
        // section_diff above it, which may exceed 32767 and thus cross the
        // SNORM16 wrap exactly once within the section.
        const v_bot_raw: i32 = scroll_v + @as(i32, @intFromFloat(@round(section_bottom * V_PER_BLOCK_F)));
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
            // Wrap at v_raw = v_bot_raw + (32768 - v_bot_mod); in the quad's
            // local fraction that's (32768 - v_bot_mod) / section_diff of
            // the way up.  Lower sub-quad runs v_bot_mod..32767 (1 SNORM
            // unit below the true wrap boundary -- REPEAT samples the same
            // texel), upper sub-quad runs 0..(v_top_from_bot - 32768).
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

/// Emit the crossed X-shaped pair of quads that make up a single section (or
/// sub-section after a wrap split).  v_bot/v_top must both be non-negative
/// so PSP hardware interpolates a monotonically increasing UV.
fn emit_section_geom(
    mesh: *Rendering.Mesh(Vertex),
    x_ctr: f32,
    z_ctr: f32,
    y_bot: f32,
    y_top: f32,
    v_bot: i16,
    v_top: i16,
    color: u32,
) void {
    // X-shaped (diagonal) crossed planes.  An axis-aligned + cross reads
    // edge-on when the camera looks along X or Z.  Rotating the cross 45
    // degrees means neither plane is ever edge-on simultaneously and the
    // streak always has visual mass regardless of yaw.
    const x_lo = x_ctr - STREAK_HALF;
    const x_hi = x_ctr + STREAK_HALF;
    const z_lo = z_ctr - STREAK_HALF;
    const z_hi = z_ctr + STREAK_HALF;
    const u_left: i16 = 0;
    const u_right: i16 = @intCast(U_SPAN);

    const by = encode(y_bot);
    const ty = encode(y_top);

    // Diagonal A: runs from (x_lo, z_lo) to (x_hi, z_hi).  Low-Y corners
    // get v_bot, high-Y corners v_top so V increases with world Y and
    // positive scroll_v animates drop content downward.
    emit_quad_both_sides(
        mesh,
        encode(x_lo),
        by,
        encode(z_lo),
        u_left,
        v_bot,
        encode(x_hi),
        by,
        encode(z_hi),
        u_right,
        v_bot,
        encode(x_hi),
        ty,
        encode(z_hi),
        u_right,
        v_top,
        encode(x_lo),
        ty,
        encode(z_lo),
        u_left,
        v_top,
        color,
    );

    // Diagonal B: runs from (x_lo, z_hi) to (x_hi, z_lo), crossing A at
    // the column center to form the X shape.
    emit_quad_both_sides(
        mesh,
        encode(x_lo),
        by,
        encode(z_hi),
        u_left,
        v_bot,
        encode(x_hi),
        by,
        encode(z_lo),
        u_right,
        v_bot,
        encode(x_hi),
        ty,
        encode(z_lo),
        u_right,
        v_top,
        encode(x_lo),
        ty,
        encode(z_hi),
        u_left,
        v_top,
        color,
    );
}

/// Emit a quad as 12 verts (front + back winding) so both sides are visible
/// under default backface culling.
fn emit_quad_both_sides(
    mesh: *Rendering.Mesh(Vertex),
    // bottom-left
    x0: i16,
    y0: i16,
    z0: i16,
    tu0: i16,
    tv0: i16,
    // bottom-right
    x1: i16,
    y1: i16,
    z1: i16,
    tu1: i16,
    tv1: i16,
    // top-right
    x2: i16,
    y2: i16,
    z2: i16,
    tu2: i16,
    tv2: i16,
    // top-left
    x3: i16,
    y3: i16,
    z3: i16,
    tu3: i16,
    tv3: i16,
    color: u32,
) void {
    const bl: Vertex = .{ .pos = .{ x0, y0, z0 }, .uv = .{ tu0, tv0 }, .color = color };
    const br: Vertex = .{ .pos = .{ x1, y1, z1 }, .uv = .{ tu1, tv1 }, .color = color };
    const tr: Vertex = .{ .pos = .{ x2, y2, z2 }, .uv = .{ tu2, tv2 }, .color = color };
    const tl: Vertex = .{ .pos = .{ x3, y3, z3 }, .uv = .{ tu3, tv3 }, .color = color };

    // Front: bl -> br -> tr, bl -> tr -> tl
    mesh.vertices.appendAssumeCapacity(bl);
    mesh.vertices.appendAssumeCapacity(br);
    mesh.vertices.appendAssumeCapacity(tr);
    mesh.vertices.appendAssumeCapacity(bl);
    mesh.vertices.appendAssumeCapacity(tr);
    mesh.vertices.appendAssumeCapacity(tl);
    // Back: reverse winding so the opposite side is also lit.
    mesh.vertices.appendAssumeCapacity(bl);
    mesh.vertices.appendAssumeCapacity(tr);
    mesh.vertices.appendAssumeCapacity(br);
    mesh.vertices.appendAssumeCapacity(bl);
    mesh.vertices.appendAssumeCapacity(tl);
    mesh.vertices.appendAssumeCapacity(tr);
}

// --- Splash mesh build ---

fn emit_splash(
    mesh: *Rendering.Mesh(Vertex),
    p: *const Splash,
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
    const bl: Vertex = .{ .pos = .{ encode(p.px - rx - upx), encode(p.py - upy), encode(p.pz - rz - upz) }, .uv = .{ tu0, tv1 }, .color = color };
    const br: Vertex = .{ .pos = .{ encode(p.px + rx - upx), encode(p.py - upy), encode(p.pz + rz - upz) }, .uv = .{ tu1, tv1 }, .color = color };
    const tr: Vertex = .{ .pos = .{ encode(p.px + rx + upx), encode(p.py + upy), encode(p.pz + rz + upz) }, .uv = .{ tu1, tv0 }, .color = color };
    const tl: Vertex = .{ .pos = .{ encode(p.px - rx + upx), encode(p.py + upy), encode(p.pz - rz + upz) }, .uv = .{ tu0, tv0 }, .color = color };
    mesh.vertices.appendAssumeCapacity(bl);
    mesh.vertices.appendAssumeCapacity(br);
    mesh.vertices.appendAssumeCapacity(tr);
    mesh.vertices.appendAssumeCapacity(bl);
    mesh.vertices.appendAssumeCapacity(tr);
    mesh.vertices.appendAssumeCapacity(tl);
}

// --- Utility ---

fn encode(world: f32) i16 {
    const scaled = @round(world * POS_SCALE);
    const clamped = @max(-32768.0, @min(32767.0, scaled));
    return @intFromFloat(clamped);
}

/// Classic-era per-column heightmap: Y+1 of the highest light-blocking block.
/// Updated by the world on every block change (src/game/world.zig:424) so we
/// get invalidation for free by reading it directly.
fn light_map_at(x: i32, z: i32) i32 {
    std.debug.assert(x >= 0 and x < c.WorldLength);
    std.debug.assert(z >= 0 and z < c.WorldDepth);
    const idx: u32 = @intCast(z * @as(i32, @intCast(c.WorldLength)) + x);
    return @intCast(World.light_map[idx]);
}

/// Y+1 of the highest block that physically blocks rain in column (x, z).
/// Differs from light_map_at: leaves and glass pass light but still stop a
/// streak visually and catch splash spawns, so we walk down from the world
/// ceiling to find the topmost block with non-zero collision height.  Scan
/// bails at light_map_at since any collision block at or below that point is
/// already covered by a light-blocker above it.
fn rain_surface_at(x: i32, z: i32) i32 {
    const light_surface: i32 = light_map_at(x, z);
    var y: i32 = @as(i32, @intCast(c.WorldHeight)) - 1;
    while (y >= light_surface) : (y -= 1) {
        const id = World.get_block(@intCast(x), @intCast(y), @intCast(z));
        if (collision.block_height(id) > 0.0) return y + 1;
    }
    return light_surface;
}

fn out_of_world(wx: f32, wy: f32, wz: f32) bool {
    if (wy < 0.0 or wy >= @as(f32, @floatFromInt(c.WorldHeight))) return true;
    if (wx < 0.0 or wx >= @as(f32, @floatFromInt(c.WorldLength))) return true;
    if (wz < 0.0 or wz >= @as(f32, @floatFromInt(c.WorldDepth))) return true;
    return false;
}

/// Full-AABB solidity test: every block that overlaps the particle's box
/// is checked.  Matches ParticleSystem.aabb_hits_solid so splash quads
/// can't clip into walls the way a single-point test at the center would
/// let them.
fn aabb_hits_solid(wx: f32, wy: f32, wz: f32) bool {
    const r: f32 = SPLASH_HALF_SIZE;
    const bx0: i32 = @intFromFloat(@floor(wx - r));
    const bx1: i32 = @intFromFloat(@floor(wx + r));
    const by0: i32 = @intFromFloat(@floor(wy - r));
    const by1: i32 = @intFromFloat(@floor(wy + r));
    const bz0: i32 = @intFromFloat(@floor(wz - r));
    const bz1: i32 = @intFromFloat(@floor(wz + r));
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
