comptime {
    _ = @import("client/util/Zip.zig");
    _ = @import("client/graphics/TextureAtlas.zig");
    _ = @import("client/world/chunk/face.zig");
    _ = @import("client/world/chunk/mesher.zig");
    _ = @import("client/world/ParticleSystem.zig");
    _ = @import("client/world/Rain.zig");
    _ = @import("client/state/Session.zig");
    _ = @import("client/connection/ClientConn.zig");
    _ = @import("client/state/BundledSave.zig");
    _ = @import("client/Options.zig");
    _ = @import("client/config.zig");
    _ = @import("client/player/bindings.zig");
    _ = @import("client/ui/Buttons.zig");
    _ = @import("client/ui/Ui.zig");
    _ = @import("client/ui/TextWrap.zig");
    _ = @import("server/ServerState.zig");
    _ = @import("server/Heartbeat.zig");
    _ = @import("server/Config.zig");
    _ = @import("server/AccessControl.zig");
    _ = @import("server/PlayersDb.zig");
    _ = @import("server/Commands.zig");
}
