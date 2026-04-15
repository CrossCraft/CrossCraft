const std = @import("std");
const mem = std.mem;
const Alignment = mem.Alignment;
const assert = std.debug.assert;

const log = std.log.scoped(.memory);

const CountingAllocator = @This();
parent_allocator: mem.Allocator,
current: u64,
peak: u64,

pub fn init(parent_allocator: mem.Allocator) CountingAllocator {
    return .{
        .parent_allocator = parent_allocator,
        .current = 0,
        .peak = 0,
    };
}

pub fn allocator(self: *CountingAllocator) mem.Allocator {
    return .{
        .ptr = self,
        .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        },
    };
}

pub fn print(self: *const CountingAllocator) void {
    log.info("current={d} KiB, peak={d} KiB", .{
        self.current / 1024,
        self.peak / 1024,
    });
}

fn alloc(ctx: *anyopaque, len: usize, ptr_align: Alignment, ret_addr: usize) ?[*]u8 {
    const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
    const ptr = self.parent_allocator.rawAlloc(len, ptr_align, ret_addr) orelse return null;
    self.current += len;
    self.peak = @max(self.peak, self.current);
    return ptr;
}

fn resize(ctx: *anyopaque, buf: []u8, buf_align: Alignment, new_len: usize, ret_addr: usize) bool {
    const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
    if (!self.parent_allocator.rawResize(buf, buf_align, new_len, ret_addr)) return false;
    self.current = self.current - buf.len + new_len;
    self.peak = @max(self.peak, self.current);
    return true;
}

fn remap(ctx: *anyopaque, buf: []u8, buf_align: Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
    const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
    const ptr = self.parent_allocator.rawRemap(buf, buf_align, new_len, ret_addr) orelse return null;
    self.current = self.current - buf.len + new_len;
    self.peak = @max(self.peak, self.current);
    return ptr;
}

fn free(ctx: *anyopaque, buf: []u8, buf_align: Alignment, ret_addr: usize) void {
    const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
    assert(self.current >= buf.len);
    self.current -= buf.len;
    self.parent_allocator.rawFree(buf, buf_align, ret_addr);
}
