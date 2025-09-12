const std = @import("std");
const Core = @import("core/core.zig");
const Util = @import("util/util.zig");
const Platform = @import("platform/platform.zig");

pub var running = true;
var vsync = true;

pub fn init(width: u32, height: u32, title: [:0]const u8, comptime api: Platform.GraphicsAPI, fullscreen: bool, sync: bool, state: *const Core.State) !void {
    vsync = sync;

    // Allocator is first
    try Util.init();
    try Platform.init(width, height, title, fullscreen, sync, api);
    try Core.input.init(Util.allocator());
    try Core.state_machine.init(state);
}

pub fn deinit() void {
    Core.state_machine.deinit();
    Core.input.deinit();

    Platform.deinit();

    // Allocator is last
    Util.deinit();
}

pub fn quit() void {
    running = false;
}

pub fn main_loop() !void {
    const US_PER_S: u64 = std.time.us_per_s;

    // Fixed-step rates
    const UPDATES_HZ: u32 = 144;
    const TICKS_HZ: u32 = 20;
    const UPDATE_US: u64 = US_PER_S / UPDATES_HZ;
    const TICK_US: u64 = US_PER_S / TICKS_HZ;

    var last_us: u64 = Util.get_micro_timestamp();
    var update_accum: u64 = 0;
    var tick_accum: u64 = 0;

    var fps_count: usize = 0;
    var fps_window_end: u64 = last_us + US_PER_S;

    while (running) {
        const now_us = Util.get_micro_timestamp();
        var frame_dt_us = now_us - last_us;
        last_us = now_us;

        if (frame_dt_us > 500_000) frame_dt_us = 500_000;

        update_accum += frame_dt_us;
        tick_accum += frame_dt_us;

        // ---- fixed-rate UPDATE steps (input update & interpolation) ----
        const UPDATE_DT_S: f32 = @as(f32, @floatFromInt(UPDATE_US)) / @as(f32, US_PER_S);
        while (update_accum >= UPDATE_US) {
            @branchHint(.unpredictable);
            Platform.update();
            Core.input.update();
            try Core.state_machine.update(UPDATE_DT_S);
            update_accum -= UPDATE_US;
        }

        // ---- fixed-rate TICK steps (e.g., 20 Hz logic) ----
        while (tick_accum >= TICK_US) {
            @branchHint(.unpredictable);
            try Core.state_machine.tick();
            tick_accum -= TICK_US;
        }

        // ---- render ASAP (uncapped when vsync == false) ----
        const frame_dt_s: f32 = @as(f32, @floatFromInt(frame_dt_us)) / @as(f32, US_PER_S);
        if (Platform.gfx.api.start_frame()) {
            try Core.state_machine.draw(frame_dt_s);
            Platform.gfx.api.end_frame();
        } else {
            @branchHint(.unlikely);
            Util.thread_sleep(std.time.us_per_ms * 50);
        }

        // ---- FPS counting ----
        fps_count += 1;
        if (now_us >= fps_window_end) {
            Util.engine_logger.info("FPS: {}", .{fps_count});
            fps_count = 0;
            fps_window_end += US_PER_S;
        }
    }
}
