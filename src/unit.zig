comptime {
    _ = @import("client/util/Zip.zig");
    _ = @import("client/graphics/TextureAtlas.zig");
    _ = @import("client/world/chunk/face.zig");
    _ = @import("game/world/DumpName.zig");
    _ = @import("game/world/CreateName.zig");
    _ = @import("game/world/WorldSimulation.zig");
    _ = @import("game/client.zig");
    _ = @import("game/players_db.zig");
    _ = @import("game/access_control.zig");
    _ = @import("client/state/Session.zig");
    _ = @import("client/state/BundledSave.zig");
    _ = @import("client/Options.zig");
    _ = @import("client/player/bindings.zig");
    _ = @import("client/ui/Ui.zig");
    _ = @import("client/ui/TextWrap.zig");
    _ = @import("server/Heartbeat.zig");
}
