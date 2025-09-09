const std = @import("std");
const core = @import("core");
const Server = core.Server;

pub fn main() !void {
    var server = try Server.init(std.heap.page_allocator);
    defer server.deinit(std.heap.page_allocator);

    const ticks_per_second = 20;
    const tick_duration = std.time.us_per_s / ticks_per_second;

    var next_tick_time = std.time.microTimestamp() + tick_duration;
    var tps: usize = 0;
    var last_report_time = std.time.microTimestamp() + std.time.us_per_s;
    while (true) {
        const now = std.time.microTimestamp();

        if (now > last_report_time) {
            std.debug.print("TPS: {d}\n", .{tps});
            tps = 0;
            last_report_time = now + std.time.us_per_s;
        }
        tps += 1;

        if (now < next_tick_time) {
            std.Thread.sleep(std.time.ns_per_us * @as(u64, @bitCast(next_tick_time - now)));
        }

        server.tick();

        next_tick_time = std.time.microTimestamp() + tick_duration;
    }
}
