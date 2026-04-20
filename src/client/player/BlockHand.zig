// Portions adapted from ClassiCube[](https://github.com/ClassiCube/ClassiCube) by UnknownShadow200.
// - Map generation & dig animation: primarily from wiki algorithm descriptions
//   (https://github.com/ClassiCube/ClassiCube/wiki/Minecraft-Classic-map-generation-algorithm
//    https://github.com/ClassiCube/ClassiCube/wiki/Dig-animation-details)
// - Physics & view-bob: cross-referenced in part from source code.
// - World generation also includes minimal cross-checks against the original BSD code
//   (e.g. one-line differences).
// See THIRD-PARTY-NOTICES.md for the full BSD 3-Clause license text.
//
// Ported to Zig for CrossCraft (LGPLv3; uses separate Aether-Engine).
// Modifications Copyright (c) 2026 CrossCraft

const std = @import("std");
const ae = @import("aether");
const Math = ae.Math;
const Rendering = ae.Rendering;

const c = @import("common").consts;
const Block = c.Block;

const Vertex = @import("../graphics/Vertex.zig").Vertex;
const TextureAtlas = @import("../graphics/TextureAtlas.zig").TextureAtlas;
const Camera = @import("Camera.zig");
const BlockRegistry = @import("../world/block/BlockRegistry.zig");
const face_mod = @import("../world/chunk/face.zig");
const Face = face_mod.Face;

// -- Tuning ------------------------------------------------------------------

// SNORM16 -> world scale; emit_face stores a unit cube in [0, 2048].
// Matches ChunkMesh / SelectionOutline model-matrix convention.
const WORLD_UNIT_SCALE: f32 = 16.0;
const HELD_SCALE: f32 = 0.4;

// Pose (camera-relative, view-space = eye at origin, +X right, +Y up, -Z fwd).
// Base Y of -0.3 (vs. the Classic reference's -0.72) was tuned for our 70 degrees
// vertical FOV and 0.72-block distance - at that depth the visible y
// half-range is only ~0.5, so the reference value dropped the cube clean
// off the bottom of the screen.
const YAW: f32 = std.math.pi / 4.0;
const BASE_X: f32 = 0.56;
const BASE_Y: f32 = -0.52;
const BASE_Z: f32 = -0.72;
// Slabs are half-height and would otherwise float; cross-plants have their
// visible content concentrated in the lower portion of the tile and read
// as hanging too low without a matching boost. Both share the same lift.
const HELD_Y_LIFT: f32 = 0.1;

// Swing animation.
const PLACE_PERIOD: f32 = 0.125;
const DIG_PERIOD: f32 = 0.35;
// Smaller than the Classic reference's -0.4 because our BASE_Y sits the
// cube near the bottom of the screen already; a full dip would send it
// entirely off-screen and hide the swap itself, so the user never sees
// the "old block down, new block up" transition.
const SWING_AMPLITUDE_Y: f32 = -0.15;
const DIG_AMP_X: f32 = -0.4;
const DIG_AMP_Y: f32 = 0.2;
const DIG_AMP_Z: f32 = -0.2;
// Per the Classic break-animation reference,
// the Y rotation peaks at +80 degrees and the X rotation at -20 degrees.
const DIG_YAW_RAD: f32 = 80.0 * std.math.pi / 180.0;
const DIG_PITCH_RAD: f32 = -20.0 * std.math.pi / 180.0;

// Cube path: 6 faces * 6 verts per triangle-pair quad. Cross-plant path
// emits 2 double-sided quads (24 verts), so the cube case is the worst.
const VERT_CAPACITY: usize = 36;
// Sentinel distinct from any real block id. Classic block ids occupy 0..49;
// 50..255 are unused, so 0xFF is safely outside the assigned range.
const SENTINEL: Block = @enumFromInt(0xFF);

const SwingKind = enum { idle, place, dig };

const Self = @This();

pipeline: Rendering.Pipeline.Handle,
atlas: TextureAtlas,
mesh: Rendering.Mesh(Vertex),
cached_block: Block,
pending_block: Block,
/// Whether the currently baked mesh used the shadow tint. Tracked alongside
/// `cached_block` so the mesh rebuilds when the player walks across a
/// sunlit/shaded boundary even if the slot stayed the same.
cached_shadowed: bool,
swing_kind: SwingKind,
swing_time: f32,
swing_period: f32,
prev_swing_y: f32,
allocator: std.mem.Allocator,

pub fn init(allocator: std.mem.Allocator, pipeline: Rendering.Pipeline.Handle, atlas: TextureAtlas) !Self {
    var self: Self = .{
        .pipeline = pipeline,
        .atlas = atlas,
        .mesh = try Rendering.Mesh(Vertex).new(allocator, pipeline),
        .cached_block = SENTINEL,
        .pending_block = SENTINEL,
        .cached_shadowed = false,
        .swing_kind = .idle,
        .swing_time = 0,
        .swing_period = 0,
        .prev_swing_y = 0,
        .allocator = allocator,
    };
    self.mesh.primitive = .triangles;
    // Reserve once at init so rebuild() stays infallible and never touches
    // the allocator on subsequent slot changes.
    try self.mesh.vertices.ensureTotalCapacity(allocator, VERT_CAPACITY);
    return self;
}

pub fn deinit(self: *Self) void {
    self.mesh.deinit(self.allocator);
}

// -- Input hooks -------------------------------------------------------------

/// Called from Player.on_break on every click, regardless of hit result.
/// Restarts the cycle from zero even if a dig swing is already in flight,
/// so spamming the button feels responsive instead of ignoring the input.
pub fn trigger_dig(self: *Self) void {
    self.swing_kind = .dig;
    self.swing_period = DIG_PERIOD;
    self.swing_time = 0;
    self.prev_swing_y = 0;
}

/// Called from Player.on_place on every right click. Restarts the cycle
/// like `trigger_dig` so back-to-back clicks feel responsive.
pub fn trigger_place(self: *Self) void {
    self.swing_kind = .place;
    self.swing_period = PLACE_PERIOD;
    self.swing_time = 0;
    self.prev_swing_y = 0;
}

// -- Per-frame update --------------------------------------------------------

pub fn update(self: *Self, dt: f32, current_block: Block, shadowed: bool) void {
    std.debug.assert(dt >= 0);

    // First frame: bootstrap cache without an animation.
    if (self.cached_block == SENTINEL) {
        self.rebuild(current_block, shadowed);
        self.cached_block = current_block;
        self.pending_block = current_block;
        self.cached_shadowed = shadowed;
        return;
    }

    // Light-state transitions don't kick off a swing -- they just rebake the
    // existing block with the new tint. Walking under a roof shouldn't
    // animate the held block, only retint it. Skip the rebuild while a dig
    // swing is mid-flight: that path will redraw the block on completion
    // anyway, and rebuilding mid-swing would briefly flash the new tint on
    // the dimming/brightening face during the animation.
    if (shadowed != self.cached_shadowed and self.swing_kind != .dig) {
        self.rebuild(self.cached_block, shadowed);
        self.cached_shadowed = shadowed;
    }

    // A slot change while idle kicks off a switch swing (same shape as
    // place). Mid-swing changes just update `pending_block`; the current
    // animation plays out and the swap happens at its rising edge (place)
    // or on completion (dig).
    if (current_block != self.pending_block) {
        self.pending_block = current_block;
        if (self.swing_kind == .idle) {
            self.swing_kind = .place;
            self.swing_period = PLACE_PERIOD;
            self.swing_time = 0;
            self.prev_swing_y = 0;
        }
    }

    if (self.swing_kind == .idle) return;
    self.swing_time += dt;

    if (self.swing_time >= self.swing_period) {
        // End of swing: force-sync the cache if a pending swap (or a tint
        // change deferred during a dig) never landed.
        if (self.cached_block != self.pending_block or self.cached_shadowed != shadowed) {
            self.rebuild(self.pending_block, shadowed);
            self.cached_block = self.pending_block;
            self.cached_shadowed = shadowed;
        }
        self.swing_kind = .idle;
        self.swing_time = 0;
        self.prev_swing_y = 0;
        return;
    }

    // Swap at the bottom of the place cycle: once `swing_y` starts
    // increasing again, the old block has bottomed out and the new one
    // should come up in its place.
    if (self.swing_kind == .place) {
        const t = self.swing_time / self.swing_period;
        const swing_y = SWING_AMPLITUDE_Y * @sin(t * std.math.pi);
        if (swing_y > self.prev_swing_y and self.cached_block != self.pending_block) {
            self.rebuild(self.pending_block, shadowed);
            self.cached_block = self.pending_block;
            self.cached_shadowed = shadowed;
        }
        self.prev_swing_y = swing_y;
    }
}

// -- Mesh build --------------------------------------------------------------

fn rebuild(self: *Self, block: Block, shadowed: bool) void {
    self.mesh.vertices.clearRetainingCapacity();
    if (block == .air) {
        self.mesh.update();
        return;
    }
    const reg = &BlockRegistry.global;
    // Lava ignores shadowing in chunk meshing; mirror that here so a held
    // lava block always reads as glowing.
    const shade = shadowed and block != .flowing_lava and block != .still_lava;

    // Cross-plants (saplings, flowers, mushrooms) have no cube faces -- the
    // chunk mesher emits two intersecting flat planes for them via
    // emit_cross. Mirror that here so the held viewmodel reads as a real
    // sapling/flower/mushroom instead of a cube wrapped in cross-PNG faces.
    if (reg.cross.isSet(@intFromEnum(block))) {
        // All faces of a cross-plant share one tile (registered via `all`),
        // so the face argument is arbitrary.
        const tile = reg.get_face_tile(block, .y_pos);
        face_mod.emit_cross(&self.mesh.vertices, 0, 0, 0, tile, &self.atlas, shade);
    } else {
        const is_slab = reg.slab.isSet(@intFromEnum(block));
        const faces = [_]Face{ .x_neg, .x_pos, .y_neg, .y_pos, .z_neg, .z_pos };
        for (faces) |face| {
            const tile = reg.get_face_tile(block, face);
            if (is_slab) {
                face_mod.emit_slab_face(&self.mesh.vertices, face, 0, 0, 0, tile, &self.atlas, shade);
            } else {
                face_mod.emit_face(&self.mesh.vertices, face, 0, 0, 0, tile, &self.atlas, shade);
            }
        }
    }

    const uniform: u32 = if (shade) face_mod.apply_shadow(0xFFFFFFFF) else 0xFFFFFFFF;
    for (self.mesh.vertices.items) |*v| {
        v.color = uniform;
    }

    std.debug.assert(self.mesh.vertices.items.len <= VERT_CAPACITY);
    self.mesh.update();
}

// -- Draw --------------------------------------------------------------------

pub fn draw(self: *Self, terrain: *const Rendering.Texture, camera: *const Camera) void {
    if (self.cached_block == .air or self.mesh.vertices.items.len == 0) return;

    // Clear depth so the cube is never clipped by nearby world geometry.
    // The existing clear_depth before the UI pass isolates the next layer.
    Rendering.gfx.api.clear_depth();

    // Use a fixed 70-degree vertical FOV for the held block so it looks
    // consistent regardless of the player's FOV setting.
    const hand_fov: f32 = 70.0 * std.math.pi / 180.0;
    if (camera.fov != hand_fov) {
        const screen_w = Rendering.gfx.surface.get_width();
        const screen_h = Rendering.gfx.surface.get_height();
        const aspect: f32 = @as(f32, @floatFromInt(screen_w)) / @as(f32, @floatFromInt(screen_h));
        const proj = Math.Mat4.perspectiveFovRh(hand_fov, aspect, if (ae.platform == .psp) 0.3 else 0.1, 128.0);
        Rendering.gfx.api.set_proj_matrix(&proj);
    }

    Rendering.Pipeline.bind(self.pipeline);
    terrain.bind();

    const anim = self.compute_anim();
    const reg = &BlockRegistry.global;
    const y_lift: f32 = if (reg.slab.isSet(@intFromEnum(self.cached_block)) or reg.cross.isSet(@intFromEnum(self.cached_block)))
        HELD_Y_LIFT
    else
        0;

    // View-space placement: scale the normalised [0, 0.0625] SNORM16 cube
    // to a HELD_SCALE (0.4) world-unit cube, pivot it around its centre,
    // rotate in place, then translate into the camera-relative hand slot.
    const scale = WORLD_UNIT_SCALE * HELD_SCALE;
    const half: f32 = HELD_SCALE * 0.5;

    const sca = Math.Mat4.scaling(scale, scale, scale);
    const center = Math.Mat4.translation(-half, -half, -half);
    const rot_x = Math.Mat4.rotationX(anim.pitch);
    const rot_y = Math.Mat4.rotationY(YAW + anim.yaw);
    // Sway opposite the camera bob so the held block visibly moves in
    // screen space. Both X and Z subtract bob_hor directly (not rotated
    // by yaw) to match the Classic feel: combined with the shared tilt
    // baked into the world view matrix, this reads as a hand-sway.
    const trans = Math.Mat4.translation(
        BASE_X + anim.dx - camera.bob_hor,
        BASE_Y + anim.dy + y_lift - camera.bob_ver,
        BASE_Z + anim.dz - camera.bob_hor,
    );

    // view_inv: undo Rx(pitch), then Ry(-yaw), then T(-eye).
    const view_rx_inv = Math.Mat4.rotationX(-camera.pitch);
    const view_ry_inv = Math.Mat4.rotationY(camera.yaw);
    const view_t_inv = Math.Mat4.translation(camera.x, camera.y, camera.z);

    const model = sca
        .mul(center)
        .mul(rot_x)
        .mul(rot_y)
        .mul(trans)
        .mul(view_rx_inv)
        .mul(view_ry_inv)
        .mul(view_t_inv);
    self.mesh.draw(&model);

    // Restore the camera's actual projection matrix.
    if (camera.fov != hand_fov) {
        const screen_w = Rendering.gfx.surface.get_width();
        const screen_h = Rendering.gfx.surface.get_height();
        const aspect: f32 = @as(f32, @floatFromInt(screen_w)) / @as(f32, @floatFromInt(screen_h));
        const proj = Math.Mat4.perspectiveFovRh(camera.fov, aspect, if (ae.platform == .psp) 0.3 else 0.1, 128.0);
        Rendering.gfx.api.set_proj_matrix(&proj);
    }
}

const Anim = struct {
    dx: f32,
    dy: f32,
    dz: f32,
    yaw: f32,
    pitch: f32,
};

fn compute_anim(self: *const Self) Anim {
    if (self.swing_kind == .idle) return .{ .dx = 0, .dy = 0, .dz = 0, .yaw = 0, .pitch = 0 };

    const t = self.swing_time / self.swing_period;

    if (self.swing_kind == .place) {
        return .{
            .dx = 0,
            .dy = SWING_AMPLITUDE_Y * @sin(t * std.math.pi),
            .dz = 0,
            .yaw = 0,
            .pitch = 0,
        };
    }

    // Dig: two-phase weighted motion. sqrt(t) front-loads the initial
    // thrust; sin(2s) gives the y a little bounce; sin(t*pi) handles z.
    const s = @sqrt(t) * std.math.pi;
    return .{
        .dx = DIG_AMP_X * @sin(s),
        .dy = DIG_AMP_Y * @sin(2.0 * s),
        .dz = DIG_AMP_Z * @sin(t * std.math.pi),
        .yaw = DIG_YAW_RAD * @sin(s),
        .pitch = DIG_PITCH_RAD * @sin(t * t * std.math.pi),
    };
}
