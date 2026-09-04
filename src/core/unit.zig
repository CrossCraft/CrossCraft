comptime {
    _ = @import("world_dims.zig");
    _ = @import("blocks.zig");
    _ = @import("physics.zig");
    _ = @import("access_control.zig");
    _ = @import("outbound_queue.zig");
    _ = @import("compress_worker.zig");
    _ = @import("players_db.zig");
    _ = @import("client.zig");
    _ = @import("server.zig");
    _ = @import("nbt/nbt.zig");
    _ = @import("world.zig");
    _ = @import("world/SaveName.zig");
    _ = @import("world/WorldData.zig");
    _ = @import("world/WorldSaver.zig");
    _ = @import("world/WorldSimulation.zig");
    _ = @import("world/SaveFormat.zig");
    _ = @import("world/formats/classic_cw.zig");
    _ = @import("world/formats/classic_dat.zig");
}
