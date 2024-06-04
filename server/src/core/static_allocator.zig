// Design based on: https://github.com/tigerbeetle/tigerbeetle/blob/main/src/static_allocator.zig
// License: Apache-2.0, found in licenses/LICENSE.tigerbeetle

const std = @import("std");
const assert = std.debug.assert;
const mem = std.mem;

const Self = @This();
backing_allocator: mem.Allocator,
state: State,

const State = enum {
    // Allow `alloc` and `resize`
    // If a `free` happens the allocator switches to `deinit`
    init,

    // No allocations allowed
    static,

    // Allow `free`
    deinit,
};

pub fn init(backing_allocator: mem.Allocator) Self {
    return .{
        .backing_allocator = backing_allocator,
        .state = .init,
    };
}

pub fn deinit(self: *Self) void {
    self.* = undefined;
}

pub fn transition_to_static(self: *Self) void {
    assert(self.state == .init);
    self.state = .static;
}

pub fn transition_to_deinit(self: *Self) void {
    assert(self.state == .static);
    self.state = .deinit;
}

pub fn allocator(self: *Self) mem.Allocator {
    return .{
        .ptr = self,
        .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .free = free,
        },
    };
}

fn alloc(ctx: *anyopaque, len: usize, ptr_align: u8, ret_addr: usize) ?[*]u8 {
    const self: *Self = @alignCast(@ptrCast(ctx));
    assert(self.state == .init);
    return self.backing_allocator.rawAlloc(len, ptr_align, ret_addr);
}

fn resize(ctx: *anyopaque, buf: []u8, buf_align: u8, new_len: usize, ret_addr: usize) bool {
    const self: *Self = @alignCast(@ptrCast(ctx));
    assert(self.state == .init);
    return self.backing_allocator.rawResize(buf, buf_align, new_len, ret_addr);
}

fn free(ctx: *anyopaque, buf: []u8, buf_align: u8, ret_addr: usize) void {
    const self: *Self = @alignCast(@ptrCast(ctx));
    assert(self.state == .init or self.state == .deinit);
    self.state = .deinit;
    self.backing_allocator.rawFree(buf, buf_align, ret_addr);
}
