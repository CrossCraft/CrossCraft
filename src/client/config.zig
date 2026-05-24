const ae = @import("aether");
const Util = ae.Util;
const Engine = ae.Engine;
const sdk = if (ae.platform == .psp) @import("pspsdk") else void;

const Profile = @This();

const MB: u32 = 1024 * 1024;
const KB: u32 = 1024;

pub const HardwareClass = enum {
    desktop,
    psp_phat,
    psp_slim,
    old_3ds,
    new_3ds,
};

hardware: HardwareClass,
total_memory_mb: u32,
chunk_radius: u32, // chunks from camera center (diameter = 2*r+1)
lod_near_radius_blocks: u32, // sections within this distance get full-detail meshing

// Initial pool layout (used by App.init before any state runs)
init_render: u32,
init_audio: u32,
init_game: u32,
init_user: u32,

// Runtime pool layout (set in GameState.init after server is up)
rt_render: u32,
rt_audio: u32,
rt_game: u32,
rt_user: u32,

const desktop_profile: Profile = .{
    .hardware = .desktop,
    .total_memory_mb = 96,
    .chunk_radius = 16,
    .lod_near_radius_blocks = 96,
    .init_render = 8 * MB,
    .init_audio = 2 * MB,
    .init_game = 2 * MB,
    .init_user = 12 * MB,
    .rt_render = 88 * MB,
    .rt_audio = 512 * KB,
    .rt_game = 512 * KB,
    .rt_user = 4 * MB + 512 * KB,
};

const psp_phat_profile: Profile = .{
    .hardware = .psp_phat,
    .total_memory_mb = 18,
    .chunk_radius = 4,
    .lod_near_radius_blocks = 0, // Always opaque leaves
    .init_render = 2 * MB,
    .init_audio = 1 * MB,
    .init_game = 1 * MB,
    .init_user = 12 * MB,
    .rt_render = 13 * MB + 512 * KB,
    .rt_audio = 0 * KB,
    .rt_game = 1 * MB,
    .rt_user = 4 * MB + 512 * KB,
};

const psp_slim_profile: Profile = .{
    .hardware = .psp_slim,
    .total_memory_mb = 36,
    .chunk_radius = 6,
    .lod_near_radius_blocks = 28,
    .init_render = 4 * MB,
    .init_audio = 2 * MB,
    .init_game = 2 * MB,
    .init_user = 12 * MB,
    .rt_render = 29 * MB + 768 * KB,
    .rt_audio = 0 * KB,
    .rt_game = 1 * MB,
    .rt_user = 4 * MB + 512 * KB,
};

var active_profile: Profile = if (ae.platform == .psp) psp_phat_profile else desktop_profile;

/// Select the runtime capability profile. Must run before any client memory
/// allocation so PSP-1000 stays on the conservative pool layout while PSP
/// 2000+ can use the larger profile in the same binary.
pub fn init() void {
    active_profile = if (ae.platform == .psp) switch (sdk.model.current()) {
        .phat => psp_phat_profile,
        .slim => psp_slim_profile,
    } else desktop_profile;
}

pub fn current() Profile {
    return active_profile;
}

/// Max chunks that fit within the radius (circular, clamped to 16x16 world).
/// Uses the bounding square (2r+1)^2 as upper bound for array sizing.
pub fn max_sections() u32 {
    const diameter = max_chunk_radius() * 2 + 1;
    return diameter * diameter * 4; // * SECTIONS_Y
}

pub fn init_memory() Util.MemoryConfig {
    const profile = current();
    return .{
        .render = profile.init_render,
        .audio = profile.init_audio,
        .game = profile.init_game,
        .user = profile.init_user,
    };
}

pub fn apply_runtime_budgets(engine: *Engine) void {
    const profile = current();
    engine.set_budget(.render, profile.rt_render);
    engine.set_budget(.audio, profile.rt_audio);
    engine.set_budget(.game, profile.rt_game);
    engine.set_budget(.user, profile.rt_user);
}

/// Restore the startup pool layout. Called on entry to MenuState so the next
/// LoadState connect/load has the larger init_user budget back -- after a
/// GameState session the user pool is shrunk to rt_user, which is too tight
/// for the MP connect path's 2 MiB scratch + 4 MiB world allocation.
pub fn apply_init_budgets(engine: *Engine) void {
    const profile = current();
    engine.set_budget(.render, profile.init_render);
    engine.set_budget(.audio, profile.init_audio);
    engine.set_budget(.game, profile.init_game);
    engine.set_budget(.user, profile.init_user);
}

fn max_chunk_radius() u32 {
    return if (ae.platform == .psp) psp_slim_profile.chunk_radius else desktop_profile.chunk_radius;
}
