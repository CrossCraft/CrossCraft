const std = @import("std");
const assert = std.debug.assert;

const State = @import("State.zig");

var initialized: bool = false;
var curr_state: *const State = undefined;

pub fn init(state: *const State) anyerror!void {
    assert(!initialized);

    curr_state = state;
    try curr_state.init();

    initialized = true;
    assert(initialized);
}

pub fn deinit() void {
    assert(initialized);

    curr_state.deinit();

    initialized = false;
    assert(!initialized);
}

pub fn transition(state: *const State) anyerror!void {
    assert(initialized);

    curr_state.deinit();
    curr_state = state;
    try curr_state.init();
}

pub fn tick() anyerror!void {
    assert(initialized);
    try curr_state.tick();
}

pub fn update(dt: f32) anyerror!void {
    assert(initialized);
    try curr_state.update(dt);
}

pub fn draw(dt: f32) anyerror!void {
    assert(initialized);
    try curr_state.draw(dt);
}
