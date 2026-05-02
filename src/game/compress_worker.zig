// --- Shared gzip compression worker ---
//
// One process-wide worker thread runs gzip jobs out of a lock-free LIFO
// queue. Both world-send (network) and world-save (disk, classic_cw) submit
// here so the deep `flate.Compress` call frames stay out of the per-task
// IO async stacks (64 KB on PSP -- not enough for the 32 KB sliding window
// plus the deflate finish path).
//
// This module owns the static state and the loop body. Spawning the OS
// thread is the consumer's job (server's `ServerState`, client's
// `LoadState`) since the game module is platform-agnostic and cannot pull
// in Aether's `Util.Thread`. Pass `worker_main` as the spawn entry point.
//
// Concurrency: only one job runs at a time -- the compressor is global
// and not reentrant.

const std = @import("std");
const builtin = @import("builtin");
const flate = std.compress.flate;

pub const Job = struct {
    next: ?*Job = null,
    done: std.atomic.Value(bool) = .init(false),
    err: ?anyerror = null,
    run: *const fn (*Job) anyerror!void,
};

var backing_allocator: std.mem.Allocator = undefined;
var compress_buf: *[flate.max_window_len]u8 = undefined;
pub var compressor: *flate.Compress = undefined;
var queue_head: std.atomic.Value(?*Job) = .init(null);
var worker_exit: std.atomic.Value(bool) = .init(false);
var stored_io: std.Io = undefined;

// Resolve the compress writer vtable at comptime so the runtime reset
// path doesn't have to call into private flate internals.
const compress_writer_vtable: *const std.Io.Writer.VTable = blk: {
    var dummy_buf: [16]u8 = undefined;
    var dummy = std.Io.Writer.fixed(&dummy_buf);
    var buf: [flate.max_window_len]u8 = undefined;
    const comp = flate.Compress.init(&dummy, &buf, .gzip, .fastest) catch unreachable;
    break :blk comp.writer.vtable;
};

pub fn init(alloc: std.mem.Allocator, io: std.Io) !void {
    backing_allocator = alloc;
    compress_buf = try alloc.create([flate.max_window_len]u8);
    compressor = try alloc.create(flate.Compress);
    compressor.* = undefined;
    queue_head = .init(null);
    worker_exit = .init(false);
    stored_io = io;
}

pub fn deinit() void {
    backing_allocator.destroy(compressor);
    backing_allocator.destroy(compress_buf);
}

/// Reset the global compressor for a new gzip stream targeting `output`.
/// Must be called from the worker thread (single job at a time).
pub fn reset(output: *std.Io.Writer) !void {
    try output.writeAll(flate.Container.gzip.header());
    compressor.writer = .{
        .vtable = compress_writer_vtable,
        .buffer = compress_buf,
    };
    compressor.history_len = 0;
    compressor.history_end_unhashed = false;
    compressor.bit_writer = .{
        .output = output,
        .buffered = 0,
        .buffered_n = 0,
    };
    compressor.buffered_tokens = .{
        .list = undefined,
        .pos = 0,
        .n = 0,
        .lit_freqs = @splat(0),
        .dist_freqs = @splat(0),
    };
    compressor.lookup = .{
        .head = @splat(.{ .value = std.math.maxInt(u15), .is_null = true }),
        .chain = undefined,
        .chain_pos = std.math.maxInt(u15),
    };
    compressor.container = .gzip;
    compressor.hasher = .init(.gzip);
    compressor.opts = .fastest;
}

/// Push a job onto the queue. Caller must keep `job` alive until
/// `job.done` reads true.
pub fn submit(job: *Job) void {
    while (true) {
        const head = queue_head.load(.monotonic);
        job.next = head;
        if (queue_head.cmpxchgWeak(head, job, .release, .monotonic) == null) return;
    }
}

pub fn signal_exit() void {
    worker_exit.store(true, .release);
}

pub fn should_exit() bool {
    return worker_exit.load(.acquire);
}

/// Drain one batch of pending jobs. Returns true if at least one job ran.
pub fn drain_once() bool {
    const head = queue_head.swap(null, .acquire) orelse return false;
    var node: ?*Job = head;
    while (node) |j| {
        const next = j.next;
        j.run(j) catch |e| {
            j.err = e;
        };
        j.done.store(true, .release);
        node = next;
    }
    return true;
}

/// Long-running thread entry point. Spawn this with a 384 KB stack on a
/// non-IO-tracked thread (Aether's `Util.Thread.spawn`).
///
/// Caveat: `std.Io.sleep` returns immediately from non-tracked threads on
/// PSP, so this loop hot-spins there. Acceptable -- the work itself
/// pegs a core during compression, and at idle the thread still yields
/// at OS-scheduler granularity.
pub fn worker_main() void {
    // PSP: pspsdk's per-thread kernel cwd is only initialised by io-tracked
    // thread entries (futureThreadEntry / groupThreadEntry call its private
    // inheritCwd). `Util.Thread.spawn` skips that, so without this the
    // worker starts with whatever the SCE default cwd is and every
    // relative-path file open from here returns the catch-all
    // `error.AccessDenied`. Re-apply the tracked cwd by reading it back
    // and pushing it through `setCurrentPath`, which calls `sceIoChdir`
    // on the calling thread.
    if (comptime builtin.os.tag == .psp) {
        var cwd_buf: [1024]u8 = undefined;
        if (std.process.currentPath(stored_io, &cwd_buf)) |n| {
            std.process.setCurrentPath(stored_io, cwd_buf[0..n]) catch {};
        } else |_| {}
    }

    while (!should_exit()) {
        if (!drain_once()) {
            std.Io.sleep(stored_io, .fromMilliseconds(10), .real) catch {};
        }
    }
}
