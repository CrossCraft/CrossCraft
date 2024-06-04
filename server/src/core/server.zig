const std = @import("std");
const assert = std.debug.assert;

const World = @import("world.zig").World;
const WorldSize = World.WorldSize;

pub const Server = struct {
    world: World,

    /// Initialize the server.
    pub fn init(allocator: std.mem.Allocator) Server {
        var res = Server{ .world = undefined };

        // TODO: Don't hardcode world size or seed
        const WORLD_SEED: u64 = 0x1337;
        const WORLD_SIZE: WorldSize = .{
            .length = 512,
            .height = 64,
            .depth = 512,
        };

        res.world.init(allocator, WORLD_SIZE, WORLD_SEED);
        return res;
    }

    /// Tick the server.
    pub fn tick(self: *Server) void {
        // TODO: Collect from client buffers and apply to world ring buffers
        self.world.tick();
    }

    /// Deinitialize the server.
    pub fn deinit(self: *Server) void {
        self.world.deinit();
        self.* = undefined;
    }
};
