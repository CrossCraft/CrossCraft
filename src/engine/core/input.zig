const std = @import("std");
const Platform = @import("../platform/platform.zig");

pub const Key = enum(u16) {
    W = 'W',
    A = 'A',
    S = 'S',
    D = 'D',
    Space = ' ',
    Escape = 256,
};
pub const MouseButton = enum(u16) {
    Left = 0,
    Right = 1,
    Middle = 2,
};
pub const Button = enum(u16) {
    A = 0,
    B = 1,
    X = 2,
    Y = 3,
    LButton = 4,
    RButton = 5,
    Back = 6,
    Start = 7,
    Guide = 8,
    LeftThumb = 9,
    DpadUp = 10,
    DpadRight = 11,
    DpadDown = 12,
    DpadLeft = 13,
};

pub const Axis = enum(u16) {
    LeftX = 0,
    LeftY = 1,
    RightX = 2,
    RightY = 3,
};

pub const MouseScroll = enum(u16) {
    Up,
    Down,
};

pub const MouseRelativeAxis = enum(u16) {
    X,
    Y,
};

pub const ActionType = enum {
    button,
    axis,
    vector2,
};

pub const BindingSource = union(enum) {
    key: Key,
    mouse_button: MouseButton,
    gamepad_button: Button,
    gamepad_axis: Axis,
    mouse_scroll: MouseScroll,
    mouse_relative: MouseRelativeAxis,
};

pub const ActionComponent = enum(u8) {
    x,
    y,
};

pub const Deadzone = 0.4;
pub const Binding = struct {
    source: BindingSource,
    component: ?ActionComponent = null,
    multiplier: f32 = 1.0,
    deadzone: f32 = Deadzone,
};

pub const ButtonEvent = enum {
    pressed,
    released,
};

pub const ActionValue = union(ActionType) {
    button: ButtonEvent,
    axis: f32,
    vector2: [2]f32,
};

pub const ButtonCallback = *const fn (ctx: *anyopaque, event: ButtonEvent) void;
pub const AxisCallback = *const fn (ctx: *anyopaque, value: f32) void;
pub const Vector2Callback = *const fn (ctx: *anyopaque, value: [2]f32) void;

pub const Action = struct {
    type: ActionType,
    bindings: std.ArrayList(Binding),
    context: ?*anyopaque = null,
    callback: ?*const anyopaque = null,
    current_value: ActionValue = undefined,
    previous_value: ActionValue = undefined,
};

var allocator: std.mem.Allocator = undefined;
var actions: std.StringArrayHashMap(Action) = undefined;

pub fn init(alloc: std.mem.Allocator) !void {
    allocator = alloc;
    actions = std.StringArrayHashMap(Action).init(allocator);
}

pub fn deinit() void {
    for (actions.values()) |*action| {
        action.bindings.deinit(allocator);
    }
    actions.deinit();
}

pub fn register_action(name: []const u8, action_type: ActionType) !void {
    if (actions.get(name)) |_| {
        return error.ActionAlreadyExists;
    }

    const action = Action{
        .type = action_type,
        .bindings = try std.ArrayList(Binding).initCapacity(allocator, 4),
        .current_value = switch (action_type) {
            .button => ActionValue{ .button = .released },
            .axis => ActionValue{ .axis = 0.0 },
            .vector2 => ActionValue{ .vector2 = .{ 0.0, 0.0 } },
        },
        .previous_value = switch (action_type) {
            .button => ActionValue{ .button = .released },
            .axis => ActionValue{ .axis = 0.0 },
            .vector2 => ActionValue{ .vector2 = .{ 0.0, 0.0 } },
        },
    };

    try actions.put(name, action);
}

pub fn bind_action(name: []const u8, binding: Binding) !void {
    const action = actions.getPtr(name) orelse return error.ActionNotFound;
    try action.bindings.append(allocator, binding);
}

pub fn add_button_callback(name: []const u8, context: *anyopaque, callback: ButtonCallback) !void {
    const action = actions.getPtr(name) orelse return error.ActionNotFound;
    action.context = context;
    if (action.type != .button) {
        return error.InvalidActionType;
    }
    action.callback = @ptrCast(callback);
}

pub fn add_axis_callback(name: []const u8, context: *anyopaque, callback: AxisCallback) !void {
    const action = actions.getPtr(name) orelse return error.ActionNotFound;
    action.context = context;
    if (action.type != .axis) {
        return error.InvalidActionType;
    }
    action.callback = @ptrCast(callback);
}

pub fn add_vector2_callback(name: []const u8, context: *anyopaque, callback: Vector2Callback) !void {
    const action = actions.getPtr(name) orelse return error.ActionNotFound;
    action.context = context;
    if (action.type != .vector2) {
        return error.InvalidActionType;
    }
    action.callback = @ptrCast(callback);
}

pub fn update() void {
    var iter = actions.iterator();
    while (iter.next()) |entry| {
        var action = entry.value_ptr;
        const new_value = get_action_value(action);

        const changed = !std.meta.eql(new_value, action.current_value);
        action.previous_value = action.current_value;
        action.current_value = new_value;

        if (action.callback) |cb_ptr| {
            if (action.context) |ctx| {
                switch (action.type) {
                    .button => {
                        const cb: ButtonCallback = @ptrCast(@alignCast(cb_ptr));
                        if (changed)
                            cb(ctx, new_value.button);
                    },
                    .axis => {
                        const cb: AxisCallback = @ptrCast(@alignCast(cb_ptr));

                        if (changed or new_value.axis > Deadzone or new_value.axis < -Deadzone)
                            cb(ctx, new_value.axis);
                    },
                    .vector2 => {
                        const cb: Vector2Callback = @ptrCast(@alignCast(cb_ptr));

                        if (changed or new_value.vector2[0] > Deadzone or new_value.vector2[0] < -Deadzone or new_value.vector2[1] > Deadzone or new_value.vector2[1] < -Deadzone)
                            cb(ctx, new_value.vector2);
                    },
                }
            }
        }
    }
}

fn get_action_value(action: *const Action) ActionValue {
    switch (action.type) {
        .button => {
            var is_pressed = false;
            for (action.bindings.items) |b| {
                const contrib = get_binding_value(&b);
                if (contrib > 0.0) {
                    is_pressed = true;
                    break;
                }
            }

            return .{
                .button = if (is_pressed) .pressed else .released,
            };
        },
        .axis => {
            var value: f32 = 0.0;
            for (action.bindings.items) |b| {
                value += get_binding_value(&b);
            }

            return .{
                .axis = value,
            };
        },
        .vector2 => {
            var x: f32 = 0.0;
            var y: f32 = 0.0;

            for (action.bindings.items) |b| {
                const contrib = get_binding_value(&b);

                if (b.component == null) {
                    continue;
                }

                switch (b.component.?) {
                    .x => x += contrib,
                    .y => y += contrib,
                }
            }

            return .{
                .vector2 = [_]f32{ x, y },
            };
        },
    }
}

fn get_binding_value(binding: *const Binding) f32 {
    const multiplier = binding.multiplier;
    var raw: f32 = 0.0;

    switch (binding.source) {
        .key => |k| {
            raw = if (Platform.input.is_key_down(k)) 1.0 else 0.0;
        },
        .mouse_button => |mb| {
            raw = if (Platform.input.is_mouse_button_down(mb)) 1.0 else 0.0;
        },
        .gamepad_button => |gb| {
            raw = if (Platform.input.is_gamepad_button_down(gb)) 1.0 else 0.0;
        },
        .gamepad_axis => |ga| {
            raw = Platform.input.get_gamepad_axis(ga);
            if (raw > binding.deadzone) {
                raw = (raw - binding.deadzone) / (1.0 - binding.deadzone);
            } else if (raw < -binding.deadzone) {
                raw = (raw + binding.deadzone) / (1.0 - binding.deadzone);
            } else {
                raw = 0.0;
            }
        },
        .mouse_scroll => |_| {},
        .mouse_relative => |_| {},
    }

    return raw * multiplier;
}
