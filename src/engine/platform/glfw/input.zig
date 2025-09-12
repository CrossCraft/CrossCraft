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

var relative_mode: bool = false;
pub fn get_mouse_delta(sensitivity: f32) [2]f32 {
    const w: f64 = @floatFromInt(gfx.surface.get_width());
    const h: f64 = @floatFromInt(gfx.surface.get_height());

    if (relative_mode) {
        glfw.setCursorPos(@as(*Surface, @ptrCast(@alignCast(gfx.surface.ptr))).window, w / 2.0, h / 2.0);

        return [_]f32{
            @as(f32, @floatCast(Surface.cursor_x - w / 2.0)) * sensitivity * 0.1,
            @as(f32, @floatCast(Surface.cursor_y - h / 2.0)) * sensitivity * 0.1,
        };
    } else {
        return [_]f32{ @floatCast(Surface.cursor_x / w), @floatCast((h - Surface.cursor_y) / h) };
    }
}

var last_scroll: f32 = 0.0;
pub fn get_mouse_scroll() f32 {
    const delta = Surface.curr_scroll - last_scroll;
    last_scroll = Surface.curr_scroll;
    return delta;
}

pub fn set_mouse_relative_mode(enabled: bool) void {
    relative_mode = enabled;
    if (enabled) {
        glfw.setInputMode(@as(*Surface, @ptrCast(@alignCast(gfx.surface.ptr))).window, glfw.Cursor, glfw.CursorHidden);
    } else {
        glfw.setInputMode(@as(*Surface, @ptrCast(@alignCast(gfx.surface.ptr))).window, glfw.Cursor, glfw.CursorNormal);
    }
}
