const std = @import("std");
const input = @import("../../core/input.zig");
const glfw = @import("glfw");
const Surface = @import("surface.zig");
const gfx = @import("../gfx.zig");
// TODO: Agnosticize this to support other backends

pub fn is_key_down(key: input.Key) bool {
    const state = glfw.getKey(@as(*Surface, @ptrCast(@alignCast(gfx.surface.ptr))).window, @intFromEnum(key));
    return state == glfw.Press;
}

pub fn is_mouse_button_down(button: input.MouseButton) bool {
    const state = glfw.getMouseButton(@as(*Surface, @ptrCast(@alignCast(gfx.surface.ptr))).window, @intFromEnum(button));
    return state == glfw.Press;
}

pub fn is_gamepad_button_down(button: input.Button) bool {
    var gamepad_state: glfw.GamepadState = undefined;
    _ = glfw.getGamepadState(@as(*Surface, @ptrCast(@alignCast(gfx.surface.ptr))).active_joystick, &gamepad_state);

    return gamepad_state.buttons[@intFromEnum(button)] == glfw.Press;
}

pub fn get_gamepad_axis(axis: input.Axis) f32 {
    var gamepad_state: glfw.GamepadState = undefined;
    _ = glfw.getGamepadState(@as(*Surface, @ptrCast(@alignCast(gfx.surface.ptr))).active_joystick, &gamepad_state);

    return gamepad_state.axes[@intFromEnum(axis)];
}
