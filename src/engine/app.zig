const std = @import("std");
const Core = @import("core/core.zig");
const Util = @import("util/util.zig");
const Platform = @import("platform/platform.zig");

pub var running = true;
var vsync = true;

pub fn init(width: u32, height: u32, title: [:0]const u8, comptime api: Platform.GraphicsAPI, sync: bool, state: *const Core.State) !void {
    vsync = sync;

    // Allocator is first
    Util.init();
    try Platform.init(width, height, title, sync, api);
    try Core.state_machine.init(state);
}

pub fn deinit() void {
    Core.state_machine.deinit();

    Platform.deinit();

    // Allocator is last
    Util.deinit();
}

pub fn main_loop() !void {
    // TODO: Configure this
    const frames_per_second = 144;
    const frame_time = std.time.us_per_s / frames_per_second + 1;

    const ticks_per_second = 20;
    const tick_time = std.time.us_per_s / ticks_per_second + 1;

    const updates_per_second = 144;
    const update_time = std.time.us_per_s / updates_per_second + 1;

    var fps: usize = 0;
    var second_timer = Util.get_micro_timestamp() + std.time.us_per_s;
    var next_frame_start = Util.get_micro_timestamp() + frame_time;
    var last_time = Util.get_micro_timestamp();
    var next_input_update = Util.get_micro_timestamp() + update_time;
    var next_tick = Util.get_micro_timestamp() + tick_time;

    while (running) {
        // Frame tracking logic
        const now = Util.get_micro_timestamp();
        if (now > second_timer) {
            @branchHint(.unpredictable);
            std.log.info("FPS: {}", .{fps});
            fps = 0;
            second_timer = now + std.time.us_per_s;
        }
        fps += 1;

        // Wait for synchronization
        if (now < next_frame_start and vsync) {
            @branchHint(.unlikely);
            var new_time = Util.get_micro_timestamp();

            while (new_time < next_frame_start) {
                new_time = Util.get_micro_timestamp();
                Platform.update();

                // Wait 1ms
                Util.thread_sleep(std.time.us_per_ms);
            }
        }

        const before_update = Util.get_micro_timestamp();
        const dt = @as(f32, @floatFromInt(before_update - last_time)) / @as(f32, std.time.us_per_s);
        last_time = before_update;

        if (before_update > next_input_update) {
            @branchHint(.unpredictable);
            Platform.update();
            next_input_update = before_update + update_time;
            try Core.state_machine.update(dt);
        }

        if (before_update > next_tick) {
            @branchHint(.unpredictable);
            try Core.state_machine.tick();
            next_tick = before_update + tick_time;
        }

        if (Platform.gfx.api.start_frame()) {
            @branchHint(.likely);
            try Core.state_machine.draw(dt);
            Platform.gfx.api.end_frame();
        } else {
            @branchHint(.unlikely);
            Util.thread_sleep(std.time.us_per_ms * 50);
        }

        next_frame_start += frame_time;
        const curr_time = Util.get_micro_timestamp();
        const drift_limit = frame_time * 2;

        if (curr_time > next_frame_start + drift_limit) {
            @branchHint(.unlikely);
            next_frame_start = curr_time;

            if (vsync) {
                std.log.debug("Fell 2 frames behind!\n", .{});
            }
        }
    }
}
