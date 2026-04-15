// Hardcoded Steve player model for rendering remote players.
//
// Geometry is derived from the Minecraft Classic skin layout (64x32 char.png).
// Six static meshes are built at init and never rebuilt:
//   torso     - torso only (36 vertices)
//   head      - head, rotated independently for pitch (36 vertices)
//   right_arm / left_arm  - idle sway + walk swing (36 vertices each)
//   right_leg / left_leg  - walk swing (36 vertices each)
//
// Left-side limbs mirror the right-side UVs (u0/u1 swapped per face).
// Positions are interpolated with exponential smoothing so movement looks
// fluid between the server's 20 Hz position ticks.

const std = @import("std");
const ae = @import("aether");
const Math = ae.Math;
const Rendering = ae.Rendering;

const c = @import("common").consts;
const collision = @import("../player/collision.zig");
const Vertex = @import("../graphics/Vertex.zig").Vertex;
const Color = @import("../graphics/Color.zig").Color;
const Player = @import("../player/Player.zig");
const PlayerList = @import("../ui/PlayerList.zig");
const FontBatcher = @import("../ui/FontBatcher.zig");
const ResourcePack = @import("../ResourcePack.zig");

const Self = @This();

// SNORM16 scale: 1 block = 2048 units (matches face.zig:encode_pos).
// Model matrix scales by 16.0 to recover world units.
const WORLD_UNIT_SCALE: f32 = 16.0;

// Render distance for remote players (blocks).
const RENDER_DIST: f32 = 32.0;
const RENDER_DIST_SQ: f32 = RENDER_DIST * RENDER_DIST;

// Interpolation speed (units: 1/s). At 20 Hz server ticks (50ms apart),
// a speed of 15 converges ~53% per tick - fast enough to track but smooth
// enough to hide jitter.
const INTERP_SPEED: f32 = 15.0;

// Idle arm sway (Z-axis, outward only).
const IDLE_AMPLITUDE: f32 = 0.05; // ~3 degrees
const IDLE_SPEED: f32 = 1.5 / 8.0; // cycles per second

// Walk animation (X-axis, forward/back swing).
const WALK_AMPLITUDE: f32 = 0.7; // ~40 degrees at full walk speed
const WALK_SPEED: f32 = 2.0; // cycles per second
// Classic walk speed (~4.3 blocks/s). At this speed walk_blend = 1.0.
const WALK_FULL_SPEED: f32 = 4.3;
// How fast walk_blend tracks the measured velocity (1/s, exponential smoothing).
const WALK_BLEND_SPEED: f32 = 10.0;

const LIMB_VERTS: usize = 36;

// Name tag billboard above the head.
const TAG_HEIGHT: f32 = 0.3; // world-space height of text (blocks)
const TAG_Y_OFFSET: f32 = 2.2; // above feet (head top is 2.0)
const BatchMesh = Rendering.Mesh(Vertex);

const PlayerState = struct {
    active: bool,
    x: f32,
    y: f32,
    z: f32,
    yaw: f32,
    pitch: f32,
    walk_blend: f32,
};

torso: Rendering.Mesh(Vertex),
head: Rendering.Mesh(Vertex),
right_arm: Rendering.Mesh(Vertex),
left_arm: Rendering.Mesh(Vertex),
right_leg: Rendering.Mesh(Vertex),
left_leg: Rendering.Mesh(Vertex),
states: [c.MAX_PLAYERS]PlayerState,
name_tags: [c.MAX_PLAYERS]?BatchMesh,
name_aspects: [c.MAX_PLAYERS]f32,
anim_time: f32,
allocator: std.mem.Allocator,
pipeline: Rendering.Pipeline.Handle,

pub fn init(allocator: std.mem.Allocator, pipeline: Rendering.Pipeline.Handle) !Self {
    var self: Self = .{
        .torso = try Rendering.Mesh(Vertex).new(allocator, pipeline),
        .head = try Rendering.Mesh(Vertex).new(allocator, pipeline),
        .right_arm = try Rendering.Mesh(Vertex).new(allocator, pipeline),
        .left_arm = try Rendering.Mesh(Vertex).new(allocator, pipeline),
        .right_leg = try Rendering.Mesh(Vertex).new(allocator, pipeline),
        .left_leg = try Rendering.Mesh(Vertex).new(allocator, pipeline),
        .states = std.mem.zeroes([c.MAX_PLAYERS]PlayerState),
        .name_tags = .{null} ** c.MAX_PLAYERS,
        .name_aspects = .{1.0} ** c.MAX_PLAYERS,
        .anim_time = 0,
        .allocator = allocator,
        .pipeline = pipeline,
    };
    const meshes = [_]*Rendering.Mesh(Vertex){
        &self.torso,     &self.head,
        &self.right_arm, &self.left_arm,
        &self.right_leg, &self.left_leg,
    };
    for (meshes) |m| {
        m.primitive = .triangles;
        try m.vertices.ensureTotalCapacity(allocator, LIMB_VERTS);
    }
    build_torso(&self.torso.vertices);
    build_head(&self.head.vertices);
    build_right_arm(&self.right_arm.vertices);
    build_left_arm(&self.left_arm.vertices);
    build_right_leg(&self.right_leg.vertices);
    build_left_leg(&self.left_leg.vertices);
    for (meshes) |m| {
        std.debug.assert(m.vertices.items.len == LIMB_VERTS);
        m.update();
    }
    return self;
}

pub fn deinit(self: *Self) void {
    for (&self.name_tags) |*nt| {
        if (nt.*) |*m| {
            m.deinit(self.allocator);
            nt.* = null;
        }
    }
    const meshes = [_]*Rendering.Mesh(Vertex){
        &self.torso,     &self.head,
        &self.right_arm, &self.left_arm,
        &self.right_leg, &self.left_leg,
    };
    for (meshes) |m| m.deinit(self.allocator);
}

// -- Per-frame update (call from GameState.update) ---------------------------

pub fn update(self: *Self, dt: f32, player_list: *const PlayerList, fonts: *const FontBatcher) void {
    const tau = std.math.tau;
    const pi = std.math.pi;
    const f = 1.0 - @exp(-INTERP_SPEED * dt);
    const wf = 1.0 - @exp(-WALK_BLEND_SPEED * dt);

    self.anim_time += dt;
    if (self.anim_time > 1000.0) self.anim_time -= 1000.0;

    for (&player_list.entries, &self.states, &self.name_tags, &self.name_aspects) |*e, *st, *nt, *aspect| {
        if (!e.active) {
            st.active = false;
            if (nt.*) |*m| {
                m.deinit(self.allocator);
                nt.* = null;
            }
            continue;
        }

        // Build name tag mesh on first sighting.
        if (nt.* == null and e.name_len > 0) {
            const name = e.name[0..e.name_len];
            const tw = fonts.string_width(name, 0, 1);
            if (tw > 0) {
                aspect.* = @as(f32, @floatFromInt(tw)) / 8.0;
                nt.* = fonts.build_mesh(name, .white_fg, .none, 0, 1) catch null;
            }
        }

        const tx: f32 = @as(f32, @floatFromInt(e.x)) / 32.0;
        const ty: f32 = @as(f32, @floatFromInt(e.y)) / 32.0;
        const tz: f32 = @as(f32, @floatFromInt(e.z)) / 32.0;
        const tyaw = -@as(f32, @floatFromInt(e.yaw)) * tau / 256.0 + pi;
        const tpitch = @as(f32, @floatFromInt(e.pitch)) * tau / 256.0;

        if (!st.active) {
            st.* = .{
                .active = true,
                .x = tx,
                .y = ty,
                .z = tz,
                .yaw = tyaw,
                .pitch = tpitch,
                .walk_blend = 0,
            };
            continue;
        }

        // Smooth position toward target; measure how far we moved this frame
        // to derive horizontal speed for walk animation amplitude.
        const prev_x = st.x;
        const prev_z = st.z;
        st.x += (tx - st.x) * f;
        st.y += (ty - st.y) * f;
        st.z += (tz - st.z) * f;

        const move_dx = st.x - prev_x;
        const move_dz = st.z - prev_z;
        const speed = @sqrt(move_dx * move_dx + move_dz * move_dz) / @max(dt, 0.001);
        const target_blend = @min(speed / WALK_FULL_SPEED, 1.5);
        st.walk_blend += (target_blend - st.walk_blend) * wf;
        st.yaw = lerp_angle(st.yaw, tyaw, f);
        st.pitch = lerp_angle(st.pitch, tpitch, f);
    }
}

fn lerp_angle(current: f32, target: f32, f_factor: f32) f32 {
    const tau = std.math.tau;
    const pi = std.math.pi;
    var diff = target - current;
    if (diff > pi) diff -= tau;
    if (diff < -pi) diff += tau;
    return current + diff * f_factor;
}

// -- Draw (call from GameState.draw) -----------------------------------------

pub fn draw(self: *Self, local: *const Player) void {
    const local_x = local.pos_x;
    const local_y = local.pos_y;
    const local_z = local.pos_z;

    Rendering.Pipeline.bind(self.pipeline);
    ResourcePack.get_tex(.char).bind();

    // Idle sway (Z-axis, outward only, always active).
    const idle_swing = (@sin(self.anim_time * std.math.tau * IDLE_SPEED) * 0.5 + 0.5) * IDLE_AMPLITUDE;

    // Walk cycle (X-axis, sinusoidal, blended per-player).
    const walk_phase = @sin(self.anim_time * std.math.tau * WALK_SPEED * 0.67) * 1.5;

    for (&self.states) |*st| {
        if (!st.active) continue;

        const feet_y = st.y - collision.EYE_HEIGHT;

        const dx = st.x - local_x;
        const dy = feet_y - local_y;
        const dz = st.z - local_z;
        if (dx * dx + dy * dy + dz * dz > RENDER_DIST_SQ) continue;

        const scale = Math.Mat4.scaling(WORLD_UNIT_SCALE, WORLD_UNIT_SCALE, WORLD_UNIT_SCALE);
        const rot_y = Math.Mat4.rotationY(st.yaw);
        const world_t = Math.Mat4.translation(st.x, feet_y, st.z);

        // Torso: scale -> yaw -> world position
        const torso_model = scale.mul(rot_y).mul(world_t);
        self.torso.draw(&torso_model);

        // Head: scale -> pitch -> neck offset -> yaw -> world position
        const rot_x = Math.Mat4.rotationX(st.pitch);
        const neck_t = Math.Mat4.translation(0, 1.5, 0);
        const head_model = scale.mul(rot_x).mul(neck_t).mul(rot_y).mul(world_t);
        self.head.draw(&head_model);

        // Walk swing for this player, scaled by blend factor.
        const walk_swing = walk_phase * WALK_AMPLITUDE * st.walk_blend;

        // Right arm: walk swing (X) + idle sway (Z, outward = -Z)
        // Right arm forward when left leg forward: +walk_swing on arm, -walk_swing on leg.
        const r_arm_walk = Math.Mat4.rotationX(walk_swing);
        const r_arm_idle = Math.Mat4.rotationZ(-idle_swing);
        const r_shoulder = Math.Mat4.translation(-0.375, 1.5, 0);
        const r_arm_model = scale.mul(r_arm_walk).mul(r_arm_idle).mul(r_shoulder).mul(rot_y).mul(world_t);
        self.right_arm.draw(&r_arm_model);

        // Left arm: opposite walk phase + idle sway (outward = +Z)
        const l_arm_walk = Math.Mat4.rotationX(-walk_swing);
        const l_arm_idle = Math.Mat4.rotationZ(idle_swing);
        const l_shoulder = Math.Mat4.translation(0.375, 1.5, 0);
        const l_arm_model = scale.mul(l_arm_walk).mul(l_arm_idle).mul(l_shoulder).mul(rot_y).mul(world_t);
        self.left_arm.draw(&l_arm_model);

        // Right leg: opposite to right arm
        const r_leg_swing = Math.Mat4.rotationX(-walk_swing);
        const r_hip = Math.Mat4.translation(-0.125, 0.75, 0);
        const r_leg_model = scale.mul(r_leg_swing).mul(r_hip).mul(rot_y).mul(world_t);
        self.right_leg.draw(&r_leg_model);

        // Left leg: opposite to left arm (same phase as right arm)
        const l_leg_swing = Math.Mat4.rotationX(walk_swing);
        const l_hip = Math.Mat4.translation(0.125, 0.75, 0);
        const l_leg_model = scale.mul(l_leg_swing).mul(l_hip).mul(rot_y).mul(world_t);
        self.left_leg.draw(&l_leg_model);
    }
}

// -- Name tags (call from GameState.draw after draw()) -----------------------

pub fn draw_nametags(self: *Self, local: *const Player, fonts: *const FontBatcher) void {
    Rendering.Pipeline.bind(self.pipeline);
    fonts.texture.bind();

    for (&self.states, &self.name_tags, &self.name_aspects) |*st, *nt, aspect| {
        if (!st.active) continue;
        const mesh = &(nt.* orelse continue);

        const feet_y = st.y - collision.EYE_HEIGHT;
        const dx = st.x - local.pos_x;
        const dy = feet_y - local.pos_y;
        const dz = st.z - local.pos_z;
        if (dx * dx + dy * dy + dz * dz > RENDER_DIST_SQ) continue;

        // Cylindrical billboard: faces camera horizontally, stays upright.
        const half_h = TAG_HEIGHT / 2.0;
        const half_w = half_h * aspect;
        const sca = Math.Mat4.scaling(half_w, half_h, 0.001);
        const rot = Math.Mat4.rotationY(local.camera.yaw);
        const trans = Math.Mat4.translation(st.x, feet_y + TAG_Y_OFFSET, st.z);
        const model = sca.mul(rot).mul(trans);
        mesh.draw(&model);
    }
}

// -- Geometry builders -------------------------------------------------------

const UVRect = struct { tu0: i16, tv0: i16, tu1: i16, tv1: i16 };

fn char_uv(ox: u32, oy: u32, ew: u32, eh: u32) UVRect {
    return .{
        .tu0 = @intCast(@as(i32, @intCast(ox + ew)) * 32767 / 64),
        .tv0 = @intCast(@as(i32, @intCast(oy)) * 32767 / 32),
        .tu1 = @intCast(@as(i32, @intCast(ox)) * 32767 / 64),
        .tv1 = @intCast(@as(i32, @intCast(oy + eh)) * 32767 / 32),
    };
}

fn enc(blocks_x256: i32) i16 {
    return @intCast(@divTrunc(blocks_x256 * 2048, 256));
}

const Face = enum(u3) { x_neg, x_pos, y_neg, y_pos, z_neg, z_pos };

fn face_color(face: Face) u32 {
    return switch (face) {
        .y_pos => 0xFFFFFFFF,
        .y_neg => 0xFF7F7F7F,
        .x_neg, .x_pos => 0xFF999999,
        .z_neg, .z_pos => 0xFFCCCCCC,
    };
}

const FaceUVs = [6]UVRect;

const head_uvs: FaceUVs = .{
    char_uv(8, 0, 8, 8), // top
    char_uv(16, 0, 8, 8), // bottom
    char_uv(8, 8, 8, 8), // front (z_pos)
    char_uv(24, 8, 8, 8), // back (z_neg)
    char_uv(0, 8, 8, 8), // right (x_neg)
    char_uv(16, 8, 8, 8), // left (x_pos)
};

const torso_uvs: FaceUVs = .{
    char_uv(20, 16, 8, 4), // top
    char_uv(28, 16, 8, 4), // bottom
    char_uv(20, 20, 8, 12), // front
    char_uv(32, 20, 8, 12), // back
    char_uv(16, 20, 4, 12), // right
    char_uv(28, 20, 4, 12), // left
};

const arm_uvs: FaceUVs = .{
    char_uv(44, 16, 4, 4), // top
    char_uv(48, 16, 4, 4), // bottom
    char_uv(44, 20, 4, 12), // front
    char_uv(52, 20, 4, 12), // back
    char_uv(40, 20, 4, 12), // right
    char_uv(48, 20, 4, 12), // left
};

const leg_uvs: FaceUVs = .{
    char_uv(4, 16, 4, 4), // top
    char_uv(8, 16, 4, 4), // bottom
    char_uv(4, 20, 4, 12), // front
    char_uv(12, 20, 4, 12), // back
    char_uv(0, 20, 4, 12), // right
    char_uv(8, 20, 4, 12), // left
};

fn mirror_uvs(uvs: FaceUVs) FaceUVs {
    var m: FaceUVs = undefined;
    for (0..6) |i| {
        m[i] = .{
            .tu0 = uvs[i].tu1,
            .tv0 = uvs[i].tv0,
            .tu1 = uvs[i].tu0,
            .tv1 = uvs[i].tv1,
        };
    }
    return m;
}

fn emit_quad(verts: *std.ArrayList(Vertex), q: [4]Vertex) void {
    verts.appendAssumeCapacity(q[0]);
    verts.appendAssumeCapacity(q[2]);
    verts.appendAssumeCapacity(q[1]);
    verts.appendAssumeCapacity(q[0]);
    verts.appendAssumeCapacity(q[3]);
    verts.appendAssumeCapacity(q[2]);
}

fn make_quad(face: Face, px: i16, px1: i16, py: i16, py1: i16, pz: i16, pz1: i16, uv: UVRect, color: u32) [4]Vertex {
    return switch (face) {
        .x_pos => .{
            .{ .pos = .{ px1, py, pz }, .uv = .{ uv.tu0, uv.tv1 }, .color = color },
            .{ .pos = .{ px1, py, pz1 }, .uv = .{ uv.tu1, uv.tv1 }, .color = color },
            .{ .pos = .{ px1, py1, pz1 }, .uv = .{ uv.tu1, uv.tv0 }, .color = color },
            .{ .pos = .{ px1, py1, pz }, .uv = .{ uv.tu0, uv.tv0 }, .color = color },
        },
        .x_neg => .{
            .{ .pos = .{ px, py, pz1 }, .uv = .{ uv.tu0, uv.tv1 }, .color = color },
            .{ .pos = .{ px, py, pz }, .uv = .{ uv.tu1, uv.tv1 }, .color = color },
            .{ .pos = .{ px, py1, pz }, .uv = .{ uv.tu1, uv.tv0 }, .color = color },
            .{ .pos = .{ px, py1, pz1 }, .uv = .{ uv.tu0, uv.tv0 }, .color = color },
        },
        .y_pos => .{
            .{ .pos = .{ px, py1, pz }, .uv = .{ uv.tu0, uv.tv0 }, .color = color },
            .{ .pos = .{ px1, py1, pz }, .uv = .{ uv.tu1, uv.tv0 }, .color = color },
            .{ .pos = .{ px1, py1, pz1 }, .uv = .{ uv.tu1, uv.tv1 }, .color = color },
            .{ .pos = .{ px, py1, pz1 }, .uv = .{ uv.tu0, uv.tv1 }, .color = color },
        },
        .y_neg => .{
            .{ .pos = .{ px, py, pz1 }, .uv = .{ uv.tu0, uv.tv0 }, .color = color },
            .{ .pos = .{ px1, py, pz1 }, .uv = .{ uv.tu1, uv.tv0 }, .color = color },
            .{ .pos = .{ px1, py, pz }, .uv = .{ uv.tu1, uv.tv1 }, .color = color },
            .{ .pos = .{ px, py, pz }, .uv = .{ uv.tu0, uv.tv1 }, .color = color },
        },
        .z_pos => .{
            .{ .pos = .{ px1, py, pz1 }, .uv = .{ uv.tu0, uv.tv1 }, .color = color },
            .{ .pos = .{ px, py, pz1 }, .uv = .{ uv.tu1, uv.tv1 }, .color = color },
            .{ .pos = .{ px, py1, pz1 }, .uv = .{ uv.tu1, uv.tv0 }, .color = color },
            .{ .pos = .{ px1, py1, pz1 }, .uv = .{ uv.tu0, uv.tv0 }, .color = color },
        },
        .z_neg => .{
            .{ .pos = .{ px, py, pz }, .uv = .{ uv.tu0, uv.tv1 }, .color = color },
            .{ .pos = .{ px1, py, pz }, .uv = .{ uv.tu1, uv.tv1 }, .color = color },
            .{ .pos = .{ px1, py1, pz }, .uv = .{ uv.tu1, uv.tv0 }, .color = color },
            .{ .pos = .{ px, py1, pz }, .uv = .{ uv.tu0, uv.tv0 }, .color = color },
        },
    };
}

fn emit_box(
    verts: *std.ArrayList(Vertex),
    x0: i32,
    y0: i32,
    z0: i32,
    x1: i32,
    y1: i32,
    z1: i32,
    uvs: *const FaceUVs,
) void {
    const px = enc(x0);
    const px1 = enc(x1);
    const py = enc(y0);
    const py1 = enc(y1);
    const pz = enc(z0);
    const pz1 = enc(z1);

    const faces = [_]Face{ .y_pos, .y_neg, .z_pos, .z_neg, .x_neg, .x_pos };
    for (faces, 0..) |face, i| {
        emit_quad(verts, make_quad(face, px, px1, py, py1, pz, pz1, uvs[i], face_color(face)));
    }
}

// -- Body part builders ------------------------------------------------------
// All limbs are built relative to their rotation pivot so that rotations
// in the model matrix produce natural joint movement.

fn build_torso(verts: *std.ArrayList(Vertex)) void {
    // 0.5 wide, 0.75 tall, 0.25 deep. Positioned at model origin (feet).
    emit_box(verts, -64, 192, -32, 64, 384, 32, &torso_uvs);
}

fn build_head(verts: *std.ArrayList(Vertex)) void {
    // Pivot at bottom-center (neck). Y [0, 0.5] relative to pivot.
    emit_box(verts, -64, 0, -64, 64, 128, 64, &head_uvs);
}

fn build_right_arm(verts: *std.ArrayList(Vertex)) void {
    // Pivot at shoulder (top-center). Y [-0.75, 0] relative to pivot.
    emit_box(verts, -32, -192, -32, 32, 0, 32, &arm_uvs);
}

fn build_left_arm(verts: *std.ArrayList(Vertex)) void {
    const left_arm_uvs = comptime mirror_uvs(arm_uvs);
    emit_box(verts, -32, -192, -32, 32, 0, 32, &left_arm_uvs);
}

fn build_right_leg(verts: *std.ArrayList(Vertex)) void {
    // Pivot at hip (top-center). Y [-0.75, 0] relative to pivot.
    emit_box(verts, -32, -192, -32, 32, 0, 32, &leg_uvs);
}

fn build_left_leg(verts: *std.ArrayList(Vertex)) void {
    const left_leg_uvs = comptime mirror_uvs(leg_uvs);
    emit_box(verts, -32, -192, -32, 32, 0, 32, &left_leg_uvs);
}
