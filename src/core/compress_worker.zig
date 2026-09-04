// One process-wide worker thread runs gzip jobs out of a lock-free LIFO
// queue. The host spawns `worker_main`; jobs run serially because the shared
// compressor is not reentrant.

const std = @import("std");
const assert = std.debug.assert;
const builtin = @import("builtin");
const flate = std.compress.flate;

pub const Job = struct {
    next: ?*Job = null,
    state: std.atomic.Value(State) = .init(.pending),
    err: ?anyerror = null,
    run: *const fn (*Job) anyerror!void,

    const State = enum(u32) { pending, done };

    pub fn is_done(self: *const Job) bool {
        return self.state.load(.acquire) == .done;
    }

    /// Claim a completed reusable job for another submission.
    pub fn try_begin(self: *Job) bool {
        return self.state.cmpxchgStrong(.done, .pending, .acq_rel, .acquire) == null;
    }

    pub fn wait(self: *Job, io: std.Io) void {
        while (self.state.load(.acquire) == .pending) {
            io.futexWaitUncancelable(State, &self.state.raw, .pending);
        }
    }

    pub fn mark_done(self: *Job, io: std.Io) void {
        self.state.store(.done, .release);
        io.futexWake(State, &self.state.raw, std.math.maxInt(u32));
    }
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
    errdefer alloc.destroy(compress_buf);
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

test "compression initialization releases allocations on failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn check(allocator: std.mem.Allocator) !void {
            try init(allocator, std.testing.io);
            deinit();
        }
    }.check, .{});
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

/// Push a pending job onto the queue. Caller must keep it alive until done.
pub fn submit(job: *Job) void {
    assert(!job.is_done());
    while (true) {
        const head = queue_head.load(.monotonic);
        job.next = head;
        if (queue_head.cmpxchgWeak(head, job, .release, .monotonic) == null) return;
    }
}

/// Cancel during init failure, before any worker can be running.
pub fn cancel_pending_before_worker(job: *Job) bool {
    var node = queue_head.swap(null, .acquire);
    var restore_head: ?*Job = null;
    var canceled = false;

    while (node) |current| {
        const next = current.next;
        if (current == job) {
            current.next = null;
            current.mark_done(stored_io);
            canceled = true;
        } else {
            current.next = restore_head;
            restore_head = current;
        }
        node = next;
    }

    queue_head.store(restore_head, .release);
    return canceled;
}

pub fn signal_exit() void {
    worker_exit.store(true, .release);
}

fn drain_once() bool {
    const head = queue_head.swap(null, .acquire) orelse return false;
    var node: ?*Job = head;
    while (node) |j| {
        const next = j.next;
        j.run(j) catch |e| {
            j.err = e;
        };
        j.mark_done(stored_io);
        node = next;
    }
    return true;
}

test "reusable job admits one submission at a time" {
    const noop = struct {
        fn run(_: *Job) anyerror!void {}
    }.run;
    var job: Job = .{ .state = .init(.done), .run = noop };

    try std.testing.expect(job.is_done());
    try std.testing.expect(job.try_begin());
    try std.testing.expect(!job.try_begin());
    try std.testing.expect(!job.is_done());

    job.mark_done(std.testing.io);
    try std.testing.expect(job.is_done());
    try std.testing.expect(job.try_begin());
    job.mark_done(std.testing.io);
    job.wait(std.testing.io);
}

test "queued jobs publish errors and queued cancellation completes" {
    const ProbeJob = struct {
        base: Job,
        runs: *u32,
        fail: bool,

        fn init(runs: *u32, fail: bool) @This() {
            return .{
                .base = .{ .state = .init(.done), .run = execute },
                .runs = runs,
                .fail = fail,
            };
        }

        fn execute(base: *Job) anyerror!void {
            const self: *@This() = @fieldParentPtr("base", base);
            self.runs.* += 1;
            if (self.fail) return error.ForcedFailure;
        }
    };

    try std.testing.expect(queue_head.load(.acquire) == null);
    defer queue_head.store(null, .release);

    stored_io = std.testing.io;

    var runs: u32 = 0;
    var successful = ProbeJob.init(&runs, false);
    var failing = ProbeJob.init(&runs, true);
    try std.testing.expect(successful.base.try_begin());
    try std.testing.expect(failing.base.try_begin());
    submit(&successful.base);
    submit(&failing.base);

    try std.testing.expect(drain_once());
    try std.testing.expectEqual(@as(u32, 2), runs);
    try std.testing.expect(successful.base.is_done());
    try std.testing.expect(failing.base.is_done());
    try std.testing.expect(successful.base.err == null);
    try std.testing.expectEqual(error.ForcedFailure, failing.base.err.?);
    try std.testing.expect(!drain_once());

    var canceled = ProbeJob.init(&runs, false);
    try std.testing.expect(canceled.base.try_begin());
    submit(&canceled.base);
    try std.testing.expect(cancel_pending_before_worker(&canceled.base));
    try std.testing.expect(canceled.base.is_done());
    try std.testing.expectEqual(@as(u32, 2), runs);
    try std.testing.expect(!drain_once());
}

/// Needs a large stack and lower priority than the main thread: PSP does not
/// preempt equal-priority threads during long compression runs.
pub fn worker_main() void {
    // Raw PSP threads do not inherit the per-thread filesystem cwd.
    if (comptime builtin.os.tag == .psp) {
        var cwd_buf: [1024]u8 = undefined;
        if (std.process.currentPath(stored_io, &cwd_buf)) |n| {
            std.process.setCurrentPath(stored_io, cwd_buf[0..n]) catch {};
        } else |_| {}
    }

    while (!worker_exit.load(.acquire)) {
        if (!drain_once()) {
            std.Io.sleep(stored_io, .fromMilliseconds(10), .real) catch {};
        }
    }
}
