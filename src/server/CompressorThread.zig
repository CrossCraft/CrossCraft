const std = @import("std");
const builtin = @import("builtin");
const ae = @import("aether");
const game = @import("game");

const Util = ae.Util;
const CompressWorker = game.CompressWorker;
const psp = if (builtin.os.tag == .psp) @import("pspsdk") else void;

const PSP_COMPRESSOR_PRIORITY = 0x12;
const COMPRESSOR_STACK_SIZE = 512 * 1024;

const PspThread = if (builtin.os.tag == .psp) struct {
    thid: psp.SceUID,

    pub fn join(self: @This()) void {
        psp.kernel.wait_thread_end(self.thid, null) catch {};
        psp.kernel.delete_thread(self.thid) catch {};
    }
} else struct {};

pub const Thread = if (builtin.os.tag == .psp) PspThread else Util.Thread;

fn psp_entry(_: usize, _: ?*anyopaque) callconv(.c) c_int {
    psp.extra.fpu.setIEEE754();
    CompressWorker.worker_main();
    return 0;
}

pub fn spawn(allocator: std.mem.Allocator) !Thread {
    return spawn_named("world_compress", allocator);
}

pub fn spawn_named(name: [:0]const u8, allocator: std.mem.Allocator) !Thread {
    if (comptime builtin.os.tag == .psp) {
        const thid = psp.kernel.create_thread(
            name,
            psp_entry,
            PSP_COMPRESSOR_PRIORITY,
            COMPRESSOR_STACK_SIZE,
            .{ .user = true },
            null,
        ) catch return error.SystemResources;
        psp.kernel.start_thread(thid, 0, null) catch {
            psp.kernel.delete_thread(thid) catch {};
            return error.SystemResources;
        };
        return .{ .thid = thid };
    }

    return Util.Thread.spawn(.{
        .name = name,
        .stack_size = COMPRESSOR_STACK_SIZE,
        .priority = .normal,
        .allocator = allocator,
    }, CompressWorker.worker_main, .{});
}
