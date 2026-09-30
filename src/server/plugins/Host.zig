//! Ordered, authoritative gameplay processing. Connection and console workers
//! enqueue bounded actions; the server tick drains them through one context
//! that orders commands, movement, block decisions, and plugin events.
const std = @import("std");
const core = @import("core");
const blocks = core.blocks;
const Server = core.Server;
const Client = Server.Client;
const zb = core.zb;
const world = core.World;
const Commands = @import("../Commands.zig");
const Plugins = @import("Plugins.zig");

const log = std.log.scoped(.plugins);
const assert = std.debug.assert;

pub const queue_capacity: usize = 1024;
pub const per_player_capacity: u16 = 64;
pub const console_capacity: u16 = 16;

pub const Identity = struct {
    handle: Server.PlayerHandle,
    name_buf: [16]u8 = @splat(0),
    name_len: u8 = 0,

    fn name(self: *const Identity) []const u8 {
        return self.name_buf[0..self.name_len];
    }
};

pub const Action = union(enum) {
    position: struct {
        handle: Server.PlayerHandle,
        x: u16,
        y: u16,
        z: u16,
        yaw: u8,
        pitch: u8,
        teleport_serial: u32,
    },
    set_block: struct {
        handle: Server.PlayerHandle,
        x: u16,
        y: u16,
        z: u16,
        mode: u8,
        block: u8,
    },
    command: struct {
        handle: ?Server.PlayerHandle,
        line: [72]u8 = @splat(0),
        line_len: u8 = 0,
    },
    join: Identity,
    leave: Identity,
};

/// A block attempt presented to decision handlers before mutation. The player
/// snapshot is filled by the plugins manager when decisions are collected.
pub const BlockAttempt = struct {
    player: Server.PlayerInfo = undefined,
    x: u16,
    y: u16,
    z: u16,
    mode: zb.ClickMode,
    block: blocks.Block,
    old_block: blocks.Block,
};

/// Denial reason text travels with the deciding plugin's own notification;
/// the host consumes only the final rule decision. A denial wins over a
/// consume result.
pub const Decision = union(enum) { allow, consume, deny };

pub const Host = @This();

queue: [queue_capacity]?Action = @splat(null),
head: usize = 0,
count: usize = 0,
mutex: std.Io.Mutex = .init,
pending_per_slot: [Server.MaxPlayers]u16 = @splat(0),
console_pending: u16 = 0,
plugins: ?*Plugins = null,
player_write: *const fn (ctx: *anyopaque, line: []const u8) void = undefined,
console_sink: Commands.Sink = undefined,
/// Monotonic stage before gameplay actions; rechecked while draining so
/// queued traffic cannot extend a timed phase.
deadline_ms: i64 = 0,
dropped_log_ms: i64 = 0,

pub var instance: ?*Host = null;

pub fn enqueue(self: *Host, action: Action) void {
    self.mutex.lockUncancelable(Server.io);

    switch (action) {
        .position => |p| {
            assert(p.handle.id < Server.MaxPlayers);
            if (self.pending_per_slot[p.handle.id] >= per_player_capacity) {
                self.mutex.unlock(Server.io);
                return;
            }
        },
        .set_block => |b| {
            assert(b.handle.id < Server.MaxPlayers);
            if (self.pending_per_slot[b.handle.id] >= per_player_capacity) {
                self.mutex.unlock(Server.io);
                self.reassert_block(b.handle, .{ b.x, b.y, b.z });
                return;
            }
        },
        .command => |c| {
            const full = if (c.handle) |handle|
                self.pending_per_slot[handle.id] >= per_player_capacity
            else
                self.console_pending >= console_capacity;
            if (full) {
                self.mutex.unlock(Server.io);
                return;
            }
        },
        .join, .leave => {},
    }
    if (self.count == queue_capacity) {
        const now = Client.now_ms();
        self.mutex.unlock(Server.io);
        if (now - self.dropped_log_ms > 1000) {
            self.dropped_log_ms = now;
            log.warn("Gameplay queue is full; dropping actions", .{});
        }
        return;
    }

    assert(self.count < queue_capacity);
    const slot = (self.head + self.count) % queue_capacity;
    assert(self.queue[slot] == null);
    self.queue[slot] = action;
    self.count += 1;
    switch (action) {
        .position => |p| self.pending_per_slot[p.handle.id] += 1,
        .set_block => |b| self.pending_per_slot[b.handle.id] += 1,
        .command => |c| if (c.handle) |handle| {
            self.pending_per_slot[handle.id] += 1;
        } else {
            self.console_pending += 1;
        },
        .join, .leave => {},
    }
    self.mutex.unlock(Server.io);
}

pub fn enqueue_command(self: *Host, handle: ?Server.PlayerHandle, line: []const u8) void {
    var action: Action = .{ .command = .{ .handle = handle } };
    const len = @min(line.len, action.command.line.len);
    @memcpy(action.command.line[0..len], line[0..len]);
    action.command.line_len = @intCast(len);
    self.enqueue(action);
}

fn pop(self: *Host) ?Action {
    self.mutex.lockUncancelable(Server.io);
    defer self.mutex.unlock(Server.io);

    assert(self.count <= queue_capacity);
    if (self.count == 0) return null;
    const action = self.queue[self.head].?;
    self.queue[self.head] = null;
    self.head = (self.head + 1) % queue_capacity;
    self.count -= 1;
    switch (action) {
        .position => |p| self.pending_per_slot[p.handle.id] -= 1,
        .set_block => |b| self.pending_per_slot[b.handle.id] -= 1,
        .command => |c| if (c.handle) |handle| {
            self.pending_per_slot[handle.id] -= 1;
        } else {
            self.console_pending -= 1;
        },
        .join, .leave => {},
    }
    return action;
}

/// Process queued actions until the deadline stage passes. Called from the
/// tick thread only, so script execution never overlaps other workers.
pub fn drain(self: *Host) void {
    while (Client.now_ms() < self.deadline_ms) {
        const action = self.pop() orelse return;
        self.dispatch(action);
    }
}

fn resolve(self: *Host, handle: Server.PlayerHandle) ?*Client {
    _ = self;
    assert(handle.id < Server.MaxPlayers);
    Server.lock_roster_shared();
    defer Server.unlock_roster_shared();

    const client = &(Server.players.items[handle.id] orelse return null);
    if (client.id != handle.id or client.generation != handle.generation) return null;
    if (!client.initialized or !client.authenticated.load(.acquire)) return null;
    return client;
}

fn dispatch(self: *Host, action: Action) void {
    switch (action) {
        .position => |p| {
            const client = self.resolve(p.handle) orelse return;
            // Position reports already in flight when a teleport committed
            // are dropped; no acknowledgement packet is required.
            if (client.teleport_serial.load(.acquire) != p.teleport_serial) return;
            const before = client.pose.load();
            client.apply_position(.{
                .pid = -1,
                .x = p.x,
                .y = p.y,
                .z = p.z,
                .yaw = p.yaw,
                .pitch = p.pitch,
            });
            if (self.plugins) |plugins| {
                plugins.dispatch_position(p.handle, p.teleport_serial, before, client.pose.load());
            }
        },
        .set_block => |b| self.dispatch_set_block(b),
        .command => |c| {
            if (c.handle) |handle| {
                const client = self.resolve(handle) orelse return;
                const sink: Commands.Sink = .{ .ctx = client, .write_fn = self.player_write };
                Commands.dispatch(sink, c.line[0..c.line_len], .{ .player = client });
            } else {
                Commands.dispatch(self.console_sink, c.line[0..c.line_len], .console);
            }
        },
        .join => |identity| if (self.plugins) |plugins| plugins.dispatch_join(identity.handle, identity.name()),
        .leave => |identity| if (self.plugins) |plugins| plugins.dispatch_leave(identity.handle, identity.name()),
    }
}

fn dispatch_set_block(self: *Host, b: @FieldType(Action, "set_block")) void {
    const mode = std.enums.fromInt(zb.ClickMode, b.mode) orelse return;
    const client = self.resolve(b.handle) orelse return;

    world.lock_world_shared();
    var attempt = BlockAttempt{
        .x = b.x,
        .y = b.y,
        .z = b.z,
        .mode = mode,
        .block = @enumFromInt(b.block),
        .old_block = world.get_block(b.x, b.y, b.z),
    };
    world.unlock_world_shared();

    var decision: Decision = .allow;
    if (self.plugins) |plugins| {
        decision = plugins.decide_block_attempt(client, &attempt);
        if (decision == .allow) {
            plugins.begin_edit(.{ .id = @intCast(client.id), .generation = client.generation });
            client.apply_set_block(.{
                .x = b.x,
                .y = b.y,
                .z = b.z,
                .mode = b.mode,
                .block = b.block,
            });
            plugins.end_edit();
            return;
        }
    } else {
        client.apply_set_block(.{
            .x = b.x,
            .y = b.y,
            .z = b.z,
            .mode = b.mode,
            .block = b.block,
        });
        return;
    }

    {
        // Correct the client-predicted block state for denied or
        // consumed edits.
        world.lock_world_shared();
        const current = world.get_block(b.x, b.y, b.z);
        world.unlock_world_shared();
        client.send_block_change(b.x, b.y, b.z, current) catch {};
    }
}

fn reassert_block(self: *Host, handle: Server.PlayerHandle, cell: [3]u16) void {
    _ = self;
    const client = blk: {
        Server.lock_roster_shared();
        defer Server.unlock_roster_shared();

        const c = &(Server.players.items[handle.id] orelse return);
        if (c.generation != handle.generation or !c.initialized) return;
        break :blk c;
    };
    world.lock_world_shared();
    const current = world.get_block(cell[0], cell[1], cell[2]);
    world.unlock_world_shared();
    client.send_block_change(cell[0], cell[1], cell[2], current) catch {};
}
