const std = @import("std");
const ae = @import("aether");
const input = ae.Core.input;

const Camera = @import("Camera.zig");
const bindings = @import("bindings.zig");
const collision = @import("collision.zig");

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

/// Initialise player state and wire up input callbacks.
/// `self` must have a stable address (module-level or arena-backed).
/// `x`, `y`, `z` are world coordinates; `y` is eye-level from server.
pub fn init(self: *Self, x: f32, y: f32, z: f32) !void {
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
    };

    try bindings.init();

    try input.add_vector2_callback("move", @ptrCast(self), on_move);
    try input.add_button_callback("jump", @ptrCast(self), on_jump);
    try input.add_button_callback("sneak", @ptrCast(self), on_sneak);
    try input.add_vector2_callback("look", @ptrCast(self), on_look);
    try input.add_vector2_callback("look_stick", @ptrCast(self), on_look_stick);
    try input.add_button_callback("escape", @ptrCast(self), on_escape);
    try input.add_button_callback("noclip", @ptrCast(self), on_noclip);

    input.mouse_sensitivity = 3.0;
    input.set_mouse_relative_mode(true);
}

/// Apply one frame of player movement.
pub fn update(self: *Self, dt: f32) void {
    std.debug.assert(dt >= 0);
    self.apply_look(dt);

    if (self.noclip) {
        self.update_noclip(dt);
    } else {
        self.run_ticks(dt);
    }

    self.sync_camera();
}

// -- Look --------------------------------------------------------------------

fn apply_look(self: *Self, dt: f32) void {
    if (self.mouse_captured) {
        self.camera.yaw -= self.look_delta[0];
        self.camera.pitch += self.look_delta[1];
    }
    self.look_delta = .{ 0, 0 };

    self.camera.yaw -= self.look_rate[0] * self.stick_look_speed * dt;
    self.camera.pitch += self.look_rate[1] * self.stick_look_speed * dt;

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
        return;
    }
    // Interpolate between previous and current tick positions
    const alpha = self.tick_remainder / TICK;
    self.camera.x = self.prev_x + (self.pos_x - self.prev_x) * alpha;
    self.camera.y = (self.prev_y + (self.pos_y - self.prev_y) * alpha) + collision.EYE_HEIGHT;
    self.camera.z = self.prev_z + (self.pos_z - self.prev_z) * alpha;
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
