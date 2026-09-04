// Portions adapted from ClassiCube (https://github.com/ClassiCube/ClassiCube) by UnknownShadow200.
// - Dig animation: primarily from wiki algorithm descriptions
//   (https://github.com/ClassiCube/ClassiCube/wiki/Dig-animation-details)
// - Physics & view-bob: cross-referenced in part from source code.
// See THIRD_PARTY_NOTICES.md for the full BSD 3-Clause license text.
//
// Ported to Zig for CrossCraft (GPLv2; uses separate Aether-Engine).
// Modifications Copyright (c) 2026 CrossCraft

const std = @import("std");
const assert = std.debug.assert;
const builtin = @import("builtin");
const ae = @import("aether");
const Math = ae.Math;
const Rendering = ae.Rendering;
const input = ae.Core.input;

const core = @import("core");
const World = core.World;
const Block = core.blocks.Block;
const proto = core.protocol;

const Camera = @import("Camera.zig");
const bindings = @import("bindings.zig");
const collision = @import("collision.zig");
const UiDrawList = @import("../ui/UiDrawList.zig");
const Scaling = ae.UI.Scaling;
const layout = ae.UI.layout;
const Colors = @import("../graphics/Color.zig");
const ParticleSystem = @import("../world/ParticleSystem.zig");
const BlockHand = @import("BlockHand.zig");
const blocks = core.blocks;
const SoundManager = @import("../SoundManager.zig");
const Face = @import("../world/chunk/face.zig").Face;
const Options = @import("../Options.zig");

const PrevInputs = struct {
    inventory_toggle: input.ButtonState = .released,
    noclip: input.ButtonState = .released,
    jump: input.ButtonState = .released,
    break_: input.ButtonState = .released,
    place: input.ButtonState = .released,
    pick_block: input.ButtonState = .released,
    shoulder_r: input.ButtonState = .released,
    shoulder_l: input.ButtonState = .released,
    playerlist: input.ButtonState = .released,
    hud_toggle: input.ButtonState = .released,
    rain_toggle: input.ButtonState = .released,
    chat_open: input.ButtonState = .released,
    chat_cmd: input.ButtonState = .released,
    hotbar_left: input.ButtonState = .released,
    hotbar_right: input.ButtonState = .released,
    hotbar_slot: [9]input.ButtonState = @splat(.released),
};

fn rising_edge(prev: input.ButtonState, cur: input.ButtonState) bool {
    return prev == .released and cur == .pressed;
}

pub const RaycastHit = struct {
    x: u16,
    y: u16,
    z: u16,
    // Empty voxel immediately before the hit, used for placement.
    place_x: u16,
    place_y: u16,
    place_z: u16,
    has_place: bool,
};

pub const FlyTapEvent = enum {
    double,
    triple,
};

pub const REACH: f32 = 5.0;

pub const HOTBAR_SLOTS: u8 = 9;

const DEFAULT_HOTBAR: [HOTBAR_SLOTS]Block = .{
    .stone,
    .cobblestone,
    .brick,
    .dirt,
    .planks,
    .log,
    .leaves,
    .glass,
    .slab,
};

const HOTBAR_TEX_X: i16 = 0;
const HOTBAR_TEX_Y: i16 = 0;
const HOTBAR_W: i16 = 182;
const HOTBAR_H: i16 = 22;
const SELECTOR_TEX_X: i16 = 0;
const SELECTOR_TEX_Y: i16 = 22;
const SELECTOR_SIZE: i16 = 24;
const HOTBAR_SLOT_STRIDE: i16 = 20;
// Keep HUD quads away from the PSP depth edge.
const HOTBAR_BG_LAYER: u8 = 250;
const SELECTOR_LAYER: u8 = 251;

const HOTBAR_SCROLL_DEADBAND: f32 = 0.5;

const LOOK_PIXEL_TO_RAD: f32 = 0.002;

const Player = @This();

// Client-side collision prediction until a placed block round-trips.
const PendingBlock = struct {
    x: u16,
    y: u16,
    z: u16,
    block: Block,
};

const TICK: f32 = 0.05;
const MAX_FRAME_DT: f32 = 0.25;
const NOCLIP_SPEED: f32 = 20.0;
const FLY_SPEED: f32 = NOCLIP_SPEED;

const JUMP_VEL: f32 = 0.42;
const GRAVITY: f32 = 0.08;
const LIQUID_GRAVITY: f32 = 0.02;
const LIQUID_SWIM_UP: f32 = 0.04;

const WATER_WALL_BOOST: f32 = 0.13;
const WATER_BOB_BOOST: f32 = 0.10;
const LAVA_WALL_BOOST: f32 = 0.30;
const LAVA_BOB_BOOST: f32 = 0.20;

const DRAG_X: f32 = 0.91;
const DRAG_Y: f32 = 0.98;
const DRAG_Z: f32 = 0.91;

const GROUND_FRICTION_X: f32 = 0.6;
const GROUND_FRICTION_Z: f32 = 0.6;

const GROUND_ACCEL: f32 = 0.1;
const AIR_ACCEL: f32 = 0.02;
const LIQUID_ACCEL: f32 = 0.02;

const WATER_DRAG: f32 = 0.8;
const LAVA_DRAG: f32 = 0.5;

const REPEAT_DELAY: f32 = 0.20;
const REPEAT_INTERVAL: f32 = 0.20;

const FLY_TAP_WINDOW: f32 = 0.25;

const BOB_BASE_UNIT: f32 = 2.5 / 16.0;
const BOB_HOR_SCALE: f32 = 0.3;
const BOB_VER_SCALE: f32 = 0.6;

const BOB_TILT_DEG: f32 = 0.15;
const BOB_TILT_X_GAIN: f32 = 3.0;

const BOB_WALK_THRESHOLD: f32 = 0.05;
const BOB_WALK_PHASE_RATE: f32 = 40.0;

const BOB_SWING_RATE: f32 = 3.0;
const BOB_STRENGTH_DECAY: f32 = 0.84;
const BOB_STRENGTH_GAIN: f32 = 0.1;
const BOB_STRENGTH_SUBSTEPS: u32 = 3;

const FALL_TILT_GAIN: f32 = 0.05;
const FALL_TILT_GRAVITY_OFFSET: f32 = 0.08;

camera: Camera,
pos_x: f32,
pos_y: f32,
pos_z: f32,
prev_x: f32,
prev_y: f32,
prev_z: f32,
vel_x: f32,
vel_y: f32,
vel_z: f32,
vel_y_prev: f32,
on_ground: bool,
hit_horizontal: bool,
can_liquid_jump: bool,
noclip: bool,
fly: bool,
tick_remainder: f32,

move_dir: [2]f32,
look_delta: [2]f32,
look_rate: [2]f32,
jumping: bool,
sneaking: bool,
mouse_captured: bool,
stick_look_speed: f32,

selected: ?RaycastHit,

hotbar: [HOTBAR_SLOTS]Block,
selected_slot: u8,

inventory_toggle_pending: bool,

shoulder_l_held: bool,
shoulder_r_held: bool,
pending_shoulder_break: bool,
pending_shoulder_place: bool,

break_held: bool,
place_held: bool,
break_repeat_timer: f32,
place_repeat_timer: f32,

playerlist_held: bool,
playerlist_edge: bool,
playerlist_edge_controller: bool,

hud_toggle_pending: bool,

rain_toggle_pending: bool,

chat_open_pending: bool,
chat_cmd_pending: bool,
fly_tap_event: ?FlyTapEvent,
jump_tap_count: u8,
jump_tap_elapsed: f32,

prev_inputs: PrevInputs,
// Suppresses held bindings when gameplay becomes the active context again.
gameplay_was_active: bool,

pending_block: ?PendingBlock,

writer: *std.Io.Writer,

particle_sink: ?*ParticleSystem,

held_renderer: ?*BlockHand,

walk_phase: f32,
walk_phase_prev: f32,
walk_swing: f32,
walk_swing_prev: f32,
bob_amount: f32,
bob_amount_prev: f32,

pub fn init(self: *Player, x: f32, y: f32, z: f32, writer: *std.Io.Writer) !void {
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
        .vel_y_prev = 0,
        .on_ground = false,
        .hit_horizontal = false,
        .can_liquid_jump = false,
        .noclip = false,
        .fly = false,
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
        .shoulder_l_held = false,
        .shoulder_r_held = false,
        .pending_shoulder_break = false,
        .pending_shoulder_place = false,
        .break_held = false,
        .place_held = false,
        .break_repeat_timer = 0,
        .place_repeat_timer = 0,
        .playerlist_held = false,
        .playerlist_edge = false,
        .playerlist_edge_controller = false,
        .hud_toggle_pending = false,
        .rain_toggle_pending = false,
        .chat_open_pending = false,
        .chat_cmd_pending = false,
        .fly_tap_event = null,
        .jump_tap_count = 0,
        .jump_tap_elapsed = 0,
        .prev_inputs = .{},
        .gameplay_was_active = false,
        .pending_block = null,
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
}

pub fn consume_fly_tap_event(self: *Player) ?FlyTapEvent {
    const event = self.fly_tap_event;
    self.fly_tap_event = null;
    return event;
}

pub fn clear_fly_tap_state(self: *Player) void {
    self.fly_tap_event = null;
    self.reset_jump_taps();
}

pub fn toggle_fly(self: *Player) void {
    self.set_fly(!self.fly);
}

pub fn set_fly(self: *Player, enabled: bool) void {
    if (self.fly == enabled) return;

    self.fly = enabled;
    self.vel_x = 0;
    self.vel_y = 0;
    self.vel_z = 0;
    self.vel_y_prev = 0;
    self.tick_remainder = 0;
    self.hit_horizontal = false;
    self.can_liquid_jump = false;

    if (!enabled) {
        self.on_ground = collision.on_ground(self.pos_x, self.pos_y, self.pos_z);
    }
}

pub fn update(self: *Player, sys: *input.InputSystem, dt: f32) void {
    assert(dt >= 0);

    self.mouse_captured = sys.effective_cursor_mode() == .captured;

    self.poll_inputs(sys, dt);

    // Process deferred gamepad shoulder actions. The one-frame delay lets
    // a same-frame L+R chord cancel the pending break/place before it fires.
    if (self.pending_shoulder_break) {
        self.pending_shoulder_break = false;
        if (!self.shoulder_l_held) {
            self.break_repeat_timer = 0;
            self.do_break();
        }
    }
    if (self.pending_shoulder_place) {
        self.pending_shoulder_place = false;
        if (!self.shoulder_r_held) {
            self.place_repeat_timer = 0;
            self.do_place();
        }
    }

    // Hold-to-repeat: tick timers while either the mouse/keyboard button
    // or the corresponding gamepad shoulder button is held. The initial
    // press already fired via the rising-edge poll; the timer handles repeats.
    const break_any_held = self.break_held or (self.shoulder_r_held and !self.shoulder_l_held);
    const place_any_held = self.place_held or (self.shoulder_l_held and !self.shoulder_r_held);
    if (break_any_held) {
        self.break_repeat_timer += dt;
        if (self.break_repeat_timer >= REPEAT_DELAY) {
            self.break_repeat_timer -= REPEAT_INTERVAL;
            self.do_break();
        }
    } else {
        self.break_repeat_timer = 0;
    }
    if (place_any_held) {
        self.place_repeat_timer += dt;
        if (self.place_repeat_timer >= REPEAT_DELAY) {
            self.place_repeat_timer -= REPEAT_INTERVAL;
            self.do_place();
        }
    } else {
        self.place_repeat_timer = 0;
    }

    self.apply_look(dt);

    if (self.noclip) {
        self.update_noclip(dt);
    } else if (self.fly) {
        self.update_fly(dt);
    } else {
        self.run_ticks(dt);
    }

    self.sync_camera();
    self.selected = self.raycast_block(REACH);
}

fn apply_look(self: *Player, dt: f32) void {
    if (self.mouse_captured) {
        self.camera.yaw -= self.look_delta[0];
        self.camera.pitch += self.look_delta[1];
    }
    self.look_delta = .{ 0, 0 };

    if (self.mouse_captured) {
        const look_rate = if (comptime ae.platform == .nintendo_3ds)
            self.look_rate
        else
            apply_stick_curve(self.look_rate);
        self.camera.yaw -= look_rate[0] * self.stick_look_speed * dt;
        self.camera.pitch += look_rate[1] * self.stick_look_speed * dt;
    }

    const max_pitch = std.math.pi / 2.0 - 0.01;
    self.camera.pitch = @max(-max_pitch, @min(max_pitch, self.camera.pitch));
}

fn apply_stick_curve(raw: [2]f32) [2]f32 {
    const exponent: f32 = 2.2;
    const mag_sq = raw[0] * raw[0] + raw[1] * raw[1];
    if (mag_sq < 1e-10) return .{ 0, 0 };
    const mag = @sqrt(mag_sq);
    const scale = std.math.pow(f32, @min(mag, 1.0), exponent) / mag;
    return .{ raw[0] * scale, raw[1] * scale };
}

fn update_noclip(self: *Player, dt: f32) void {
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

    self.prev_x = self.pos_x;
    self.prev_y = self.pos_y;
    self.prev_z = self.pos_z;
}

fn update_fly(self: *Player, dt: f32) void {
    const clamped = @min(dt, MAX_FRAME_DT);
    const sin_yaw = @sin(self.camera.yaw);
    const cos_yaw = @cos(self.camera.yaw);
    const strafe = self.move_dir[0];
    const forward = self.move_dir[1];

    const dx = (strafe * cos_yaw - forward * sin_yaw) * FLY_SPEED * clamped;
    const dz = (-strafe * sin_yaw - forward * cos_yaw) * FLY_SPEED * clamped;

    var dy: f32 = 0;
    if (self.jumping) dy += FLY_SPEED * clamped;
    if (self.sneaking) dy -= FLY_SPEED * clamped;

    const result = collision.move_and_collide(
        self.pos_x,
        self.pos_y,
        self.pos_z,
        dx,
        dy,
        dz,
        false,
    );

    self.pos_x = result.x;
    self.pos_y = result.y;
    self.pos_z = result.z;
    self.on_ground = result.on_ground;
    self.hit_horizontal = result.hit_x or result.hit_z;

    self.vel_x = 0;
    self.vel_y = 0;
    self.vel_z = 0;
    self.vel_y_prev = 0;

    self.prev_x = self.pos_x;
    self.prev_y = self.pos_y;
    self.prev_z = self.pos_z;
}

fn run_ticks(self: *Player, dt: f32) void {
    const clamped = @min(dt, MAX_FRAME_DT);
    self.tick_remainder += clamped;

    while (self.tick_remainder >= TICK) {
        self.tick_remainder -= TICK;
        self.physics_tick();
    }
}

/// One Classic physics tick. Order matches the spec:
/// input -> vertical state -> accel -> collide+integrate -> drag -> gravity -> friction
fn physics_tick(self: *Player) void {
    self.prev_x = self.pos_x;
    self.prev_y = self.pos_y;
    self.prev_z = self.pos_z;
    self.vel_y_prev = self.vel_y;

    const strafe = self.move_dir[0] * 0.98;
    const forward = self.move_dir[1] * 0.98;
    const sin_yaw = @sin(self.camera.yaw);
    const cos_yaw = @cos(self.camera.yaw);
    const head_x = strafe * cos_yaw - forward * sin_yaw;
    const head_z = -strafe * sin_yaw - forward * cos_yaw;

    const liq_feet = collision.liquid_feet(self.pos_x, self.pos_y, self.pos_z);
    const liq_body = collision.liquid_body(self.pos_x, self.pos_y, self.pos_z);
    const any_liquid: ?collision.Liquid = liq_feet orelse liq_body;

    self.update_vertical_state(liq_feet, liq_body);

    const accel: f32 = if (any_liquid != null) LIQUID_ACCEL else if (self.on_ground) GROUND_ACCEL else AIR_ACCEL;
    var dist = @sqrt(head_x * head_x + head_z * head_z);
    if (dist < 1.0) dist = 1.0;
    self.vel_x += head_x * (accel / dist);
    self.vel_z += head_z * (accel / dist);

    self.collide_and_move(any_liquid);

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

    self.vel_y -= if (any_liquid != null) LIQUID_GRAVITY else GRAVITY;

    if (self.on_ground and any_liquid == null) {
        self.vel_x *= GROUND_FRICTION_X;
        self.vel_z *= GROUND_FRICTION_Z;
    }

    self.advance_view_bob();
}

fn advance_view_bob(self: *Player) void {
    self.walk_phase_prev = self.walk_phase;
    self.walk_swing_prev = self.walk_swing;
    self.bob_amount_prev = self.bob_amount;

    const dx = self.pos_x - self.prev_x;
    const dz = self.pos_z - self.prev_z;
    const dist = @sqrt(dx * dx + dz * dz);

    if (dist > BOB_WALK_THRESHOLD) {
        const phase_before = self.walk_phase;
        self.walk_phase += dist * BOB_WALK_PHASE_RATE * TICK;
        self.walk_swing += BOB_SWING_RATE * TICK;

        if (self.on_ground) {
            const prev_idx = @as(u32, @intFromFloat(@floor(phase_before / std.math.pi)));
            const curr_idx = @as(u32, @intFromFloat(@floor(self.walk_phase / std.math.pi)));
            if (curr_idx != prev_idx) {
                const foot = block_under_feet(self);
                if (!foot.is_air()) SoundManager.play_step(foot);
            }
        }
    } else {
        self.walk_swing -= BOB_SWING_RATE * TICK;
    }
    self.walk_swing = std.math.clamp(self.walk_swing, 0.0, 1.0);

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

fn compute_view_bob(self: *const Player, alpha: f32) ViewBob {
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

    const vy = self.vel_y_prev + (self.vel_y - self.vel_y_prev) * alpha;
    const fall = -(vy + FALL_TILT_GRAVITY_OFFSET) * FALL_TILT_GAIN;

    const tilt = Math.Mat4.rotationZ(roll_z)
        .mul(Math.Mat4.rotationX(pitch_x))
        .mul(Math.Mat4.rotationX(fall));

    return .{ .hor = hor, .ver = ver, .tilt = tilt };
}

fn update_vertical_state(
    self: *Player,
    liq_feet: ?collision.Liquid,
    liq_body: ?collision.Liquid,
) void {
    const any_liquid = liq_feet orelse liq_body;

    if (any_liquid == null) {
        if (self.jumping and self.on_ground) {
            self.vel_y = JUMP_VEL;
            self.on_ground = false;
        }
        return;
    }

    if (!self.jumping) return;

    const past_jump_point = liq_feet != null and liq_body == null and
        frac(self.pos_y) >= 0.4;

    if (!past_jump_point) {
        self.vel_y += LIQUID_SWIM_UP;
        self.can_liquid_jump = true;
        return;
    }

    if (!self.can_liquid_jump) return;
    self.can_liquid_jump = false;

    const is_water = (liq_feet.? == .water);
    if (self.hit_horizontal) {
        self.vel_y += if (is_water) WATER_WALL_BOOST else LAVA_WALL_BOOST;
    } else {
        self.vel_y += if (is_water) WATER_BOB_BOOST else LAVA_BOB_BOOST;
    }
}

fn frac(v: f32) f32 {
    return v - @floor(v);
}

fn block_under_feet(self: *const Player) Block {
    const by_f = @floor(self.pos_y - 0.01);
    const bx_f = @floor(self.pos_x);
    const bz_f = @floor(self.pos_z);
    const dims = World.data.dims;
    if (by_f < 0 or by_f >= @as(f32, @floatFromInt(dims.height))) return .air;
    if (bx_f < 0 or bx_f >= @as(f32, @floatFromInt(dims.length))) return .air;
    if (bz_f < 0 or bz_f >= @as(f32, @floatFromInt(dims.depth))) return .air;
    return World.data.get_block(
        @intCast(@as(i32, @intFromFloat(bx_f))),
        @intCast(@as(i32, @intFromFloat(by_f))),
        @intCast(@as(i32, @intFromFloat(bz_f))),
    );
}

fn collide_and_move(self: *Player, liquid: ?collision.Liquid) void {
    const was_on_ground = self.on_ground;

    var result = collision.move_and_collide(
        self.pos_x,
        self.pos_y,
        self.pos_z,
        self.vel_x,
        self.vel_y,
        self.vel_z,
        was_on_ground,
    );

    self.hit_horizontal = result.hit_x or result.hit_z;

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

    if (self.pending_block) |pb| {
        if (!World.data.get_block(pb.x, pb.y, pb.z).is_air()) {
            self.pending_block = null;
        } else {
            const bh = pb.block.collision_height();
            const block_top: f32 = @as(f32, @floatFromInt(pb.y)) + bh;
            const bx0: f32 = @floatFromInt(pb.x);
            const bz0: f32 = @floatFromInt(pb.z);
            const xz_over = result.x + collision.HALF_W > bx0 and
                result.x - collision.HALF_W < bx0 + 1.0 and
                result.z + collision.HALF_W > bz0 and
                result.z - collision.HALF_W < bz0 + 1.0;
            if (xz_over and self.pos_y >= block_top and result.y < block_top) {
                result.y = block_top;
                result.on_ground = true;
            }
        }
    }

    self.pos_x = result.x;
    self.pos_y = result.y;
    self.pos_z = result.z;

    if (result.hit_x) self.vel_x = 0;
    if (result.hit_z) self.vel_z = 0;
    if (result.on_ground and self.vel_y < 0) self.vel_y = 0;
    if (result.hit_y_above and self.vel_y > 0) self.vel_y = 0;

    self.on_ground = result.on_ground;
}

fn sync_camera(self: *Player) void {
    if (self.noclip or self.fly) {
        self.camera.x = self.pos_x;
        self.camera.y = self.pos_y + collision.EYE_HEIGHT;
        self.camera.z = self.pos_z;
        self.camera.tilt = Math.Mat4.identity();
        self.camera.bob_hor = 0;
        self.camera.bob_ver = 0;
        return;
    }
    const alpha = self.tick_remainder / TICK;
    self.camera.x = self.prev_x + (self.pos_x - self.prev_x) * alpha;
    self.camera.y = (self.prev_y + (self.pos_y - self.prev_y) * alpha) + collision.EYE_HEIGHT;
    self.camera.z = self.prev_z + (self.pos_z - self.prev_z) * alpha;

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

/// Amanatides-Woo voxel traversal using fixed-point distances.
pub fn raycast_block(self: *const Player, range: f32) ?RaycastHit {
    assert(range >= 0.0);
    assert(range <= 64.0);

    const cp = @cos(self.camera.pitch);
    const dir_x = to_fp(-@sin(self.camera.yaw) * cp);
    const dir_y = to_fp(-@sin(self.camera.pitch));
    const dir_z = to_fp(-@cos(self.camera.yaw) * cp);

    const fp_ox = to_fp(self.camera.x);
    const fp_oy = to_fp(self.camera.y);
    const fp_oz = to_fp(self.camera.z);

    const fx = @floor(self.camera.x);
    const fy = @floor(self.camera.y);
    const fz = @floor(self.camera.z);
    if (fx < -2147483648.0 or fx > 2147483647.0) return null;
    if (fy < -2147483648.0 or fy > 2147483647.0) return null;
    if (fz < -2147483648.0 or fz > 2147483647.0) return null;
    var bx: i32 = @intFromFloat(fx);
    var by: i32 = @intFromFloat(fy);
    var bz: i32 = @intFromFloat(fz);

    const step_x: i32 = if (dir_x > 0) 1 else if (dir_x < 0) -1 else 0;
    const step_y: i32 = if (dir_y > 0) 1 else if (dir_y < 0) -1 else 0;
    const step_z: i32 = if (dir_z > 0) 1 else if (dir_z < 0) -1 else 0;

    const adx: i32 = @intCast(@abs(dir_x));
    const ady: i32 = @intCast(@abs(dir_y));
    const adz: i32 = @intCast(@abs(dir_z));

    const frac_x = fp_ox - (bx <<| FRAC);
    const frac_y = fp_oy - (by <<| FRAC);
    const frac_z = fp_oz - (bz <<| FRAC);

    var dist_x: i32 = if (step_x > 0) ONE - frac_x else if (step_x < 0) frac_x else std.math.maxInt(i32);
    var dist_y: i32 = if (step_y > 0) ONE - frac_y else if (step_y < 0) frac_y else std.math.maxInt(i32);
    var dist_z: i32 = if (step_z > 0) ONE - frac_z else if (step_z < 0) frac_z else std.math.maxInt(i32);

    const range_fp: i32 = to_fp(range);

    if (in_world(bx, by, bz)) {
        if (is_selectable(@intCast(bx), @intCast(by), @intCast(bz))) {
            const bounds = World.data.get_block(@intCast(bx), @intCast(by), @intCast(bz)).bounds();
            if (point_in_bounds_fp(frac_x, frac_y, frac_z, bounds)) {
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
    }

    const max_iters: u32 = 64;
    var i: u32 = 0;
    while (i < max_iters) : (i += 1) {
        if (t_exceeds_range(dist_x, adx, dist_y, ady, dist_z, adz, range_fp)) return null;

        const prev_x = bx;
        const prev_y = by;
        const prev_z = bz;

        // t_max_a <= t_max_b <-> dist_a * abs_b <= dist_b * abs_a (cross multiply).
        if (t_le(dist_x, adx, dist_y, ady) and t_le(dist_x, adx, dist_z, adz)) {
            bx += step_x;
            dist_x += ONE;
        } else if (t_le(dist_y, ady, dist_z, adz)) {
            by += step_y;
            dist_y += ONE;
        } else {
            bz += step_z;
            dist_z += ONE;
        }

        if (!in_world(bx, by, bz)) continue;
        if (!is_selectable(@intCast(bx), @intCast(by), @intCast(bz))) continue;

        const block = World.data.get_block(@intCast(bx), @intCast(by), @intCast(bz));
        const bounds = block.bounds();

        if (bounds.is_full()) {
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

        // Partial block: integer slab test against the subvoxel AABB.
        if (ray_sub_aabb_fp(fp_ox, fp_oy, fp_oz, dir_x, dir_y, dir_z, bx, by, bz, bounds, range_fp)) |face| {
            const off = face_normal(face);
            const px = bx + off[0];
            const py = by + off[1];
            const pz = bz + off[2];
            const has_place = in_world(px, py, pz);
            return .{
                .x = @intCast(bx),
                .y = @intCast(by),
                .z = @intCast(bz),
                .place_x = if (has_place) @intCast(px) else @intCast(bx),
                .place_y = if (has_place) @intCast(py) else @intCast(by),
                .place_z = if (has_place) @intCast(pz) else @intCast(bz),
                .has_place = has_place,
            };
        }
    }
    return null;
}

const FRAC: u5 = 8;
const ONE: i32 = 1 << FRAC;

fn to_fp(f: f32) i32 {
    return @intFromFloat(f * @as(f32, @floatFromInt(ONE)));
}

fn t_le(dist_a: i32, abs_a: i32, dist_b: i32, abs_b: i32) bool {
    if (abs_a == 0) return false;
    if (abs_b == 0) return true;
    return @as(i64, dist_a) * @as(i64, abs_b) <= @as(i64, dist_b) * @as(i64, abs_a);
}

fn t_exceeds_range(dx: i32, adx: i32, dy: i32, ady: i32, dz: i32, adz: i32, range_fp: i32) bool {
    const xv = adx != 0 and @as(i64, dx) * ONE <= @as(i64, range_fp) * @as(i64, adx);
    const yv = ady != 0 and @as(i64, dy) * ONE <= @as(i64, range_fp) * @as(i64, ady);
    const zv = adz != 0 and @as(i64, dz) * ONE <= @as(i64, range_fp) * @as(i64, adz);
    return !xv and !yv and !zv;
}

fn in_world(x: i32, y: i32, z: i32) bool {
    const dims = World.data.dims;
    return x >= 0 and y >= 0 and z >= 0 and
        x < @as(i32, @intCast(dims.length)) and
        y < @as(i32, @intCast(dims.height)) and
        z < @as(i32, @intCast(dims.depth));
}

fn is_selectable(x: u16, y: u16, z: u16) bool {
    return World.data.get_block(x, y, z).is_selectable();
}

fn point_in_bounds_fp(lx: i32, ly: i32, lz: i32, b: blocks.SubvoxelBounds) bool {
    const STEP = ONE / 16;
    return lx >= @as(i32, b.min_x) * STEP and
        lx < @as(i32, b.max_x) * STEP and
        ly >= @as(i32, b.min_y) * STEP and
        ly < @as(i32, b.max_y) * STEP and
        lz >= @as(i32, b.min_z) * STEP and
        lz < @as(i32, b.max_z) * STEP;
}

fn ray_sub_aabb_fp(
    ox: i32,
    oy: i32,
    oz: i32,
    dx: i32,
    dy: i32,
    dz: i32,
    bx: i32,
    by: i32,
    bz: i32,
    bounds: blocks.SubvoxelBounds,
    max_t_fp: i32,
) ?Face {
    const STEP = ONE / 16;
    const bx_fp = bx <<| FRAC;
    const by_fp = by <<| FRAC;
    const bz_fp = bz <<| FRAC;

    const x0 = bx_fp + @as(i32, bounds.min_x) * STEP;
    const y0 = by_fp + @as(i32, bounds.min_y) * STEP;
    const z0 = bz_fp + @as(i32, bounds.min_z) * STEP;
    const x1 = bx_fp + @as(i32, bounds.max_x) * STEP;
    const y1 = by_fp + @as(i32, bounds.max_y) * STEP;
    const z1 = bz_fp + @as(i32, bounds.max_z) * STEP;

    const MAX: i32 = std.math.maxInt(i32);
    const MIN: i32 = std.math.minInt(i32);
    var t_near: i32 = MIN;
    var t_far: i32 = MAX;
    var face: Face = .y_pos;

    if (dx != 0) {
        const t0 = fp_div(x0 - ox, dx);
        const t1 = fp_div(x1 - ox, dx);
        const t_lo = @min(t0, t1);
        const t_hi = @max(t0, t1);
        if (t_lo > t_near) {
            t_near = t_lo;
            face = if (dx > 0) .x_neg else .x_pos;
        }
        t_far = @min(t_far, t_hi);
    } else {
        if (ox < x0 or ox >= x1) return null;
    }

    if (dy != 0) {
        const t0 = fp_div(y0 - oy, dy);
        const t1 = fp_div(y1 - oy, dy);
        const t_lo = @min(t0, t1);
        const t_hi = @max(t0, t1);
        if (t_lo > t_near) {
            t_near = t_lo;
            face = if (dy > 0) .y_neg else .y_pos;
        }
        t_far = @min(t_far, t_hi);
    } else {
        if (oy < y0 or oy >= y1) return null;
    }

    if (dz != 0) {
        const t0 = fp_div(z0 - oz, dz);
        const t1 = fp_div(z1 - oz, dz);
        const t_lo = @min(t0, t1);
        const t_hi = @max(t0, t1);
        if (t_lo > t_near) {
            t_near = t_lo;
            face = if (dz > 0) .z_neg else .z_pos;
        }
        t_far = @min(t_far, t_hi);
    } else {
        if (oz < z0 or oz >= z1) return null;
    }

    if (t_near > t_far) return null;
    if (t_far < 0) return null;
    if (t_near > max_t_fp) return null;

    return face;
}

fn fp_div(num: i32, den: i32) i32 {
    if (den == 0) return if (num >= 0) std.math.maxInt(i32) else std.math.minInt(i32);
    const wide = @divTrunc(@as(i64, num) <<| FRAC, @as(i64, den));
    return @intCast(std.math.clamp(wide, std.math.minInt(i32), std.math.maxInt(i32)));
}

fn face_normal(face: Face) [3]i32 {
    return switch (face) {
        .x_neg => .{ -1, 0, 0 },
        .x_pos => .{ 1, 0, 0 },
        .y_neg => .{ 0, -1, 0 },
        .y_pos => .{ 0, 1, 0 },
        .z_neg => .{ 0, 0, -1 },
        .z_pos => .{ 0, 0, 1 },
    };
}

pub fn draw_ui_into(
    self: *Player,
    list: *UiDrawList,
    gui: *const Rendering.Texture,
    hide_crosshair: bool,
    hud_y_shift: i16,
) void {
    assert(self.selected_slot < HOTBAR_SLOTS);

    if (!hide_crosshair) {
        list.add_sprite(&.{
            .texture = gui,
            .pos_offset = .{ .x = 0, .y = 0 },
            .pos_extent = .{ .x = 16, .y = 16 },
            .tex_offset = .{ .x = 240, .y = 0 },
            .tex_extent = .{ .x = 16, .y = 16 },
            .color = Colors.white_fg,
            .layer = 255,
            .reference = .middle_center,
            .origin = .middle_center,
        });
    }

    list.add_sprite(&.{
        .texture = gui,
        .pos_offset = .{ .x = 0, .y = -1 - hud_y_shift },
        .pos_extent = .{ .x = HOTBAR_W, .y = HOTBAR_H },
        .tex_offset = .{ .x = HOTBAR_TEX_X, .y = HOTBAR_TEX_Y },
        .tex_extent = .{ .x = HOTBAR_W, .y = HOTBAR_H },
        .color = Colors.white_fg,
        .layer = HOTBAR_BG_LAYER,
        .reference = .bottom_center,
        .origin = .bottom_center,
    });

    const slot_i: i16 = @intCast(self.selected_slot);
    const sel_x: i16 = HOTBAR_SLOT_STRIDE * slot_i - 80;
    list.add_sprite(&.{
        .texture = gui,
        .pos_offset = .{ .x = sel_x, .y = -hud_y_shift },
        .pos_extent = .{ .x = SELECTOR_SIZE, .y = SELECTOR_SIZE },
        .tex_offset = .{ .x = SELECTOR_TEX_X, .y = SELECTOR_TEX_Y },
        .tex_extent = .{ .x = SELECTOR_SIZE, .y = SELECTOR_SIZE },
        .color = Colors.white_fg,
        .layer = SELECTOR_LAYER,
        .reference = .bottom_center,
        .origin = .bottom_center,
    });

    self.draw_hotbar_blocks(list, hud_y_shift);
}

const HOTBAR_BLOCK_HALF_EXTENT: f32 = 3.5;

fn draw_hotbar_blocks(self: *const Player, list: *UiDrawList, hud_y_shift: i16) void {
    const screen_w = Rendering.gfx.surface.get_width();
    const screen_h = Rendering.gfx.surface.get_height();
    const ui_scale = Scaling.compute(screen_w, screen_h);
    const max_lx: i32 = @intCast(layout.logical_width(screen_w, ui_scale));
    const max_ly: i32 = @intCast(layout.logical_height(screen_h, ui_scale));

    const hotbar_top: f32 = @floatFromInt(max_ly - 1 - @as(i32, hud_y_shift) - @as(i32, HOTBAR_H));
    const slot_cy: f32 = hotbar_top + 11.0;
    const center_x: f32 = @floatFromInt(@divTrunc(max_lx, 2));

    var i: u8 = 0;
    while (i < HOTBAR_SLOTS) : (i += 1) {
        const slot_offset_x: f32 = @floatFromInt(@as(i32, HOTBAR_SLOT_STRIDE) * @as(i32, i) - 80);
        list.add_iso_block(&.{
            .block = self.hotbar[i],
            .cx = center_x + slot_offset_x,
            .cy = slot_cy,
            .half_extent_px = HOTBAR_BLOCK_HALF_EXTENT,
        });
    }
}

fn poll_inputs(self: *Player, sys: *input.InputSystem, dt: f32) void {
    const actions = bindings.actions();
    const active_now = is_gameplay_active(sys);
    const fresh_activation = active_now and !self.gameplay_was_active;
    self.gameplay_was_active = active_now;
    self.age_jump_taps(dt);

    self.move_dir = sys.vector2(actions.move).current;

    const look_raw = sys.vector2(actions.look).current;
    const sens = Options.current.sensitivity * LOOK_PIXEL_TO_RAD;
    self.look_delta = .{ look_raw[0] * sens, look_raw[1] * sens };

    self.look_rate = sys.vector2(actions.look_stick).current;
    const jump = sys.button(actions.jump).current;
    self.jumping = jump == .pressed;
    self.sneaking = sys.button(actions.sneak).current == .pressed;

    const br = sys.button(actions.break_).current;
    const pl = sys.button(actions.place).current;
    self.break_held = br == .pressed;
    self.place_held = pl == .pressed;
    if (Options.uses_old_3ds_controls() and self.break_held and self.place_held) {
        self.break_held = false;
        self.place_held = false;
    }
    self.shoulder_r_held = sys.button(actions.shoulder_r).current == .pressed;
    self.shoulder_l_held = sys.button(actions.shoulder_l).current == .pressed;
    self.playerlist_held = sys.button(actions.playerlist).current == .pressed;

    if (fresh_activation) {
        self.prev_inputs.inventory_toggle = sys.button(actions.inventory_toggle).current;
        if (comptime builtin.mode == .Debug and ae.platform != .psp) {
            self.prev_inputs.noclip = sys.button(actions.noclip).current;
        }
        self.prev_inputs.jump = jump;
        self.prev_inputs.break_ = br;
        self.prev_inputs.place = pl;
        self.prev_inputs.pick_block = sys.button(actions.pick_block).current;
        self.prev_inputs.shoulder_r = sys.button(actions.shoulder_r).current;
        self.prev_inputs.shoulder_l = sys.button(actions.shoulder_l).current;
        self.prev_inputs.playerlist = sys.button(actions.playerlist).current;
        if (ae.platform != .psp) {
            self.prev_inputs.hud_toggle = sys.button(actions.hud_toggle).current;
            self.prev_inputs.rain_toggle = sys.button(actions.rain_toggle).current;
        }
        self.prev_inputs.chat_open = sys.button(actions.chat_open).current;
        self.prev_inputs.chat_cmd = sys.button(actions.chat_cmd).current;
        self.prev_inputs.hotbar_left = sys.button(actions.hotbar_left).current;
        self.prev_inputs.hotbar_right = sys.button(actions.hotbar_right).current;
        inline for (0..9) |i| {
            self.prev_inputs.hotbar_slot[i] = sys.button(actions.hotbar_slot[i]).current;
        }
        self.reset_jump_taps();
        return;
    }

    if (rising_edge(self.prev_inputs.jump, jump)) self.record_jump_tap();
    self.prev_inputs.jump = jump;

    const inv = sys.button(actions.inventory_toggle).current;
    if (rising_edge(self.prev_inputs.inventory_toggle, inv)) {
        self.inventory_toggle_pending = true;
    }
    self.prev_inputs.inventory_toggle = inv;

    if (comptime builtin.mode == .Debug and ae.platform != .psp) {
        const nc = sys.button(actions.noclip).current;
        if (rising_edge(self.prev_inputs.noclip, nc)) {
            self.noclip = !self.noclip;
            if (self.noclip) {
                self.vel_x = 0;
                self.vel_y = 0;
                self.vel_z = 0;
            } else {
                self.on_ground = collision.on_ground(self.pos_x, self.pos_y, self.pos_z);
            }
        }
        self.prev_inputs.noclip = nc;
    }

    if (Options.uses_old_3ds_controls()) {
        const both_held = br == .pressed and pl == .pressed;
        const break_pressed = rising_edge(self.prev_inputs.break_, br);
        const place_pressed = rising_edge(self.prev_inputs.place, pl);
        self.break_held = br == .pressed and !both_held;
        self.place_held = pl == .pressed and !both_held;

        if (both_held and (break_pressed or place_pressed)) {
            self.inventory_toggle_pending = true;
            self.break_repeat_timer = 0;
            self.place_repeat_timer = 0;
        } else {
            if (break_pressed) {
                self.break_repeat_timer = 0;
                self.do_break();
            }
            if (place_pressed) {
                self.place_repeat_timer = 0;
                self.do_place();
            }
        }
    } else {
        self.break_held = br == .pressed;
        if (rising_edge(self.prev_inputs.break_, br)) {
            self.break_repeat_timer = 0;
            self.do_break();
        }

        self.place_held = pl == .pressed;
        if (rising_edge(self.prev_inputs.place, pl)) {
            self.place_repeat_timer = 0;
            self.do_place();
        }
    }
    self.prev_inputs.break_ = br;
    self.prev_inputs.place = pl;

    const pb = sys.button(actions.pick_block).current;
    if (rising_edge(self.prev_inputs.pick_block, pb)) {
        self.do_pick_block();
    }
    self.prev_inputs.pick_block = pb;

    const sr = sys.button(actions.shoulder_r).current;
    self.shoulder_r_held = sr == .pressed;
    if (rising_edge(self.prev_inputs.shoulder_r, sr)) {
        if (self.shoulder_l_held) {
            self.inventory_toggle_pending = true;
            self.pending_shoulder_break = false;
            self.pending_shoulder_place = false;
        } else {
            self.pending_shoulder_break = true;
        }
    }
    self.prev_inputs.shoulder_r = sr;

    const sl = sys.button(actions.shoulder_l).current;
    self.shoulder_l_held = sl == .pressed;
    if (rising_edge(self.prev_inputs.shoulder_l, sl)) {
        if (self.shoulder_r_held) {
            self.inventory_toggle_pending = true;
            self.pending_shoulder_break = false;
            self.pending_shoulder_place = false;
        } else {
            self.pending_shoulder_place = true;
        }
    }
    self.prev_inputs.shoulder_l = sl;

    const pll = sys.button(actions.playerlist).current;
    self.playerlist_held = pll == .pressed;
    if (rising_edge(self.prev_inputs.playerlist, pll)) {
        self.playerlist_edge = true;
        self.playerlist_edge_controller = playerlist_controller_pressed_this_frame(sys);
    }
    self.prev_inputs.playerlist = pll;

    if (ae.platform != .psp) {
        const hud = sys.button(actions.hud_toggle).current;
        if (rising_edge(self.prev_inputs.hud_toggle, hud)) self.hud_toggle_pending = true;
        self.prev_inputs.hud_toggle = hud;

        const rain = sys.button(actions.rain_toggle).current;
        if (rising_edge(self.prev_inputs.rain_toggle, rain)) self.rain_toggle_pending = true;
        self.prev_inputs.rain_toggle = rain;
    }

    const co = sys.button(actions.chat_open).current;
    if (rising_edge(self.prev_inputs.chat_open, co)) self.chat_open_pending = true;
    self.prev_inputs.chat_open = co;

    const cc = sys.button(actions.chat_cmd).current;
    if (rising_edge(self.prev_inputs.chat_cmd, cc)) self.chat_cmd_pending = true;
    self.prev_inputs.chat_cmd = cc;

    const hl = sys.button(actions.hotbar_left).current;
    if (rising_edge(self.prev_inputs.hotbar_left, hl)) {
        self.selected_slot = if (self.selected_slot == 0) HOTBAR_SLOTS - 1 else self.selected_slot - 1;
    }
    self.prev_inputs.hotbar_left = hl;

    const hr = sys.button(actions.hotbar_right).current;
    if (rising_edge(self.prev_inputs.hotbar_right, hr)) {
        self.selected_slot = if (self.selected_slot + 1 >= HOTBAR_SLOTS) 0 else self.selected_slot + 1;
    }
    self.prev_inputs.hotbar_right = hr;

    inline for (0..9) |i| {
        const cur = sys.button(actions.hotbar_slot[i]).current;
        if (rising_edge(self.prev_inputs.hotbar_slot[i], cur)) {
            self.selected_slot = @intCast(i);
        }
        self.prev_inputs.hotbar_slot[i] = cur;
    }

    const scroll = sys.axis(actions.hotbar_scroll).current;
    if (scroll > HOTBAR_SCROLL_DEADBAND) {
        self.selected_slot = if (self.selected_slot == 0) HOTBAR_SLOTS - 1 else self.selected_slot - 1;
    } else if (scroll < -HOTBAR_SCROLL_DEADBAND) {
        self.selected_slot = if (self.selected_slot + 1 >= HOTBAR_SLOTS) 0 else self.selected_slot + 1;
    }
}

fn age_jump_taps(self: *Player, dt: f32) void {
    if (self.jump_tap_count == 0) return;
    self.jump_tap_elapsed += dt;
    if (self.jump_tap_elapsed > FLY_TAP_WINDOW) self.reset_jump_taps();
}

fn record_jump_tap(self: *Player) void {
    if (self.jump_tap_count == 0) {
        self.jump_tap_count = 1;
        self.jump_tap_elapsed = 0;
        return;
    }

    self.jump_tap_count += 1;
    self.jump_tap_elapsed = 0;
    if (self.jump_tap_count == 2) {
        self.fly_tap_event = .double;
    } else {
        self.fly_tap_event = .triple;
        self.reset_jump_taps();
    }
}

fn reset_jump_taps(self: *Player) void {
    self.jump_tap_count = 0;
    self.jump_tap_elapsed = 0;
}

fn is_gameplay_active(sys: *input.InputSystem) bool {
    const top = sys.stack_top() orelse return false;
    const set = bindings.handle() orelse return false;
    return @intFromEnum(top.actions) == @intFromEnum(set);
}

fn playerlist_controller_button() input.Button {
    if (ae.platform == .psp or Options.uses_old_3ds_controls()) {
        return switch (Options.current.psp_jump_mode) {
            .up => .Back,
            .select => .DpadUp,
        };
    }
    return .Back;
}

fn playerlist_controller_pressed_this_frame(sys: *input.InputSystem) bool {
    const button = playerlist_controller_button();
    for (sys.frame_events()) |ev| {
        switch (ev.kind) {
            .gamepad_button_down => |b| if (b.button == button) return true,
            else => {},
        }
    }
    return false;
}

fn do_break(self: *Player) void {
    if (!self.mouse_captured) return;
    if (self.held_renderer) |hr| hr.trigger_dig();
    const hit = self.selected orelse return;
    const block_id = World.data.get_block(hit.x, hit.y, hit.z);
    if (!block_id.is_breakable()) return;
    if (!block_id.is_air()) {
        if (self.particle_sink) |ps| {
            ps.spawn_break(block_id, hit.x, hit.y, hit.z);
        }
        SoundManager.play_dig(block_id, hit.x, hit.y, hit.z);
    }
    send_block_change(self.writer, hit.x, hit.y, hit.z, 0, .air);
}

fn do_pick_block(self: *Player) void {
    if (!self.mouse_captured) return;
    const hit = self.selected orelse return;
    const block = World.data.get_block(hit.x, hit.y, hit.z);
    if (!block.in_inventory()) return;

    assert(self.selected_slot < HOTBAR_SLOTS);
    if (self.hotbar[self.selected_slot] == block) return;

    var i: u8 = 0;
    while (i < HOTBAR_SLOTS) : (i += 1) {
        if (self.hotbar[i] == block) {
            self.selected_slot = i;
            return;
        }
    }

    self.hotbar[self.selected_slot] = block;
}

fn do_place(self: *Player) void {
    if (!self.mouse_captured) return;
    const hit = self.selected orelse return;
    if (!hit.has_place) return;
    assert(self.selected_slot < HOTBAR_SLOTS);
    const block = self.hotbar[self.selected_slot];
    if (block.is_air()) return;
    const target = World.data.get_block(hit.place_x, hit.place_y, hit.place_z);
    const target_replaceable = target.is_place_replaceable();
    const promotes_to_double_slab = block == .slab and
        (target == .slab or (target_replaceable and hit.place_y > 0 and
            World.data.get_block(hit.place_x, hit.place_y - 1, hit.place_z) == .slab));
    if (!target_replaceable and !promotes_to_double_slab) return;
    const bx0: f32 = @floatFromInt(hit.place_x);
    const by0: f32 = @floatFromInt(hit.place_y);
    const bz0: f32 = @floatFromInt(hit.place_z);
    const bh: f32 = if (target == .slab and promotes_to_double_slab) 1.0 else block.collision_height();
    const overlaps = bh > 0 and
        self.pos_x + collision.HALF_W > bx0 and
        self.pos_x - collision.HALF_W < bx0 + 1.0 and
        self.pos_y + collision.HEIGHT > by0 and
        self.pos_y < by0 + bh and
        self.pos_z + collision.HALF_W > bz0 and
        self.pos_z - collision.HALF_W < bz0 + 1.0;
    if (overlaps) return;
    send_block_change(self.writer, hit.place_x, hit.place_y, hit.place_z, 1, block);
    if (self.held_renderer) |hr| hr.trigger_place();
    // Promoted slabs already have collision and may target a different cell.
    if (block.collision_height() > 0 and !promotes_to_double_slab) {
        self.pending_block = .{
            .x = hit.place_x,
            .y = hit.place_y,
            .z = hit.place_z,
            .block = block,
        };
    }
}

fn send_block_change(w: *std.Io.Writer, x: u16, y: u16, z: u16, mode: u8, block: Block) void {
    proto.send_set_block_to_server(w, x, y, z, mode, block) catch |err| {
        std.log.scoped(.player).err("send_set_block_to_server: {}", .{err});
        return;
    };
    w.flush() catch |err| {
        std.log.scoped(.player).err("writer.flush: {}", .{err});
    };
}
