const std = @import("std");
const core = @import("core");
const Server = core.Server;

pub fn main() !void {
    var server = try Server.init(std.heap.page_allocator);
    defer server.deinit(std.heap.page_allocator);

    const ticks_per_second: i64 = 20;
    const tick_us: i64 = @intCast(std.time.us_per_s / ticks_per_second);

    var prev_time: i64 = std.time.microTimestamp();
    var acc_us: i64 = 0;

    var tps: usize = 0;
    var next_report_time: i64 = prev_time + std.time.us_per_s;

    const max_acc_us: i64 = std.time.us_per_s;

    while (true) {
        const now = std.time.microTimestamp();
        var dt = now - prev_time;
        if (dt < 0) dt = 0;
        prev_time = now;

        acc_us += dt;
        if (acc_us > max_acc_us) acc_us = max_acc_us;

        while (acc_us >= tick_us) {
            server.tick();
            acc_us -= tick_us;
            tps += 1;
        }

        if (now >= next_report_time) {
            std.debug.print("TPS: {d}\n", .{tps});
            tps = 0;
            next_report_time += std.time.us_per_s;
            if (now > next_report_time + (10 * std.time.us_per_ms))
                next_report_time = now + std.time.us_per_s;
        }
    }
}
