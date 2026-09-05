//! Game-owned reusable gzip context and save/transfer requests. Hosts inject
//! Aether's serial executor; std-only tools execute submitted requests inline.
const std = @import("std");
const assert = std.debug.assert;
const flate = std.compress.flate;

pub const Job = struct {
    state: std.atomic.Value(State) = .init(.pending),
    err: ?anyerror = null,
    run: *const fn (*Job) anyerror!void,
    const State = enum(u32) { pending, done };

    pub fn is_done(self: *const Job) bool {
        return self.state.load(.acquire) == .done;
    }
    pub fn try_begin(self: *Job) bool {
        return self.state.cmpxchgStrong(.done, .pending, .acq_rel, .acquire) == null;
    }
    pub fn wait(self: *Job, io: std.Io) void {
        // The request stays borrowed until completion. Preserve cancellation
        // for the caller's next cancelable operation after that storage is safe.
        const previous_protection = io.swapCancelProtection(.blocked);
        defer _ = io.swapCancelProtection(previous_protection);

        while (!self.is_done()) std.Io.sleep(io, .fromMilliseconds(1), .real) catch unreachable;
    }
    pub fn mark_done(self: *Job) void {
        assert(!self.is_done());
        // No access after this store: the requester may immediately free it.
        self.state.store(.done, .release);
    }
};

pub const Scheduler = struct {
    init: *const fn (std.mem.Allocator, std.Io) anyerror!*anyopaque,
    deinit: *const fn (*anyopaque) void,
    start: *const fn (*anyopaque, [:0]const u8) anyerror!void,
    submit: *const fn (*anyopaque, *Job) anyerror!void,
    cancel: *const fn (*anyopaque, *Job) bool,
};
/// Install before initialization; do not replace while requests are alive.
pub var scheduler: ?Scheduler = null;
var scheduler_context: ?*anyopaque = null;
var backing_allocator: std.mem.Allocator = undefined;
var compress_buf: *[flate.max_window_len]u8 = undefined;
pub var compressor: *flate.Compress = undefined;

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
    errdefer alloc.destroy(compressor);
    scheduler_context = if (scheduler) |host| try host.init(alloc, io) else null;
}

pub fn deinit() void {
    if (scheduler_context) |context| scheduler.?.deinit(context);
    scheduler_context = null;
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

/// Start delayed background execution after state initialization succeeds.
pub fn start(name: [:0]const u8) !void {
    if (scheduler_context) |context| try scheduler.?.start(context, name);
}

/// Admission failure completes the request with an error, so save/transfer
/// owners can always wait before releasing their borrowed data.
pub fn submit(job: *Job) void {
    assert(!job.is_done());
    if (scheduler_context) |context| {
        scheduler.?.submit(context, job) catch |err| {
            std.log.scoped(.world).err("compression submission failed: {}", .{err});
            job.err = err;
            job.mark_done();
        };
    } else {
        job.run(job) catch |err| {
            job.err = err;
        };
        job.mark_done();
    }
}

pub fn cancel_pending_before_worker(job: *Job) bool {
    if (scheduler_context) |context| return scheduler.?.cancel(context, job);
    return false;
}

test "reusable compression requests preserve failure and single-flight state" {
    const Fail = struct {
        fn run(_: *Job) !void {
            return error.ForcedFailure;
        }
    };
    var request: Job = .{ .state = .init(.done), .run = Fail.run };
    try std.testing.expect(request.try_begin());
    try std.testing.expect(!request.try_begin());
    submit(&request);
    request.wait(std.testing.io);
    try std.testing.expect(request.is_done());
    try std.testing.expectEqual(error.ForcedFailure, request.err.?);
}

test "compression wait preserves cancellation and restores caller protection" {
    const Probe = struct {
        job: *Job,
        protection: std.Io.CancelProtection,
        cancel_pending: bool = true,
        sleeps: usize = 0,

        fn swap_protection(context: ?*anyopaque, next: std.Io.CancelProtection) std.Io.CancelProtection {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            const previous = self.protection;
            self.protection = next;
            return previous;
        }

        fn check_cancel(context: ?*anyopaque) std.Io.Cancelable!void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            if (self.protection == .unblocked and self.cancel_pending) {
                self.cancel_pending = false;
                return error.Canceled;
            }
        }

        fn sleep(context: ?*anyopaque, _: std.Io.Timeout) std.Io.Cancelable!void {
            try check_cancel(context);
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.sleeps += 1;
            self.job.mark_done();
        }

        fn run(_: *Job) !void {}
    };
    for ([_]std.Io.CancelProtection{ .unblocked, .blocked }) |initial| {
        var job: Job = .{ .run = Probe.run };
        var probe: Probe = .{ .job = &job, .protection = initial };
        var vtable = std.testing.io.vtable.*;
        vtable.swapCancelProtection = Probe.swap_protection;
        vtable.sleep = Probe.sleep;
        vtable.checkCancel = Probe.check_cancel;
        const io: std.Io = .{ .userdata = &probe, .vtable = &vtable };
        job.wait(io);
        try std.testing.expect(job.is_done());
        try std.testing.expectEqual(@as(usize, 1), probe.sleeps);
        try std.testing.expectEqual(initial, probe.protection);
        try std.testing.expect(probe.cancel_pending);
        if (initial == .unblocked) try std.testing.expectError(error.Canceled, io.checkCancel());
    }
}
