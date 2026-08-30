comptime {
    const game = @import("game");
    _ = @import("client/util/Zip.zig");
    _ = @import("client/graphics/TextureAtlas.zig");
    _ = @import("client/world/chunk/face.zig");
    // Game files are reachable only through the `game` module: importing them
    // by path here would place them in two modules (this test root and `game`),
    // which Zig forbids.
    _ = game.World.DumpName;
    _ = game.World.CreateName;
    _ = game.World.WorldSimulation;
    _ = game.Client;
    _ = game.OutboundQueue;
    _ = game.PlayersDb;
    _ = game.AccessControl;
    _ = @import("client/state/Session.zig");
    _ = @import("client/state/BundledSave.zig");
    _ = @import("client/Options.zig");
    _ = @import("client/player/bindings.zig");
    _ = @import("client/ui/Ui.zig");
    _ = @import("client/ui/TextWrap.zig");
    _ = @import("server/Heartbeat.zig");
    _ = @import("server/BackupScheme.zig");
}
