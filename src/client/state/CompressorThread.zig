const std = @import("std");
const ae = @import("aether");
const core = @import("core");

const Util = ae.Util;
const CompressWorker = core.CompressWorker;

pub fn spawn(name: [:0]const u8, allocator: std.mem.Allocator) !Util.Thread {
    return Util.Thread.spawn(.{
        .name = name,
        .stack_size = 512 * 1024,
        .priority = .lowest,
        .allocator = allocator,
    }, CompressWorker.worker_main, .{});
}
