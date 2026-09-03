// Test root for the `core` module.
comptime {
    _ = @import("world_dims.zig");
    _ = @import("blocks.zig");
    _ = @import("access_control.zig");
    _ = @import("outbound_queue.zig");
    _ = @import("players_db.zig");
    _ = @import("client.zig");
    _ = @import("server.zig");
    _ = @import("nbt/nbt.zig");
    _ = @import("world.zig");
    _ = @import("world/DumpName.zig");
    _ = @import("world/CreateName.zig");
    _ = @import("world/WorldData.zig");
    _ = @import("world/WorldSimulation.zig");
    _ = @import("world/SaveFormat.zig");
    _ = @import("world/formats/classic_cw.zig");
    _ = @import("world/formats/classic_dat.zig");
}
