const std = @import("std");
const core = @import("core");
const Server = core.Server;

pub fn main() !void {
    var server = try Server.init(std.heap.page_allocator);
    defer server.deinit(std.heap.page_allocator);

    while (true) {
        server.tick();
    }
}
