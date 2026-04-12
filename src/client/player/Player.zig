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
const builtin = @import("builtin");
const ae = @import("aether");
const Math = ae.Math;
const Rendering = ae.Rendering;
const input = ae.Core.input;

const World = @import("game").World;
const c = @import("common").consts;
const B = c.Block;
const proto = @import("common").protocol;

const Camera = @import("Camera.zig");
const bindings = @import("bindings.zig");
const collision = @import("collision.zig");
const SpriteBatcher = @import("../ui/SpriteBatcher.zig");
const IsoBlockDrawer = @import("../ui/IsoBlockDrawer.zig");
const Scaling = @import("../ui/Scaling.zig");
const ParticleSystem = @import("../world/ParticleSystem.zig");
const BlockHand = @import("BlockHand.zig");
const Face = @import("../world/chunk/face.zig").Face;

pub const RaycastHit = struct {
    /// Block coordinates of the solid voxel under the crosshair.
    x: u16,
    y: u16,
    z: u16,
    /// Coordinates of the empty voxel the ray was in just before entering
    /// the hit block. Used as the placement target. May equal the hit
    /// position when the camera is already inside the block (no place).
    place_x: u16,
    place_y: u16,
    place_z: u16,
    has_place: bool,
};

/// Maximum reach in blocks for the selection raycast.
pub const REACH: f32 = 5.0;

/// Number of slots in the hotbar (Classic uses 9).
pub const HOTBAR_SLOTS: u8 = 9;

/// Default hotbar contents in slot order.
const DEFAULT_HOTBAR: [HOTBAR_SLOTS]u8 = .{
    B.Stone,
    B.Cobblestone,
    B.Brick,
    B.Dirt,
    B.Planks,
    B.Log,
    B.Leaves,
    B.Glass,
    B.Slab,
};

// gui.png layout (Minecraft Classic): hotbar bg at (0,0) 182x22; selector
// at (0,22) 24x24. Slots are 20px wide; first slot center 11px from the
// hotbar's left edge, so slot i center is 20*i - 80 from hotbar center.
const HOTBAR_TEX_X: i16 = 0;
const HOTBAR_TEX_Y: i16 = 0;
const HOTBAR_W: i16 = 182;
const HOTBAR_H: i16 = 22;
const SELECTOR_TEX_X: i16 = 0;
const SELECTOR_TEX_Y: i16 = 22;
const SELECTOR_SIZE: i16 = 24;
const HOTBAR_SLOT_STRIDE: i16 = 20;
// Keep HUD quads away from the PSP clip/depth edge. Low layer ids map very
// close to +1 NDC in SpriteBatcher; that is fragile on the PSP GU path.
const HOTBAR_BG_LAYER: u8 = 250;
const SELECTOR_LAYER: u8 = 251;

// Mouse-wheel scroll axis returns +/-1.0 per click; deadband at half a click
// so a single notch always advances exactly one slot and stray sub-tick
// values from analog sources never trigger a wrap.
const HOTBAR_SCROLL_DEADBAND: f32 = 0.5;

const Self = @This();

// -- Physics constants (blocks/tick, Classic units) --------------------------

const TICK: f32 = 0.05; // 50 ms, 20 TPS
const MAX_FRAME_DT: f32 = 0.25;
const NOCLIP_SPEED: f32 = 20.0;

const JUMP_VEL: f32 = 0.42;
const GRAVITY: f32 = 0.08;
const LIQUID_GRAVITY: f32 = 0.02;
const LIQUID_SWIM_UP: f32 = 0.04; // per tick while submerged + jump held

// Water-to-land exit boosts (past jump point)
const WATER_WALL_BOOST: f32 = 0.13; // climbing onto a block
const WATER_BOB_BOOST: f32 = 0.10; // open water bob
const LAVA_WALL_BOOST: f32 = 0.30;
const LAVA_BOB_BOOST: f32 = 0.20;

// Drag per tick (XYZ)
const DRAG_X: f32 = 0.91;
const DRAG_Y: f32 = 0.98;
const DRAG_Z: f32 = 0.91;

// Extra XZ friction when on ground (applied after drag)
const GROUND_FRICTION_X: f32 = 0.6;
const GROUND_FRICTION_Z: f32 = 0.6;

// Acceleration factor added to velocity per tick
const GROUND_ACCEL: f32 = 0.1;
const AIR_ACCEL: f32 = 0.02;
const LIQUID_ACCEL: f32 = 0.02;

// Liquid-specific drag per tick
const WATER_DRAG: f32 = 0.8;
const LAVA_DRAG: f32 = 0.5;

// -- View bobbing tuning -----------------------------------------------------
// Drives both the camera sway and the held-block screen-space sway. The
// underlying state is a walk phase (advanced by horizontal travel), an
// envelope (walk_swing) that fades in/out with motion, and a smoothed
// strength (bob_amount) that fades to zero in midair.

// Spec base unit: ~0.156 blocks. Final hor/ver scale this by 0.3/0.6.
const BOB_BASE_UNIT: f32 = 2.5 / 16.0;
const BOB_HOR_SCALE: f32 = 0.3;
const BOB_VER_SCALE: f32 = 0.6;

// Camera tilt (degrees). The X-rotation component is multiplied by 3 to
// match the Classic feel.
const BOB_TILT_DEG: f32 = 0.15;
const BOB_TILT_X_GAIN: f32 = 3.0;

// Walk-phase advance: minimum tick distance to count as moving, and the
// rate (= 2 * 20 in the spec, where 20 is TPS).
const BOB_WALK_THRESHOLD: f32 = 0.05;
const BOB_WALK_PHASE_RATE: f32 = 40.0;

// Envelope rates (per second) and grounded-strength smoothing.
const BOB_SWING_RATE: f32 = 3.0;
const BOB_STRENGTH_DECAY: f32 = 0.84;
const BOB_STRENGTH_GAIN: f32 = 0.1;
// Three substeps per 50 ms tick to match the spec's 60 Hz design.
const BOB_STRENGTH_SUBSTEPS: u32 = 3;

// Fall tilt: small extra X-rotation driven by vertical velocity. The
// +0.08 offset cancels gravity at rest so it doesn't drift while standing.
const FALL_TILT_GAIN: f32 = 0.05;
const FALL_TILT_GRAVITY_OFFSET: f32 = 0.08;

// -- Fields ------------------------------------------------------------------

camera: Camera,
// Current tick position (feet)
pos_x: f32,
pos_y: f32,
pos_z: f32,
// Previous tick position (for interpolation)
prev_x: f32,
prev_y: f32,
prev_z: f32,
// Velocity in blocks/tick
vel_x: f32,
vel_y: f32,
vel_z: f32,
on_ground: bool,
hit_horizontal: bool, // horizontal collision last tick (for water exit)
can_liquid_jump: bool, // one-shot flag for water exit boost
noclip: bool,
tick_remainder: f32,

move_dir: [2]f32, // x = strafe (right +), y = forward/back (forward +)
look_delta: [2]f32,
look_rate: [2]f32,
jumping: bool,
sneaking: bool,
mouse_captured: bool,
stick_look_speed: f32,

/// Block currently under the crosshair, if any. Refreshed each frame in
/// `update`. Consumed by GameState to draw the selection outline.
selected: ?RaycastHit,

/// Hotbar contents (block IDs) and currently selected slot index.
hotbar: [HOTBAR_SLOTS]u8,
selected_slot: u8,

/// Edge flag set by the inventory_toggle input callback. GameState polls and
/// clears this each frame so the player struct doesn't need to know about
/// the inventory overlay's lifetime or its mouse-capture handoff.
inventory_toggle_pending: bool,

/// Outbound packet sink, owned by the connection layer (FakeConn or
/// real socket). Used by break/place callbacks to send SetBlockToServer.
writer: *std.Io.Writer,

/// Optional sink for break particles. GameState wires this after both the
/// world renderer and player exist; null leaves on_break silently skipping
/// the visual effect (useful for tests).
particle_sink: ?*ParticleSystem,

/// Optional held-block viewmodel. GameState wires this after the renderer
/// exists. Used to trigger swing animations on place/break.
held_renderer: ?*BlockHand,

// View bobbing -- driven per tick from XZ travel + grounded state. All
// three values are double-buffered for per-frame interpolation, the same
// way prev_x/pos_x already are.
walk_phase: f32,
walk_phase_prev: f32,
walk_swing: f32,
walk_swing_prev: f32,
bob_amount: f32, // smoothed 0..1, the spec's BobStrength
bob_amount_prev: f32,

/// Initialise player state and wire up input callbacks.
/// `self` must have a stable address (module-level or arena-backed).
/// `x`, `y`, `z` are world coordinates; `y` is eye-level from server.
/// `writer` is the connection's outbound stream (used for SetBlockToServer).
pub fn init(self: *Self, x: f32, y: f32, z: f32, writer: *std.Io.Writer) !void {
    const feet_y = y - collision.EYE_HEIGHT;
    self.* = .{
        .camera = Camera.init(x, y, z),
        .pos_x = x,
        .pos_y = feet_y,
        .pos_z = z,
        .prev_x = x,
        .prev_y = feet_y,
        .prev_z = z,
        .vel_x = 0,
        .vel_y = 0,
        .vel_z = 0,
        .on_ground = false,
        .hit_horizontal = false,
        .can_liquid_jump = false,
        .noclip = false,
        .tick_remainder = 0,
        .move_dir = .{ 0, 0 },
        .look_delta = .{ 0, 0 },
        .look_rate = .{ 0, 0 },
        .jumping = false,
        .sneaking = false,
        .mouse_captured = true,
        .stick_look_speed = 3.0,
        .selected = null,
        .hotbar = DEFAULT_HOTBAR,
        .selected_slot = 0,
        .inventory_toggle_pending = false,
        .writer = writer,
        .particle_sink = null,
        .held_renderer = null,
        .walk_phase = 0,
        .walk_phase_prev = 0,
        .walk_swing = 0,
        .walk_swing_prev = 0,
        .bob_amount = 0,
        .bob_amount_prev = 0,
    };

    try bindings.init();

    try input.add_vector2_callback("move", @ptrCast(self), on_move);
    try input.add_button_callback("jump", @ptrCast(self), on_jump);
    try input.add_button_callback("sneak", @ptrCast(self), on_sneak);
    try input.add_vector2_callback("look", @ptrCast(self), on_look);
    try input.add_vector2_callback("look_stick", @ptrCast(self), on_look_stick);
    try input.add_button_callback("escape", @ptrCast(self), on_escape);
    if (comptime builtin.mode == .Debug and ae.platform != .psp) {
        try input.add_button_callback("noclip", @ptrCast(self), on_noclip);
    }
    try input.add_button_callback("inventory_toggle", @ptrCast(self), on_inventory_toggle);
    try input.add_button_callback("break", @ptrCast(self), on_break);
    try input.add_button_callback("place", @ptrCast(self), on_place);
    try input.add_button_callback("hotbar_left", @ptrCast(self), on_hotbar_left);
    try input.add_button_callback("hotbar_right", @ptrCast(self), on_hotbar_right);
    try input.add_axis_callback("hotbar_scroll", @ptrCast(self), on_hotbar_scroll);
    try input.add_button_callback("hotbar_slot_1", @ptrCast(self), on_hotbar_slot_1);
    try input.add_button_callback("hotbar_slot_2", @ptrCast(self), on_hotbar_slot_2);
    try input.add_button_callback("hotbar_slot_3", @ptrCast(self), on_hotbar_slot_3);
    try input.add_button_callback("hotbar_slot_4", @ptrCast(self), on_hotbar_slot_4);
    try input.add_button_callback("hotbar_slot_5", @ptrCast(self), on_hotbar_slot_5);
    try input.add_button_callback("hotbar_slot_6", @ptrCast(self), on_hotbar_slot_6);
    try input.add_button_callback("hotbar_slot_7", @ptrCast(self), on_hotbar_slot_7);
    try input.add_button_callback("hotbar_slot_8", @ptrCast(self), on_hotbar_slot_8);
    try input.add_button_callback("hotbar_slot_9", @ptrCast(self), on_hotbar_slot_9);

    input.mouse_sensitivity = 3.0;
    input.set_mouse_relative_mode(true);
}

/// Apply one frame of player movement.
pub fn update(self: *Self, dt: f32) void {
    std.debug.assert(dt >= 0);
    self.apply_look(dt);

    // mouse_captured doubles as the gameplay-input gate. While the inventory
    // overlay (or escape) has uncaptured the mouse, suppress movement, jump,
    // and sneak so PSP D-pad / face buttons cannot drive the player through
    // the world while the picker is up. Save/restore around the physics call
    // so the held shadow state survives the gated frames -- closing the
    // overlay while still holding W (or DpadUp) resumes movement immediately
    // without waiting for a fresh edge.
    const saved_move = self.move_dir;
    const saved_jump = self.jumping;
    const saved_sneak = self.sneaking;
    if (!self.mouse_captured) {
        self.move_dir = .{ 0, 0 };
        self.jumping = false;
        self.sneaking = false;
    }

    if (self.noclip) {
        self.update_noclip(dt);
    } else {
        self.run_ticks(dt);
    }

    if (!self.mouse_captured) {
        self.move_dir = saved_move;
        self.jumping = saved_jump;
        self.sneaking = saved_sneak;
    }

    self.sync_camera();
    self.selected = self.raycast_block(REACH);
}

// -- Look --------------------------------------------------------------------

fn apply_look(self: *Self, dt: f32) void {
    if (self.mouse_captured) {
        self.camera.yaw -= self.look_delta[0];
        self.camera.pitch += self.look_delta[1];
    }
    self.look_delta = .{ 0, 0 };

    // Stick look honours the same gate as mouse look so the PSP analog nub
    // does not rotate the camera while the inventory overlay is up.
    if (self.mouse_captured) {
        self.camera.yaw -= self.look_rate[0] * self.stick_look_speed * dt;
        self.camera.pitch += self.look_rate[1] * self.stick_look_speed * dt;
    }

    const max_pitch = std.math.pi / 2.0 - 0.01;
    self.camera.pitch = @max(-max_pitch, @min(max_pitch, self.camera.pitch));
}

// -- Noclip (freecam) -------------------------------------------------------

fn update_noclip(self: *Self, dt: f32) void {
    const sin_yaw = @sin(self.camera.yaw);
    const cos_yaw = @cos(self.camera.yaw);
    const strafe = self.move_dir[0];
    const forward = self.move_dir[1];

    self.pos_x += (strafe * cos_yaw - forward * sin_yaw) * NOCLIP_SPEED * dt;
    self.pos_z += (-strafe * sin_yaw - forward * cos_yaw) * NOCLIP_SPEED * dt;

    var dy: f32 = 0;
    if (self.jumping) dy += NOCLIP_SPEED * dt;
    if (self.sneaking) dy -= NOCLIP_SPEED * dt;
    self.pos_y += dy;

    // No interpolation in noclip -- prev tracks current
    self.prev_x = self.pos_x;
    self.prev_y = self.pos_y;
    self.prev_z = self.pos_z;
}

// -- Fixed-rate tick loop ----------------------------------------------------

fn run_ticks(self: *Self, dt: f32) void {
    const clamped = @min(dt, MAX_FRAME_DT);
    self.tick_remainder += clamped;

    while (self.tick_remainder >= TICK) {
        self.tick_remainder -= TICK;
        self.physics_tick();
    }
}

/// One Classic physics tick. Order matches the spec:
/// input -> vertical state -> accel -> collide+integrate -> drag -> gravity -> friction
fn physics_tick(self: *Self) void {
    // Save for interpolation
    self.prev_x = self.pos_x;
    self.prev_y = self.pos_y;
    self.prev_z = self.pos_z;

    // 1. Input scaled by 0.98, rotated into world space
    const strafe = self.move_dir[0] * 0.98;
    const forward = self.move_dir[1] * 0.98;
    const sin_yaw = @sin(self.camera.yaw);
    const cos_yaw = @cos(self.camera.yaw);
    const head_x = strafe * cos_yaw - forward * sin_yaw;
    const head_z = -strafe * sin_yaw - forward * cos_yaw;

    // Detect environment via two-zone liquid check
    const liq_feet = collision.liquid_feet(self.pos_x, self.pos_y, self.pos_z);
    const liq_body = collision.liquid_body(self.pos_x, self.pos_y, self.pos_z);
    const any_liquid: ?collision.Liquid = liq_feet orelse liq_body;

    // 2. Vertical velocity state (uses hit_horizontal from previous tick)
    self.update_vertical_state(liq_feet, liq_body);

    // 3. Horizontal acceleration
    const accel: f32 = if (any_liquid != null) LIQUID_ACCEL else if (self.on_ground) GROUND_ACCEL else AIR_ACCEL;
    var dist = @sqrt(head_x * head_x + head_z * head_z);
    if (dist < 1.0) dist = 1.0;
    self.vel_x += head_x * (accel / dist);
    self.vel_z += head_z * (accel / dist);

    // 4+5. Collide and integrate (Position += Velocity with collision)
    self.collide_and_move(any_liquid);

    // 6. Drag
    if (any_liquid) |liq| {
        const d: f32 = if (liq == .water) WATER_DRAG else LAVA_DRAG;
        self.vel_x *= d;
        self.vel_y *= d;
        self.vel_z *= d;
    } else {
        self.vel_x *= DRAG_X;
        self.vel_y *= DRAG_Y;
        self.vel_z *= DRAG_Z;
    }

    // 7. Gravity
    self.vel_y -= if (any_liquid != null) LIQUID_GRAVITY else GRAVITY;

    // 8. Ground friction (only on ground, not in liquid)
    if (self.on_ground and any_liquid == null) {
        self.vel_x *= GROUND_FRICTION_X;
        self.vel_z *= GROUND_FRICTION_Z;
    }

    // 9. Advance view-bob state from this tick's actual XZ movement.
    self.advance_view_bob();
}

// -- View bob (advance per tick, compute per frame) --------------------------

fn advance_view_bob(self: *Self) void {
    // Snapshot prev for sub-tick interpolation, then update.
    self.walk_phase_prev = self.walk_phase;
    self.walk_swing_prev = self.walk_swing;
    self.bob_amount_prev = self.bob_amount;

    const dx = self.pos_x - self.prev_x;
    const dz = self.pos_z - self.prev_z;
    const dist = @sqrt(dx * dx + dz * dz);

    if (dist > BOB_WALK_THRESHOLD) {
        self.walk_phase += dist * BOB_WALK_PHASE_RATE * TICK;
        self.walk_swing += BOB_SWING_RATE * TICK;
    } else {
        self.walk_swing -= BOB_SWING_RATE * TICK;
    }
    self.walk_swing = std.math.clamp(self.walk_swing, 0.0, 1.0);

    // Three substeps to match the spec's 60 Hz design at 20 TPS. Strength
    // grows toward 1 while grounded, decays toward 0 while airborne.
    var i: u32 = 0;
    while (i < BOB_STRENGTH_SUBSTEPS) : (i += 1) {
        if (self.on_ground) {
            self.bob_amount += BOB_STRENGTH_GAIN;
        } else {
            self.bob_amount *= BOB_STRENGTH_DECAY;
        }
        self.bob_amount = std.math.clamp(self.bob_amount, 0.0, 1.0);
    }
}

const ViewBob = struct {
    hor: f32,
    ver: f32,
    tilt: Math.Mat4,
};

fn compute_view_bob(self: *const Self, alpha: f32) ViewBob {
    const phase = self.walk_phase_prev + (self.walk_phase - self.walk_phase_prev) * alpha;
    const swing = self.walk_swing_prev + (self.walk_swing - self.walk_swing_prev) * alpha;
    const amount = self.bob_amount_prev + (self.bob_amount - self.bob_amount_prev) * alpha;

    const cosw = @cos(phase);
    const sinw = @sin(phase);
    const abs_sin = @abs(sinw);

    const hor_raw = cosw * swing * BOB_BASE_UNIT;
    const ver_raw = abs_sin * swing * BOB_BASE_UNIT;
    const hor = hor_raw * BOB_HOR_SCALE * amount;
    const ver = ver_raw * BOB_VER_SCALE * amount;

    const tilt_rad = BOB_TILT_DEG * std.math.pi / 180.0;
    const roll_z = -cosw * swing * tilt_rad * amount;
    const pitch_x = @abs(sinw * swing * tilt_rad) * BOB_TILT_X_GAIN * amount;

    // Fall tilt: small extra X-pitch from vertical velocity. We don't
    // double-buffer velocity, so use the current value -- the visible
    // artefact is tiny and avoids touching the existing physics state.
    const fall = -(self.vel_y + FALL_TILT_GRAVITY_OFFSET) * FALL_TILT_GAIN;

    const tilt = Math.Mat4.rotationZ(roll_z)
        .mul(Math.Mat4.rotationX(pitch_x))
        .mul(Math.Mat4.rotationX(fall));

    return .{ .hor = hor, .ver = ver, .tilt = tilt };
}

// -- Vertical state (3-phase water exit) -------------------------------------

fn update_vertical_state(
    self: *Self,
    liq_feet: ?collision.Liquid,
    liq_body: ?collision.Liquid,
) void {
    const any_liquid = liq_feet orelse liq_body;

    if (any_liquid == null) {
        // Airborne or on ground -- normal jump
        if (self.jumping and self.on_ground) {
            self.vel_y = JUMP_VEL;
            self.on_ground = false;
        }
        return;
    }

    if (!self.jumping) return;

    // Check "past jump point": feet in liquid, body NOT in liquid,
    // fractional Y >= 0.4
    const past_jump_point = liq_feet != null and liq_body == null and
        frac(self.pos_y) >= 0.4;

    if (!past_jump_point) {
        // Phase 1: submerged or not yet past jump point -- swim upward
        self.vel_y += LIQUID_SWIM_UP;
        self.can_liquid_jump = true; // reset one-shot when re-entering phase 1
        return;
    }

    // Phase 2: past jump point -- one-time exit boost
    if (!self.can_liquid_jump) return;
    self.can_liquid_jump = false;

    const is_water = (liq_feet.? == .water);
    if (self.hit_horizontal) {
        // Case A: climbing onto a block (pressing into wall)
        self.vel_y += if (is_water) WATER_WALL_BOOST else LAVA_WALL_BOOST;
    } else {
        // Case B: open water bob
        self.vel_y += if (is_water) WATER_BOB_BOOST else LAVA_BOB_BOOST;
    }
}

/// Fractional part of a float, always in [0, 1).
fn frac(v: f32) f32 {
    const r = v - @floor(v);
    return if (r < 0) r + 1.0 else r;
}

// -- Collision + integration -------------------------------------------------

fn collide_and_move(self: *Self, liquid: ?collision.Liquid) void {
    const was_on_ground = self.on_ground;

    const result = collision.move_and_collide(
        self.pos_x,
        self.pos_y,
        self.pos_z,
        self.vel_x,
        self.vel_y,
        self.vel_z,
    );

    // Track horizontal collision for water exit boost next tick
    self.hit_horizontal = result.hit_x or result.hit_z;

    // Step-up when blocked horizontally while on ground
    if (self.hit_horizontal and was_on_ground) {
        if (collision.try_step_up(self.pos_x, self.pos_y, self.pos_z, self.vel_x, self.vel_z)) |stepped| {
            self.pos_x = stepped.x;
            self.pos_y = stepped.y;
            self.pos_z = stepped.z;
            self.on_ground = true;
            self.vel_y = 0;
            return;
        }
    }

    // Water-to-land step-up: only accept if the stepped position exits liquid
    if (self.hit_horizontal and liquid != null) {
        if (collision.try_step_up(self.pos_x, self.pos_y, self.pos_z, self.vel_x, self.vel_z)) |stepped| {
            if (collision.liquid_feet(stepped.x, stepped.y, stepped.z) == null) {
                self.pos_x = stepped.x;
                self.pos_y = stepped.y;
                self.pos_z = stepped.z;
                self.on_ground = true;
                self.vel_y = 0;
                return;
            }
        }
    }

    self.pos_x = result.x;
    self.pos_y = result.y;
    self.pos_z = result.z;

    // Zero blocked velocity components
    if (result.hit_x) self.vel_x = 0;
    if (result.hit_z) self.vel_z = 0;
    if (result.on_ground and self.vel_y < 0) self.vel_y = 0;
    if (result.hit_y_above and self.vel_y > 0) self.vel_y = 0;

    self.on_ground = result.on_ground;

    // Step-down: was on ground, now airborne, not in liquid
    if (was_on_ground and !self.on_ground and self.vel_y <= 0 and liquid == null) {
        if (collision.try_snap_down(self.pos_x, self.pos_y, self.pos_z, collision.STEP_HEIGHT)) |landed_y| {
            self.pos_y = landed_y;
            self.on_ground = true;
            self.vel_y = 0;
        }
    }
}

// -- Camera sync (interpolation) ---------------------------------------------

fn sync_camera(self: *Self) void {
    if (self.noclip) {
        self.camera.x = self.pos_x;
        self.camera.y = self.pos_y + collision.EYE_HEIGHT;
        self.camera.z = self.pos_z;
        // Stale bob state would otherwise leak into the held block on
        // re-enter. Reset to identity / zero while flying.
        self.camera.tilt = Math.Mat4.identity();
        self.camera.bob_hor = 0;
        self.camera.bob_ver = 0;
        return;
    }
    // Interpolate between previous and current tick positions
    const alpha = self.tick_remainder / TICK;
    self.camera.x = self.prev_x + (self.pos_x - self.prev_x) * alpha;
    self.camera.y = (self.prev_y + (self.pos_y - self.prev_y) * alpha) + collision.EYE_HEIGHT;
    self.camera.z = self.prev_z + (self.pos_z - self.prev_z) * alpha;

    // Apply view bob: positional offset is rotated into yaw so the head
    // sways relative to facing direction (slight forward-back rocking
    // when combined with the tilt rotations).
    const bob = self.compute_view_bob(alpha);
    const sin_yaw = @sin(self.camera.yaw);
    const cos_yaw = @cos(self.camera.yaw);
    self.camera.x += bob.hor * cos_yaw;
    self.camera.y += bob.ver;
    self.camera.z += bob.hor * sin_yaw;
    self.camera.tilt = bob.tilt;
    self.camera.bob_hor = bob.hor;
    self.camera.bob_ver = bob.ver;
}

// -- Voxel raycast (Amanatides & Woo) ----------------------------------------

/// Walk voxels along the camera's forward ray and return the first non-air
/// block within `range` blocks of the eye, or null if none. Used for the
/// selection outline; iterative (no recursion), no allocation.
pub fn raycast_block(self: *const Self, range: f32) ?RaycastHit {
    std.debug.assert(range >= 0.0);
    std.debug.assert(range <= 64.0);

    // Camera-forward in world space. Yaw 0 looks down -Z, positive pitch up.
    // Derived from Camera.apply(): view = T(-pos) * Ry(-yaw) * Rx(pitch)
    // (row-vector convention), so the world vector mapping to view -Z is
    // (-cos(p)*sin(y), -sin(p), -cos(p)*cos(y)).
    const cp = @cos(self.camera.pitch);
    const dx = -@sin(self.camera.yaw) * cp;
    const dy = -@sin(self.camera.pitch);
    const dz = -@cos(self.camera.yaw) * cp;

    const ox = self.camera.x;
    const oy = self.camera.y;
    const oz = self.camera.z;

    const fx = @floor(ox);
    const fy = @floor(oy);
    const fz = @floor(oz);
    // Camera outside representable range — nothing to select.
    if (fx < -2147483648.0 or fx > 2147483647.0) return null;
    if (fy < -2147483648.0 or fy > 2147483647.0) return null;
    if (fz < -2147483648.0 or fz > 2147483647.0) return null;
    var bx: i32 = @intFromFloat(fx);
    var by: i32 = @intFromFloat(fy);
    var bz: i32 = @intFromFloat(fz);

    const step_x: i32 = if (dx > 0) 1 else if (dx < 0) -1 else 0;
    const step_y: i32 = if (dy > 0) 1 else if (dy < 0) -1 else 0;
    const step_z: i32 = if (dz > 0) 1 else if (dz < 0) -1 else 0;

    const INF: f32 = std.math.inf(f32);
    const t_delta_x: f32 = if (dx != 0) @abs(1.0 / dx) else INF;
    const t_delta_y: f32 = if (dy != 0) @abs(1.0 / dy) else INF;
    const t_delta_z: f32 = if (dz != 0) @abs(1.0 / dz) else INF;

    var t_max_x: f32 = if (dx != 0) next_boundary(ox, dx) else INF;
    var t_max_y: f32 = if (dy != 0) next_boundary(oy, dy) else INF;
    var t_max_z: f32 = if (dz != 0) next_boundary(oz, dz) else INF;

    // Check the voxel containing the eye first (in case we're inside a block).
    if (in_world(bx, by, bz)) {
        if (is_selectable(@intCast(bx), @intCast(by), @intCast(bz))) {
            return .{
                .x = @intCast(bx),
                .y = @intCast(by),
                .z = @intCast(bz),
                .place_x = @intCast(bx),
                .place_y = @intCast(by),
                .place_z = @intCast(bz),
                .has_place = false,
            };
        }
    }

    // Hard cap iterations as defense in depth against numerical edge cases.
    const max_iters: u32 = 64;
    var i: u32 = 0;
    while (i < max_iters) : (i += 1) {
        const t_min = @min(t_max_x, @min(t_max_y, t_max_z));
        if (t_min > range) return null;

        // Remember the empty voxel we're stepping out of -- that's where a
        // place action would put a new block.
        const prev_x = bx;
        const prev_y = by;
        const prev_z = bz;

        if (t_max_x <= t_max_y and t_max_x <= t_max_z) {
            bx += step_x;
            t_max_x += t_delta_x;
        } else if (t_max_y <= t_max_z) {
            by += step_y;
            t_max_y += t_delta_y;
        } else {
            bz += step_z;
            t_max_z += t_delta_z;
        }

        if (!in_world(bx, by, bz)) return null;
        if (is_selectable(@intCast(bx), @intCast(by), @intCast(bz))) {
            const has_place = in_world(prev_x, prev_y, prev_z);
            return .{
                .x = @intCast(bx),
                .y = @intCast(by),
                .z = @intCast(bz),
                .place_x = if (has_place) @intCast(prev_x) else @intCast(bx),
                .place_y = if (has_place) @intCast(prev_y) else @intCast(by),
                .place_z = if (has_place) @intCast(prev_z) else @intCast(bz),
                .has_place = has_place,
            };
        }
    }
    return null;
}

/// Distance along the ray to the next integer grid plane on one axis.
fn next_boundary(origin: f32, dir: f32) f32 {
    std.debug.assert(dir != 0);
    const cell = @floor(origin);
    const next: f32 = if (dir > 0) cell + 1.0 else cell;
    return (next - origin) / dir;
}

fn in_world(x: i32, y: i32, z: i32) bool {
    return x >= 0 and y >= 0 and z >= 0 and
        x < c.WorldLength and y < c.WorldHeight and z < c.WorldDepth;
}

/// What counts as "selectable" by the crosshair. Air and fluids are
/// passed through so the outline lands on the first solid block behind
/// any water/lava the ray crosses.
fn is_selectable(x: u16, y: u16, z: u16) bool {
    const id = World.get_block(x, y, z);
    return switch (id) {
        B.Air,
        B.Flowing_Water,
        B.Still_Water,
        B.Flowing_Lava,
        B.Still_Lava,
        => false,
        else => true,
    };
}

// -- UI / HUD ----------------------------------------------------------------

/// HUD pass: queues every 2D sprite (crosshair, hotbar background, selector
/// frame) into `batcher`, and queues hotbar block icons into `iso`. Caller
/// flushes the sprite batcher first, then the iso drawer, so the 3D block
/// icons land on top of the 2D selector frame in a single sprite pass — no
/// second batcher and no extra depth clear needed.
pub fn draw_ui(
    self: *Self,
    batcher: *SpriteBatcher,
    iso: *IsoBlockDrawer,
    gui: *const Rendering.Texture,
    hide_crosshair: bool,
) void {
    std.debug.assert(self.selected_slot < HOTBAR_SLOTS);

    // Crosshair: gui.png (240, 0), 16x16, screen center.
    // Hidden while the block inventory overlay is open.
    if (!hide_crosshair) {
        batcher.add_sprite(&.{
            .texture = gui,
            .pos_offset = .{ .x = 0, .y = 0 },
            .pos_extent = .{ .x = 16, .y = 16 },
            .tex_offset = .{ .x = 240, .y = 0 },
            .tex_extent = .{ .x = 16, .y = 16 },
            .color = .white,
            .layer = 255,
            .reference = .middle_center,
            .origin = .middle_center,
        });
    }

    // Hotbar background. The 1 px upward nudge keeps the selector's bottom
    // row (selector is 24 tall vs the hotbar's 22) from clipping off the
    // bottom of the screen.
    batcher.add_sprite(&.{
        .texture = gui,
        .pos_offset = .{ .x = 0, .y = -1 },
        .pos_extent = .{ .x = HOTBAR_W, .y = HOTBAR_H },
        .tex_offset = .{ .x = HOTBAR_TEX_X, .y = HOTBAR_TEX_Y },
        .tex_extent = .{ .x = HOTBAR_W, .y = HOTBAR_H },
        .color = .white,
        .layer = HOTBAR_BG_LAYER,
        .reference = .bottom_center,
        .origin = .bottom_center,
    });

    // Selector frame, centered over the active slot. Slot i center sits at
    // 20*i - 80 from the hotbar's horizontal center.
    const slot_i: i16 = @intCast(self.selected_slot);
    const sel_x: i16 = HOTBAR_SLOT_STRIDE * slot_i - 80;
    batcher.add_sprite(&.{
        .texture = gui,
        .pos_offset = .{ .x = sel_x, .y = 0 },
        .pos_extent = .{ .x = SELECTOR_SIZE, .y = SELECTOR_SIZE },
        .tex_offset = .{ .x = SELECTOR_TEX_X, .y = SELECTOR_TEX_Y },
        .tex_extent = .{ .x = SELECTOR_SIZE, .y = SELECTOR_SIZE },
        .color = .white,
        .layer = SELECTOR_LAYER,
        .reference = .bottom_center,
        .origin = .bottom_center,
    });

    self.draw_hotbar_blocks(iso);
}

// Logical-pixel half-extent of each rendered iso block. The iso projection
// makes the cube taller than wide (height ~= 2*cos30/cos45 * half_extent ~=
// 2.45x); 6 px keeps the projected block ~12 wide x ~14 tall, leaving the
// 16 px slot interior clear of the surrounding selector frame.
const HOTBAR_BLOCK_HALF_EXTENT: f32 = 3.5;

fn draw_hotbar_blocks(self: *const Self, iso: *IsoBlockDrawer) void {
    const screen_w = Rendering.gfx.surface.get_width();
    const screen_h = Rendering.gfx.surface.get_height();
    const ui_scale = Scaling.compute(screen_w, screen_h);
    const max_lx: i32 = @intCast(screen_w / ui_scale);
    const max_ly: i32 = @intCast(screen_h / ui_scale);

    // Hotbar bg sits at bottom-center with pos_offset y = -1 and origin
    // bottom-center, so its bottom edge is at max_ly - 1 and its top edge at
    // max_ly - 1 - HOTBAR_H. Slot centers are 11 px below the top of the bg
    // (Classic uses centered 20 px slots inside a 22 px tall strip).
    const hotbar_top: f32 = @floatFromInt(max_ly - 1 - @as(i32, HOTBAR_H));
    const slot_cy: f32 = hotbar_top + 11.0;
    const center_x: f32 = @floatFromInt(@divTrunc(max_lx, 2));

    var i: u8 = 0;
    while (i < HOTBAR_SLOTS) : (i += 1) {
        const slot_offset_x: f32 = @floatFromInt(@as(i32, HOTBAR_SLOT_STRIDE) * @as(i32, i) - 80);
        iso.add_block(self.hotbar[i], center_x + slot_offset_x, slot_cy, HOTBAR_BLOCK_HALF_EXTENT);
    }
}

// -- Input callbacks ---------------------------------------------------------

fn on_move(ctx: *anyopaque, value: [2]f32) void {
    const self: *Self = @ptrCast(@alignCast(ctx));
    self.move_dir = value;
}

fn on_jump(ctx: *anyopaque, event: input.ButtonEvent) void {
    const self: *Self = @ptrCast(@alignCast(ctx));
    self.jumping = event == .pressed;
}

fn on_sneak(ctx: *anyopaque, event: input.ButtonEvent) void {
    const self: *Self = @ptrCast(@alignCast(ctx));
    self.sneaking = event == .pressed;
}

fn on_look(ctx: *anyopaque, value: [2]f32) void {
    const self: *Self = @ptrCast(@alignCast(ctx));
    self.look_delta = value;
}

fn on_look_stick(ctx: *anyopaque, value: [2]f32) void {
    const self: *Self = @ptrCast(@alignCast(ctx));
    self.look_rate = value;
}

fn on_escape(ctx: *anyopaque, event: input.ButtonEvent) void {
    if (event != .pressed) return;
    const self: *Self = @ptrCast(@alignCast(ctx));
    self.mouse_captured = !self.mouse_captured;
    input.set_mouse_relative_mode(self.mouse_captured);
    self.look_delta = .{ 0, 0 };
}

/// Edge-only signal: GameState polls and clears `inventory_toggle_pending`
/// each frame and owns the open/close + mouse-capture handoff for the
/// inventory overlay. Toggling capture here would race the overlay's own
/// open/close path.
fn on_inventory_toggle(ctx: *anyopaque, event: input.ButtonEvent) void {
    if (event != .pressed) return;
    const self: *Self = @ptrCast(@alignCast(ctx));
    self.inventory_toggle_pending = true;
}

fn on_noclip(ctx: *anyopaque, event: input.ButtonEvent) void {
    if (event != .pressed) return;
    const self: *Self = @ptrCast(@alignCast(ctx));
    self.noclip = !self.noclip;
    if (self.noclip) {
        self.vel_x = 0;
        self.vel_y = 0;
        self.vel_z = 0;
    } else {
        self.on_ground = collision.on_ground(self.pos_x, self.pos_y, self.pos_z);
    }
}

fn on_break(ctx: *anyopaque, event: input.ButtonEvent) void {
    if (event != .pressed) return;
    const self: *Self = @ptrCast(@alignCast(ctx));
    if (!self.mouse_captured) return;
    // Swing on every click, regardless of whether we actually struck a block.
    if (self.held_renderer) |hr| hr.trigger_dig();
    const hit = self.selected orelse return;
    if (self.particle_sink) |ps| {
        const block_id = World.get_block(hit.x, hit.y, hit.z);
        if (block_id != B.Air) {
            ps.spawn_break(block_id, hit.x, hit.y, hit.z, derive_break_face(hit));
        }
    }
    send_block_change(self.writer, hit.x, hit.y, hit.z, 0, B.Air);
}

/// Recover which face the player struck from the raycast result. The
/// raycaster stores the empty cell just before the hit (`place_*`); the
/// delta from there to the hit voxel points along the broken face's normal.
///
/// `raycast_block` advances exactly one axis per DDA iteration, so for a
/// real hit (`has_place == true`) the place cell differs from the hit cell
/// by exactly one component. The axis priority below is therefore just
/// "first non-zero wins", not a tiebreaker — corners can't occur.
fn derive_break_face(hit: RaycastHit) Face {
    if (!hit.has_place) return .y_pos;
    const dx: i32 = @as(i32, hit.place_x) - @as(i32, hit.x);
    const dy: i32 = @as(i32, hit.place_y) - @as(i32, hit.y);
    const dz: i32 = @as(i32, hit.place_z) - @as(i32, hit.z);
    if (dy > 0) return .y_pos;
    if (dy < 0) return .y_neg;
    if (dx > 0) return .x_pos;
    if (dx < 0) return .x_neg;
    if (dz > 0) return .z_pos;
    return .z_neg;
}

fn on_place(ctx: *anyopaque, event: input.ButtonEvent) void {
    if (event != .pressed) return;
    const self: *Self = @ptrCast(@alignCast(ctx));
    if (!self.mouse_captured) return;
    const hit = self.selected orelse return;
    if (!hit.has_place) return;
    // Avoid placing a block inside the player's own AABB.
    const bx0: f32 = @floatFromInt(hit.place_x);
    const by0: f32 = @floatFromInt(hit.place_y);
    const bz0: f32 = @floatFromInt(hit.place_z);
    const overlaps = self.pos_x + collision.HALF_W > bx0 and
        self.pos_x - collision.HALF_W < bx0 + 1.0 and
        self.pos_y + collision.HEIGHT > by0 and
        self.pos_y < by0 + 1.0 and
        self.pos_z + collision.HALF_W > bz0 and
        self.pos_z - collision.HALF_W < bz0 + 1.0;
    if (overlaps) return;
    std.debug.assert(self.selected_slot < HOTBAR_SLOTS);
    const block = self.hotbar[self.selected_slot];
    if (block == B.Air) return;
    send_block_change(self.writer, hit.place_x, hit.place_y, hit.place_z, 1, block);
    if (self.held_renderer) |hr| hr.trigger_place();
}

fn on_hotbar_left(ctx: *anyopaque, event: input.ButtonEvent) void {
    if (event != .pressed) return;
    const self: *Self = @ptrCast(@alignCast(ctx));
    if (!self.mouse_captured) return;
    self.selected_slot = if (self.selected_slot == 0) HOTBAR_SLOTS - 1 else self.selected_slot - 1;
}

fn on_hotbar_right(ctx: *anyopaque, event: input.ButtonEvent) void {
    if (event != .pressed) return;
    const self: *Self = @ptrCast(@alignCast(ctx));
    if (!self.mouse_captured) return;
    self.selected_slot = if (self.selected_slot + 1 >= HOTBAR_SLOTS) 0 else self.selected_slot + 1;
}

fn select_slot(self: *Self, slot: u8) void {
    std.debug.assert(slot < HOTBAR_SLOTS);
    if (!self.mouse_captured) return;
    self.selected_slot = slot;
}

fn on_hotbar_slot_1(ctx: *anyopaque, event: input.ButtonEvent) void {
    if (event != .pressed) return;
    select_slot(@ptrCast(@alignCast(ctx)), 0);
}
fn on_hotbar_slot_2(ctx: *anyopaque, event: input.ButtonEvent) void {
    if (event != .pressed) return;
    select_slot(@ptrCast(@alignCast(ctx)), 1);
}
fn on_hotbar_slot_3(ctx: *anyopaque, event: input.ButtonEvent) void {
    if (event != .pressed) return;
    select_slot(@ptrCast(@alignCast(ctx)), 2);
}
fn on_hotbar_slot_4(ctx: *anyopaque, event: input.ButtonEvent) void {
    if (event != .pressed) return;
    select_slot(@ptrCast(@alignCast(ctx)), 3);
}
fn on_hotbar_slot_5(ctx: *anyopaque, event: input.ButtonEvent) void {
    if (event != .pressed) return;
    select_slot(@ptrCast(@alignCast(ctx)), 4);
}
fn on_hotbar_slot_6(ctx: *anyopaque, event: input.ButtonEvent) void {
    if (event != .pressed) return;
    select_slot(@ptrCast(@alignCast(ctx)), 5);
}
fn on_hotbar_slot_7(ctx: *anyopaque, event: input.ButtonEvent) void {
    if (event != .pressed) return;
    select_slot(@ptrCast(@alignCast(ctx)), 6);
}
fn on_hotbar_slot_8(ctx: *anyopaque, event: input.ButtonEvent) void {
    if (event != .pressed) return;
    select_slot(@ptrCast(@alignCast(ctx)), 7);
}
fn on_hotbar_slot_9(ctx: *anyopaque, event: input.ButtonEvent) void {
    if (event != .pressed) return;
    select_slot(@ptrCast(@alignCast(ctx)), 8);
}

/// Mouse scroll wheel: positive value = scroll up = previous slot, negative
/// = scroll down = next slot. Uses an axis callback because the underlying
/// mouse_scroll source is a per-frame delta consumed on read.
fn on_hotbar_scroll(ctx: *anyopaque, value: f32) void {
    const self: *Self = @ptrCast(@alignCast(ctx));
    if (!self.mouse_captured) return;
    if (value > HOTBAR_SCROLL_DEADBAND) {
        self.selected_slot = if (self.selected_slot == 0) HOTBAR_SLOTS - 1 else self.selected_slot - 1;
    } else if (value < -HOTBAR_SCROLL_DEADBAND) {
        self.selected_slot = if (self.selected_slot + 1 >= HOTBAR_SLOTS) 0 else self.selected_slot + 1;
    }
}

/// Send a SetBlockToServer packet and flush the writer so the embedded
/// server picks it up on its next drain. Errors are logged-and-ignored;
/// dropping a click is harmless and the alternative would crash the game.
fn send_block_change(w: *std.Io.Writer, x: u16, y: u16, z: u16, mode: u8, block: u8) void {
    proto.send_set_block_to_server(w, x, y, z, mode, block) catch |err| {
        std.log.scoped(.player).err("send_set_block_to_server: {}", .{err});
        return;
    };
    w.flush() catch |err| {
        std.log.scoped(.player).err("writer.flush: {}", .{err});
    };
}
