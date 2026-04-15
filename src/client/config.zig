const ae = @import("aether");
const Util = ae.Util;
const Engine = ae.Engine;
const build_options = @import("build_options");

const Self = @This();

const MB: u32 = 1024 * 1024;
const KB: u32 = 1024;

total_memory_mb: u32,
chunk_radius: u32, // chunks from camera center (diameter = 2*r+1)
lod_near_radius_blocks: u32, // sections within this distance get full-detail meshing
mesh_pool_mb: u32,

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

pub const current: Self = if (ae.platform == .psp and build_options.slim) .{
    .total_memory_mb = 24,
    .chunk_radius = 4,
    .lod_near_radius_blocks = 28,
    .mesh_pool_mb = 20,
    .init_render = 4 * MB,
    .init_audio = 2 * MB,
    .init_game = 2 * MB,
    .init_user = 12 * MB,
    .rt_render = 16 * MB,
    .rt_audio = 0 * KB,
    .rt_game = 256 * KB,
    .rt_user = 7 * MB,
} else if (ae.platform == .psp) .{
    .total_memory_mb = 19,
    .chunk_radius = 4,
    .lod_near_radius_blocks = 0, // Always opaque leaves
    .mesh_pool_mb = 10,
    .init_render = 2 * MB,
    .init_audio = 1 * MB,
    .init_game = 1 * MB,
    .init_user = 12 * MB,
    .rt_render = 11 * MB + 768 * KB,
    .rt_audio = 0 * KB,
    .rt_game = 256 * KB,
    .rt_user = 7 * MB,
} else .{
    .total_memory_mb = 80,
    .chunk_radius = 8,
    .lod_near_radius_blocks = 96,
    .mesh_pool_mb = 32,
    .init_render = 8 * MB,
    .init_audio = 2 * MB,
    .init_game = 2 * MB,
    .init_user = 12 * MB,
    .rt_render = 48 * MB,
    .rt_audio = 512 * KB,
    .rt_game = 512 * KB,
    .rt_user = 7 * MB,
};

/// Max chunks that fit within the radius (circular, clamped to 16x16 world).
/// Uses the bounding square (2r+1)^2 as upper bound for array sizing.
pub fn max_sections() u32 {
    const diameter = current.chunk_radius * 2 + 1;
    return diameter * diameter * 4; // * SECTIONS_Y
}

pub fn init_memory() Util.MemoryConfig {
    return .{
        .render = current.init_render,
        .audio = current.init_audio,
        .game = current.init_game,
        .user = current.init_user,
    };
}

pub fn apply_runtime_budgets(engine: *Engine) void {
    engine.set_budget(.render, current.rt_render);
    engine.set_budget(.audio, current.rt_audio);
    engine.set_budget(.game, current.rt_game);
    engine.set_budget(.user, current.rt_user);
}

/// Restore the startup pool layout. Called on entry to MenuState so the next
/// LoadState connect/load has the larger init_user budget back -- after a
/// GameState session the user pool is shrunk to rt_user, which is too tight
/// for the MP connect path's 2 MiB scratch + 4 MiB world allocation.
pub fn apply_init_budgets(engine: *Engine) void {
    engine.set_budget(.render, current.init_render);
    engine.set_budget(.audio, current.init_audio);
    engine.set_budget(.game, current.init_game);
    engine.set_budget(.user, current.init_user);
}
