const std = @import("std");
const StaticAllocator = @import("core/static_allocator.zig");
const Server = @import("core/server.zig").Server;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var sta = StaticAllocator.init(gpa.allocator());
    defer sta.deinit();

    const allocator = sta.allocator();

    var server = Server.init(allocator);
    defer server.deinit();

    sta.transition_to_static();

    // The only allowed true loop in the program
    while (true) {
        server.tick();
    }

    sta.transition_to_deinit();
}
