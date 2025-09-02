const std = @import("std");
const assert = std.debug.assert;
const GPA = std.heap.GeneralPurposeAllocator(.{});

var initialized = false;
var gpa: GPA = undefined;

pub fn init() void {
    assert(!initialized);

    gpa = GPA{};
    initialized = true;

    assert(initialized);
}

pub fn deinit() void {
    assert(initialized);

    _ = gpa.deinit();
    initialized = false;

    assert(!initialized);
}

pub fn allocator() std.mem.Allocator {
    assert(initialized);

    return gpa.allocator();
}

pub fn ctx_to_self(comptime T: type, ptr: *anyopaque) *T {
    return @ptrCast(@alignCast(ptr));
}

pub fn get_micro_timestamp() u64 {
    // TODO: This is modularized such that other platforms may use different sets here
    return @bitCast(std.time.microTimestamp());
}
