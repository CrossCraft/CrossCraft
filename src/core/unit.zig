const world_dims = @import("world_dims.zig");
const blocks = @import("blocks.zig");
const physics = @import("physics.zig");
const outbound_queue = @import("outbound_queue.zig");
const compress_worker = @import("compress_worker.zig");
const client = @import("client.zig");
const server = @import("server.zig");
const nbt = @import("nbt/nbt.zig");
const world = @import("world.zig");
const SaveName = @import("world/SaveName.zig");
const WorldData = @import("world/WorldData.zig");
const WorldSaver = @import("world/WorldSaver.zig");
const WorldSimulation = @import("world/WorldSimulation.zig");
const SaveFormat = @import("world/SaveFormat.zig");
const classic_cw = @import("world/formats/classic_cw.zig");
const classic_dat = @import("world/formats/classic_dat.zig");

comptime {
    _ = world_dims;
    _ = blocks;
    _ = physics;
    _ = outbound_queue;
    _ = compress_worker;
    _ = client;
    _ = server;
    _ = nbt;
    _ = world;
    _ = SaveName;
    _ = WorldData;
    _ = WorldSaver;
    _ = WorldSimulation;
    _ = SaveFormat;
    _ = classic_cw;
    _ = classic_dat;
}
