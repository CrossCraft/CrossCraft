const std = @import("std");
const ae = @import("aether");
const Util = ae.Util;
const Engine = ae.Engine;
const core = @import("core");

const log = std.log.scoped(.client);

const caps = @import("capabilities").ClientType(ae);
const Profile = @import("capabilities").MemoryProfile;

const MB: u32 = 1024 * 1024;

var active_profile: Profile = caps.memory.initial_profile;

/// Select the runtime capability profile. Must run before any client memory
/// allocation so PSP-1000 stays on the conservative pool layout while PSP
/// 2000+ can use the larger profile in the same binary.
pub fn init() void {
    active_profile = caps.memory.detect_profile();
}

pub fn current() Profile {
    return active_profile;
}

pub fn main_memory_bytes() usize {
    const profile = current();
    return @as(usize, profile.total_memory_mb) * MB;
}

pub fn max_sections() u32 {
    const diameter = caps.memory.max_chunk_radius * 2 + 1;
    // Sections per column in the tallest world the lattice allows
    // (world_dims.max_height / chunk_size = 8). Only loaded columns are ever
    // queued, so this bounds the build queue and visibility list.
    const max_sections_per_column = core.world_dims.max_height / core.world_dims.chunk_size;
    return diameter * diameter * max_sections_per_column;
}

pub fn init_memory() Util.MemoryConfig {
    const profile = current();
    return .{
        .render = profile.init_render,
        .audio = profile.init_audio,
        .game = profile.init_game,
        .frame = 0,
        .user = profile.init_user,
    };
}

const gameplay_user_slack: u32 = 4 * MB;

pub fn gameplay_user_budget(dims: core.world_dims.WorldDims) u32 {
    if (!caps.memory.resize_user_pool_to_world) return 0;
    const world_bytes: u64 = dims.volume() +
        dims.length * dims.depth + // light_map
        4 * dims.chunk_count(); // chunk_counts + chunk_non_opaque (2 x u16)
    return @intCast(world_bytes + gameplay_user_slack);
}

pub fn apply_runtime_budgets(engine: *Engine) void {
    const profile = current();
    set_budget_clamped(engine, .render, profile.rt_render);
    set_budget_clamped(engine, .audio, profile.rt_audio);
    set_budget_clamped(engine, .game, profile.rt_game);
    const want = @max(profile.rt_user, gameplay_user_budget(core.World.data.dims));
    set_budget_clamped(engine, .user, want);
}

/// Restore the startup pool layout.
pub fn apply_init_budgets(engine: *Engine) void {
    const profile = current();
    set_budget_clamped(engine, .render, profile.init_render);
    set_budget_clamped(engine, .audio, profile.init_audio);
    set_budget_clamped(engine, .game, profile.init_game);
    set_budget_clamped(engine, .user, profile.init_user);
}

fn set_budget_clamped(engine: *Engine, pool: Util.Pool, want: u32) void {
    const target = @max(want, engine.pool_used(pool));
    engine.set_budget(pool, target) catch |err|
        log.err("set_budget({s}, {d}) failed after clamp: {}", .{ @tagName(pool), target, err });
}
