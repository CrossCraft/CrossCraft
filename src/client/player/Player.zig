const std = @import("std");
const ae = @import("aether");
const input = ae.Core.input;

const Camera = @import("Camera.zig");
const bindings = @import("bindings.zig");

const Self = @This();

camera: *Camera,
move_dir: [2]f32, // x = strafe (right +), y = forward/back (forward +)
look_delta: [2]f32, // mouse delta (applied once then cleared)
look_rate: [2]f32, // stick/D-pad deflection (applied as velocity * dt)
flying_up: bool,
flying_down: bool,
mouse_captured: bool,
speed: f32,
stick_look_speed: f32, // radians/sec at full stick deflection

/// Initialise player state and wire up input callbacks.
/// `self` must have a stable address (module-level or arena-backed).
pub fn init(self: *Self, camera: *Camera) !void {
    std.debug.assert(camera.fov > 0);

    self.* = .{
        .camera = camera,
        .move_dir = .{ 0, 0 },
        .look_delta = .{ 0, 0 },
        .look_rate = .{ 0, 0 },
        .flying_up = false,
        .flying_down = false,
        .mouse_captured = true,
        .speed = 20.0,
        .stick_look_speed = 3.0,
    };

    try bindings.init();

    try input.add_vector2_callback("move", @ptrCast(self), on_move);
    try input.add_button_callback("fly_up", @ptrCast(self), on_fly_up);
    try input.add_button_callback("fly_down", @ptrCast(self), on_fly_down);
    try input.add_vector2_callback("look", @ptrCast(self), on_look);
    try input.add_vector2_callback("look_stick", @ptrCast(self), on_look_stick);
    try input.add_button_callback("escape", @ptrCast(self), on_escape);

    // DPI-normalized deltas need higher sensitivity to feel right
    input.mouse_sensitivity = 3.0;
    input.set_mouse_relative_mode(true);
}

/// Apply one frame of freecam movement.
pub fn update(self: *Self, dt: f32) void {
    std.debug.assert(dt >= 0);

    // Mouse look (delta) - only when captured
    if (self.mouse_captured) {
        self.camera.yaw -= self.look_delta[0];
        self.camera.pitch += self.look_delta[1];
    }
    self.look_delta = .{ 0, 0 };

    // Stick / D-pad look (rate)
    self.camera.yaw -= self.look_rate[0] * self.stick_look_speed * dt;
    self.camera.pitch += self.look_rate[1] * self.stick_look_speed * dt;

    const max_pitch = std.math.pi / 2.0 - 0.01;
    self.camera.pitch = @max(-max_pitch, @min(max_pitch, self.camera.pitch));

    // Forward / right vectors on the horizontal plane
    const sin_yaw = @sin(self.camera.yaw);
    const cos_yaw = @cos(self.camera.yaw);
    const strafe = self.move_dir[0];
    const forward = self.move_dir[1];

    const dx = (strafe * cos_yaw - forward * sin_yaw) * self.speed * dt;
    const dz = (-strafe * sin_yaw - forward * cos_yaw) * self.speed * dt;
    var dy: f32 = 0;
    if (self.flying_up) dy += self.speed * dt;
    if (self.flying_down) dy -= self.speed * dt;

    self.camera.x += dx;
    self.camera.y += dy;
    self.camera.z += dz;
}

// ---- input callbacks (invoked by Aether before state update) ----

fn on_move(ctx: *anyopaque, value: [2]f32) void {
    const self: *Self = @ptrCast(@alignCast(ctx));
    self.move_dir = value;
}

fn on_fly_up(ctx: *anyopaque, event: input.ButtonEvent) void {
    const self: *Self = @ptrCast(@alignCast(ctx));
    self.flying_up = event == .pressed;
}

fn on_fly_down(ctx: *anyopaque, event: input.ButtonEvent) void {
    const self: *Self = @ptrCast(@alignCast(ctx));
    self.flying_down = event == .pressed;
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
    // Clear pending delta to avoid a camera jump on re-capture
    self.look_delta = .{ 0, 0 };
}
