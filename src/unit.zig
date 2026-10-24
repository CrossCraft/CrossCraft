const ParticleSystem = @import("client/world/ParticleSystem.zig");
const Rain = @import("client/world/Rain.zig");
const LoadState = @import("client/state/LoadState.zig");
const BundledSave = @import("client/state/BundledSave.zig");
const bindings = @import("client/player/bindings.zig");
const ServerState = @import("server/ServerState.zig");

comptime {
    _ = ParticleSystem;
    _ = Rain;
    _ = LoadState;
    _ = BundledSave;
    _ = bindings;
    _ = ServerState;
}
