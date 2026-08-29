const std = @import("std");
const ae = @import("aether");
const game = @import("game");

const Util = ae.Util;
const CompressWorker = game.CompressWorker;

const COMPRESSOR_STACK_SIZE = 512 * 1024;

pub const Thread = Util.Thread;

pub fn spawn(allocator: std.mem.Allocator) !Thread {
    return spawn_named("world_compress", allocator);
}

pub fn spawn_named(name: [:0]const u8, allocator: std.mem.Allocator) !Thread {
    return Util.Thread.spawn(.{
        .name = name,
        .stack_size = COMPRESSOR_STACK_SIZE,
        .priority = .lowest,
        .allocator = allocator,
    }, CompressWorker.worker_main, .{});
}
