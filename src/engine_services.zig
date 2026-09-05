//! Aether adapters installed by executable hosts, never imported by Core.
const std = @import("std");
const ae = @import("aether");
const core = @import("core");
const Worker = core.CompressWorker;

pub fn install() void {
    Worker.scheduler = .{ .init = create, .deinit = destroy, .start = start, .submit = submit, .cancel = cancel };
    core.Host.replace_file = replace_file;
}

const slot_count = core.Server.MaxPlayers + 2;
const Slot = struct {
    job: ae.Jobs.Job = .{ .context = undefined, .run = run },
    request: *Worker.Job = undefined,

    fn run(context: *anyopaque) !void {
        const self: *Slot = @ptrCast(@alignCast(context));
        // Completion is the final access to the game's borrowed request. The
        // slot remains alive until the engine publishes its own completion.
        const request = self.request;
        request.run(request) catch |err| {
            request.err = err;
        };
        request.mark_done();
    }
};

const Scheduler = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    executor: *ae.Jobs.Executor,
    slots: [slot_count]Slot = @splat(.{}),
    mutex: std.Io.Mutex = .init,
};

fn create(allocator: std.mem.Allocator, io: std.Io) !*anyopaque {
    const self = try allocator.create(Scheduler);
    errdefer allocator.destroy(self);
    self.* = .{ .allocator = allocator, .io = io, .executor = try ae.Jobs.Executor.init(allocator, io, .{
        .capacity = slot_count,
        .mode = if (ae.System.info().background_workers) .manual else .inline_execution,
    }) };
    for (&self.slots) |*slot| slot.job.context = slot;
    return self;
}

fn destroy(context: *anyopaque) void {
    const self: *Scheduler = @ptrCast(@alignCast(context));
    self.executor.deinit();
    self.allocator.destroy(self);
}

fn start(context: *anyopaque, name: [:0]const u8) !void {
    const self: *Scheduler = @ptrCast(@alignCast(context));
    if (self.executor.mode == .inline_execution) return;
    try self.executor.start_thread(.{ .name = name, .stack_size = 512 * 1024, .priority = .lowest });
}

fn submit(context: *anyopaque, request: *Worker.Job) !void {
    const self: *Scheduler = @ptrCast(@alignCast(context));
    // Inline mode has a single app-thread producer. Release the adapter lock
    // before invoking callbacks so nested game submissions remain serial.
    var locked = true;
    self.mutex.lockUncancelable(self.io);
    defer if (locked) self.mutex.unlock(self.io);

    for (&self.slots) |*slot| {
        if (slot.job.state.load(.acquire) != .idle and !slot.job.is_done()) continue;
        slot.request = request;
        if (self.executor.mode == .inline_execution) {
            self.mutex.unlock(self.io);
            locked = false;
        }
        try self.executor.submit(&slot.job);
        return;
    }
    return error.QueueFull;
}

fn cancel(context: *anyopaque, request: *Worker.Job) bool {
    const self: *Scheduler = @ptrCast(@alignCast(context));
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);

    for (&self.slots) |*slot| {
        if (slot.job.state.load(.acquire) == .idle or slot.job.is_done()) continue;
        if (slot.request == request and self.executor.cancel(&slot.job)) {
            request.err = error.Canceled;
            request.mark_done();
            return true;
        }
    }
    return false;
}

fn replace_file(io: std.Io, dir: std.Io.Dir, path: []const u8, body: core.Host.WriteBody) !core.Host.ReplaceResult {
    const result = try ae.Storage.write_replace(io, dir, path, body, .{});
    return .{ .bytes = result.bytes, .previous_retained = result.previous_retained };
}

test "engine compression adapter drains queued work and joins before shutdown" {
    const context = try create(std.testing.allocator, std.testing.io);
    var runs: u32 = 0;
    const Request = struct {
        base: Worker.Job = .{ .run = run },
        runs: *u32,
        fn run(job: *Worker.Job) !void {
            const self: *@This() = @fieldParentPtr("base", job);
            self.runs.* += 1;
        }
    };
    var first: Request = .{ .runs = &runs };
    var second: Request = .{ .runs = &runs };
    try submit(context, &first.base);
    try submit(context, &second.base);
    try std.testing.expect(cancel(context, &second.base));
    try start(context, "test_compression");
    destroy(context);
    try std.testing.expectEqual(@as(u32, 1), runs);
    try std.testing.expect(first.base.is_done() and second.base.is_done());
}

test "engine storage adapter preserves an existing save when serialization fails" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const Body = struct {
        fn write(_: *const anyopaque, writer: *std.Io.Writer) !void {
            try writer.writeAll("partial");
            return error.ForcedFailure;
        }
    };
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "world.cw", .data = "old" });
    const context: u8 = 0;
    try std.testing.expectError(error.ForcedFailure, replace_file(std.testing.io, tmp.dir, "world.cw", .{ .context = &context, .write_fn = Body.write }));
    var buffer: [8]u8 = undefined;
    try std.testing.expectEqualStrings("old", try tmp.dir.readFile(std.testing.io, "world.cw", &buffer));
}

test "engine compression adapter permits nested inline requests" {
    const context = try create(std.testing.allocator, std.testing.io);
    defer destroy(context);

    const scheduler: *Scheduler = @ptrCast(@alignCast(context));
    scheduler.executor.mode = .inline_execution;
    const Request = struct {
        base: Worker.Job = .{ .run = run },
        scheduler: *anyopaque,
        next: ?*Worker.Job,
        order: *u32,
        fn run(job: *Worker.Job) !void {
            const self: *@This() = @fieldParentPtr("base", job);
            self.order.* = self.order.* * 10 + 1;
            if (self.next) |next| {
                try submit(self.scheduler, next);
                try std.testing.expect(!next.is_done());
            }
            self.order.* = self.order.* * 10 + 2;
        }
    };
    var order: u32 = 0;
    var child: Request = .{ .scheduler = context, .next = null, .order = &order };
    var parent: Request = .{ .scheduler = context, .next = &child.base, .order = &order };
    try submit(context, &parent.base);
    try std.testing.expect(parent.base.is_done() and child.base.is_done());
    try std.testing.expectEqual(@as(u32, 1212), order);
}
