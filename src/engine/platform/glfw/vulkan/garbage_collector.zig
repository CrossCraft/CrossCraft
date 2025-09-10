const std = @import("std");
const vk = @import("vulkan");
const Renderer = @import("vulkan_gfx.zig");

const GcItem = union(enum) {
    buffer: struct { buf: vk.Buffer, mem: vk.DeviceMemory },
    // add image/sampler/etc as needed
};

const MaxFrames = 3;

allocator: std.mem.Allocator,
buckets: [MaxFrames]std.ArrayList(GcItem) = .{ .{}, .{}, .{} },
frame_index: usize = 0,

const Self = @This();

pub fn init(allocator: std.mem.Allocator) Self {
    return .{ .allocator = allocator };
}

pub fn defer_destroy_buffer(self: *Self, buf: vk.Buffer, mem: vk.DeviceMemory) !void {
    try self.buckets[self.frame_index].append(self.allocator, .{ .buffer = .{ .buf = buf, .mem = mem } });
}

pub fn collect(self: *Self) void {
    // Call this after fence[self.frame_index] is signaled.
    var list = &self.buckets[self.frame_index];
    for (list.items) |it| switch (it) {
        .buffer => |b| {
            Renderer.context.logical_device.destroyBuffer(b.buf, null);
            Renderer.context.logical_device.freeMemory(b.mem, null);
        },
    };
    list.clearRetainingCapacity();
}

pub fn deinit(self: *Self) void {
    for (&self.buckets) |*list| {
        for (list.items) |it| switch (it) {
            .buffer => |b| {
                Renderer.context.logical_device.destroyBuffer(b.buf, null);
                Renderer.context.logical_device.freeMemory(b.mem, null);
            },
        };
        list.deinit(self.allocator);
    }
}
