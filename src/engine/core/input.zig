const std = @import("std");

pub const Key = enum(u16) {
    W,
    A,
    S,
    D,
    Space,
    Escape,
};
pub const MouseButton = enum(u16) {
    Left,
    Right,
    Middle,
};
pub const Button = enum(u16) {
    A,
    B,
    X,
    Y,
    Left,
    Right,
    Up,
    Down,
    LButton,
    RButton,
    LTrigger,
    RTrigger,
    Start,
    Select,
};
pub const Axis = enum(u16) {
    LeftX,
    LeftY,
    RightX,
    RightY,
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

pub const Binding = struct {
    source: BindingSource,
    component: ?ActionComponent = null,
    multiplier: f32 = 1.0,
    deadzone: f32 = 0.0,
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
    callback: ?*anyopaque = null,
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
    actions.deinit();
}

pub fn register_action(name: []const u8, action_type: ActionType, context: ?*anyopaque, callback: ?*anyopaque) !void {
    if (actions.get(name)) |_| {
        return error.ActionAlreadyExists;
    }

    const action = Action{
        .type = action_type,
        .bindings = try std.ArrayList(Binding).init(allocator),
        .context = context,
        .callback = callback,
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

pub fn add_button_callback(name: []const u8, callback: ButtonCallback) !void {
    const action = actions.getPtr(name) orelse return error.ActionNotFound;
    if (action.type != .button) {
        return error.InvalidActionType;
    }
    action.callback = @ptrCast(callback);
}

pub fn add_axis_callback(name: []const u8, callback: AxisCallback) !void {
    const action = actions.getPtr(name) orelse return error.ActionNotFound;
    if (action.type != .axis) {
        return error.InvalidActionType;
    }
    action.callback = @ptrCast(callback);
}

pub fn add_vector2_callback(name: []const u8, callback: Vector2Callback) !void {
    const action = actions.getPtr(name) orelse return error.ActionNotFound;
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
                        const cb: ButtonCallback = @ptrCast(cb_ptr);
                        if (changed)
                            cb(ctx, new_value.button);
                    },
                    .axis => {
                        const cb: AxisCallback = @ptrCast(cb_ptr);

                        // TODO: Deadzone handling
                        if (changed or new_value.axis != 0.0)
                            cb(ctx, new_value.axis);
                    },
                    .vector2 => {
                        const cb: Vector2Callback = @ptrCast(cb_ptr);

                        // TODO: Deadzone handling
                        if (changed or new_value.vector2[0] != 0.0 or new_value.vector2[1] != 0.0)
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
        .key => |_| {
            raw = 0.0;
        },
        .mouse_button => |_| {},
        .gamepad_button => |_| {},
        .gamepad_axis => |_| {},
        .mouse_scroll => |_| {},
        .mouse_relative => |_| {},
    }

    return raw * multiplier;
}
