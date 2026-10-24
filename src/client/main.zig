const std = @import("std");
const ae = @import("aether");
const log = std.log.scoped(.main);

pub const build_options = @import("build_options");
const capabilities = @import("capabilities");
const MenuState = @import("state/MenuState.zig");
const ResourcePack = @import("ResourcePack.zig");
const game_config = @import("config.zig");

const caps = capabilities.ClientType(ae);

pub const aether_options: ae.Options = .{
    .title = "CrossCraft Classic",
    .app_name = caps.resources.app_name,
    .psp = .{
        .module_name = "CrossCraft",
        .stack_size = 512 * 1024,
        .async_stack_size = 64 * 1024,
        .heap_reserve_kb_size = 2048,
    },
};

var menu_state: MenuState = undefined;
var engine: ae.Engine = undefined;

pub fn main(init: std.process.Init) !void {
    game_config.init();

    const memory = try init.gpa.alignedAlloc(u8, .fromByteUnits(16), game_config.main_memory_bytes());
    defer if (!caps.memory.outlives_main) init.gpa.free(memory);

    const state = menu_state.state();
    try engine.init(init.io, init.environ_map, memory, &.{
        .memory = game_config.init_memory(),
        .width = 854,
        .height = 480,
        .title = aether_options.title,
        .app_name = ae.AppOptions.resolve_app_name(aether_options),
        .vsync = true,
        .resizable = true,
    }, &state);
    defer if (!caps.memory.outlives_main) engine.deinit();
    defer if (!caps.memory.outlives_main) ResourcePack.deinit();

    engine.run() catch |err| {
        log.err("game loop failed: {s}", .{@errorName(err)});
        switch (err) {
            error.OutOfMemory => {
                const diag = engine.memory_diagnostics();
                for (diag.pools) |pool| {
                    log.err("  pool {s}: used {d} of {d}, high water {d}, last failed request {?d}", .{ pool.name, pool.used, pool.budget, pool.high_water, pool.last_failed_request });
                }
                log.err("  physical {d} of {d}, largest free run {d}", .{ diag.physical_used, diag.physical_capacity, diag.physical_largest_free_run });
            },
            else => {},
        }
        return err;
    };
}
