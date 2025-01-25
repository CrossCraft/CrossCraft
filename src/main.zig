const std = @import("std");
const log = std.log;

const c = @import("constants.zig");
const IO = @import("io.zig");

const StaticAllocator = @import("static_allocator.zig");
const server = @import("server.zig");

pub fn main() !void {
    // Boilerplate
    log.info("Starting CrossCraft Server {}.{}.{}", .{ c.MajorVersion, c.MinorVersion, c.PatchVersion });

    var gpa = std.heap.GeneralPurposeAllocator(.{ .enable_memory_limit = true }){};
    gpa.requested_memory_limit = c.WorldDepth * c.WorldHeight * c.WorldLength + 4;
    defer _ = gpa.deinit();

    var sta = StaticAllocator.init(gpa.allocator());
    defer sta.deinit();

    var io = try IO.init();
    defer io.deinit();

    // Create initial server state
    try server.init(sta.allocator());
    sta.transition_to_static();

    std.debug.print("Static Limit Hit! Total Allocated: {} bytes\n", .{gpa.total_requested_bytes});

    defer sta.transition_to_deinit();
    defer server.deinit();

    // Create client socket driver
    const socket = try io.create_server_socket(0x7F000001, 25565);
    defer io.close_socket(socket);

    var start_second = std.time.timestamp();
    var tps: usize = 0;

    // Main loop
    var start_timestamp = std.time.nanoTimestamp();
    while (true) {
        const curr_second = std.time.timestamp();
        if (curr_second != start_second) {
            log.info("TPS: {}", .{tps});
            tps = 0;
            start_second = curr_second;
        }

        const current_timestamp = std.time.nanoTimestamp();
        const delta = current_timestamp - start_timestamp;
        const diff = delta - c.TickSpeedNS;

        // Create new delta
        if (delta >= c.TickSpeedNS) {
            // Try to keep us on track
            start_timestamp = current_timestamp - diff;
        }

        // Add a new client connection
        const conn = try io.accept(socket);
        if (conn) |cl| {
            const client_addr = std.mem.toBytes(cl.address.addr);

            log.info("New connection: {}.{}.{}.{}:{}", .{ client_addr[0], client_addr[1], client_addr[2], client_addr[3], @byteSwap(cl.address.port) });

            server.new_client(cl);
        }

        // Process all events
        server.tick();
        tps += 1;

        // How much time did we take?
        const post_process_timestamp = std.time.nanoTimestamp();
        const total_time_taken = post_process_timestamp - current_timestamp + diff;

        // If less than the goal tick rate, continue
        if (total_time_taken < c.TickSpeedNS) {
            const remaining_time = c.TickSpeedNS - total_time_taken;
            std.time.sleep(@intCast(remaining_time));
        } else {
            // Skip lost time
            start_timestamp = post_process_timestamp - c.TickSpeedNS;
        }
    }
}
