comptime {
    const core = @import("core");
    _ = @import("client/util/Zip.zig");
    _ = @import("client/graphics/TextureAtlas.zig");
    _ = @import("client/world/chunk/face.zig");
    // Core files are reachable only through the `core` module: importing them
    // by path here would place them in two modules (this test root and `core`),
    // which Zig forbids.
    _ = core.World.DumpName;
    _ = core.World.CreateName;
    _ = core.World.WorldSimulation;
    _ = core.Client;
    _ = core.OutboundQueue;
    _ = core.PlayersDb;
    _ = core.AccessControl;
    _ = @import("client/state/Session.zig");
    _ = @import("client/state/BundledSave.zig");
    _ = @import("client/Options.zig");
    _ = @import("client/config.zig");
    _ = @import("client/player/bindings.zig");
    _ = @import("client/ui/Ui.zig");
    _ = @import("client/ui/TextWrap.zig");
    _ = @import("client/ui/screens/CreateWorld.zig");
    _ = @import("server/Heartbeat.zig");
    _ = @import("server/BackupScheme.zig");
}
