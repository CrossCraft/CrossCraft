const std = @import("std");
const ae = @import("aether");
const core = @import("core");

const Util = ae.Util;
const CompressWorker = core.CompressWorker;

const COMPRESSOR_STACK_SIZE = 512 * 1024;

pub const Thread = Util.Thread;

pub fn spawn(allocator: std.mem.Allocator) !Thread {
    return Util.Thread.spawn(.{
        .name = "world_compress",
        .stack_size = COMPRESSOR_STACK_SIZE,
        .priority = .lowest,
        .allocator = allocator,
    }, CompressWorker.worker_main, .{});
}
