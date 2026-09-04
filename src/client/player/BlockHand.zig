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
const ae = @import("aether");
const Math = ae.Math;
const Rendering = ae.Rendering;

const Block = @import("core").blocks.Block;

const Vertex = @import("aether").Rendering.Vertex;
const TextureAtlas = @import("../graphics/TextureAtlas.zig").TextureAtlas;
const Camera = @import("Camera.zig");
const face_mod = @import("../world/chunk/face.zig");
const Face = face_mod.Face;

// emit_face stores a unit cube in [0, 2048] SNORM16 units.
const WORLD_UNIT_SCALE: f32 = 16.0;
const HELD_SCALE: f32 = 0.4;

// Camera-relative pose in view space.
const YAW: f32 = std.math.pi / 4.0;
const BASE_X: f32 = 0.56;
const BASE_Y: f32 = -0.52;
const BASE_Z: f32 = -0.72;
const HELD_Y_LIFT: f32 = 0.1;

const PLACE_PERIOD: f32 = 0.25;
const DIG_PERIOD: f32 = 0.35;
const SWING_AMPLITUDE_Y: f32 = -0.3;
const DIG_AMP_X: f32 = -0.4;
const DIG_AMP_Y: f32 = 0.2;
const DIG_AMP_Z: f32 = -0.2;
const DIG_YAW_RAD: f32 = 80.0 * std.math.pi / 180.0;
const DIG_PITCH_RAD: f32 = -20.0 * std.math.pi / 180.0;

const QUAD_CAPACITY: usize = 6;
const VERT_CAPACITY: usize = QUAD_CAPACITY * 6;
const SENTINEL: Block = @enumFromInt(0xFF);

const SwingKind = enum { idle, place, dig };

const BlockHand = @This();

const hand_near_plane: f32 = if (ae.platform == .psp) 0.3 else Camera.near_plane;
const hand_far_plane: f32 = if (ae.platform == .nintendo_3ds) Camera.far_plane else 128.0;

atlas: TextureAtlas,
mesh_data: Rendering.MeshDataType(Vertex),
mesh: Rendering.MeshType(Vertex),
cached_block: Block,
pending_block: Block,
cached_shadowed: bool,
swing_kind: SwingKind,
swing_time: f32,
swing_period: f32,
prev_swing_y: f32,
allocator: std.mem.Allocator,

pub fn init(allocator: std.mem.Allocator, atlas: TextureAtlas) !BlockHand {
    var self: BlockHand = .{
        .atlas = atlas,
        .mesh_data = try Rendering.MeshDataType(Vertex).init(allocator),
        .mesh = try Rendering.MeshType(Vertex).init(&.{}),
        .cached_block = SENTINEL,
        .pending_block = SENTINEL,
        .cached_shadowed = false,
        .swing_kind = .idle,
        .swing_time = 0,
        .swing_period = 0,
        .prev_swing_y = 0,
        .allocator = allocator,
    };
    try self.mesh_data.ensure_quad_capacity(allocator, QUAD_CAPACITY);
    return self;
}

pub fn deinit(self: *BlockHand) void {
    self.mesh.deinit();
    self.mesh_data.deinit(self.allocator);
    self.* = undefined;
}

pub fn trigger_dig(self: *BlockHand) void {
    self.swing_kind = .dig;
    self.swing_period = DIG_PERIOD;
    self.swing_time = 0;
    self.prev_swing_y = 0;
}

pub fn trigger_place(self: *BlockHand) void {
    self.swing_kind = .place;
    self.swing_period = PLACE_PERIOD;
    self.swing_time = 0;
    self.prev_swing_y = 0;
}

pub fn update(self: *BlockHand, dt: f32, current_block: Block, shadowed: bool) void {
    assert(dt >= 0);

    if (self.cached_block == SENTINEL) {
        self.rebuild(current_block, shadowed);
        self.cached_block = current_block;
        self.pending_block = current_block;
        self.cached_shadowed = shadowed;
        return;
    }

    // Defer tint changes during a dig; its completion rebuilds the mesh.
    if (shadowed != self.cached_shadowed and self.swing_kind != .dig) {
        self.rebuild(self.cached_block, shadowed);
        self.cached_shadowed = shadowed;
    }

    if (current_block != self.pending_block) {
        self.pending_block = current_block;
        if (self.swing_kind == .idle) {
            self.swing_kind = .place;
            self.swing_period = PLACE_PERIOD;
            self.swing_time = 0;
            self.prev_swing_y = 0;
        } else {
            self.swing_kind = .place;
            self.swing_period = PLACE_PERIOD;
            self.swing_time = PLACE_PERIOD * 0.5;
            self.prev_swing_y = SWING_AMPLITUDE_Y;
        }
    }

    if (self.swing_kind == .idle) return;
    self.swing_time += dt;

    if (self.swing_time >= self.swing_period) {
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

    // Swap blocks as the place swing starts rising from its trough.
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

fn rebuild(self: *BlockHand, block: Block, shadowed: bool) void {
    self.mesh_data.clear_retaining_capacity();
    if (block.is_air()) {
        self.mesh.update(&self.mesh_data);
        return;
    }
    const p = block.mesh_props();
    const shade = shadowed and !p.emits_light;

    if (p.cross) {
        const tile = block.face_tile(.y_pos);
        face_mod.emit_cross(&self.mesh_data, 0, 0, 0, tile, &self.atlas, shade);
    } else {
        const is_slab = p.slab;
        const faces = [_]Face{ .x_neg, .x_pos, .y_neg, .y_pos, .z_neg, .z_pos };
        for (faces) |face| {
            const tile = block.face_tile(face);
            if (is_slab) {
                face_mod.emit_slab_face(&self.mesh_data, face, 0, 0, 0, tile, &self.atlas, shade);
            } else {
                face_mod.emit_face(&self.mesh_data, face, 0, 0, 0, tile, &self.atlas, shade);
            }
        }
    }

    const uniform: u32 = if (shade) face_mod.apply_shadow(0xFFCCCCCC) else 0xFFCCCCCC;
    for (self.mesh_data.vertices.items) |*v| {
        v.color = uniform;
    }

    assert(self.mesh_data.vertices.items.len <= VERT_CAPACITY);
    self.mesh.update(&self.mesh_data);
}

pub fn draw(self: *BlockHand, terrain: *const Rendering.Texture, camera: *const Camera) void {
    if (self.cached_block.is_air() or self.mesh_data.vertices.items.len == 0) return;

    Rendering.gfx.api.clear_depth();

    const hand_fov: f32 = 70.0 * std.math.pi / 180.0;
    if (camera.fov != hand_fov) set_projection(hand_fov);

    Rendering.gfx.api.bind_texture(terrain.handle);

    const anim = self.compute_anim();
    const held_p = self.cached_block.mesh_props();
    const y_lift: f32 = if (held_p.slab or held_p.cross) HELD_Y_LIFT else 0;

    const scale = WORLD_UNIT_SCALE * HELD_SCALE;
    const half: f32 = HELD_SCALE * 0.5;

    const sca = Math.Mat4.scaling(scale, scale, scale);
    const center = Math.Mat4.translation(-half, -half, -half);
    const rot_x = Math.Mat4.rotationX(anim.pitch);
    const rot_y = Math.Mat4.rotationY(YAW + anim.yaw);
    const trans = Math.Mat4.translation(
        BASE_X + anim.dx - camera.bob_hor,
        BASE_Y + anim.dy + y_lift - camera.bob_ver,
        BASE_Z + anim.dz - camera.bob_hor,
    );

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

    if (camera.fov != hand_fov) set_projection(camera.fov);
}

fn set_projection(fov: f32) void {
    const screen_w = Rendering.gfx.surface.get_width();
    const screen_h = Rendering.gfx.surface.get_height();
    const aspect: f32 = @as(f32, @floatFromInt(screen_w)) / @as(f32, @floatFromInt(screen_h));
    const proj = Math.Mat4.perspectiveFovRh(fov, aspect, hand_near_plane, hand_far_plane);
    Rendering.gfx.api.set_proj_matrix(&proj);
}

const Anim = struct {
    dx: f32,
    dy: f32,
    dz: f32,
    yaw: f32,
    pitch: f32,
};

fn compute_anim(self: *const BlockHand) Anim {
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

    const s = @sqrt(t) * std.math.pi;
    return .{
        .dx = DIG_AMP_X * @sin(s),
        .dy = DIG_AMP_Y * @sin(2.0 * s),
        .dz = DIG_AMP_Z * @sin(t * std.math.pi),
        .yaw = DIG_YAW_RAD * @sin(s),
        .pitch = DIG_PITCH_RAD * @sin(t * t * std.math.pi),
    };
}
