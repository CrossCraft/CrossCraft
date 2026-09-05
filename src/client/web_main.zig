const std = @import("std");
const ae = @import("aether");

const client_main = @import("main.zig");
const game_config = @import("config.zig");
const MenuState = @import("state/MenuState.zig");
const ResourcePack = @import("ResourcePack.zig");

pub const aether_options = client_main.aether_options;
pub const std_options = aether_options.std_options;
pub const std_options_debug_threaded_io = std.Io.Threaded.global_single_threaded;
pub const std_options_debug_io: std.Io = std.Io.Threaded.global_single_threaded.io();

const gpa = std.heap.wasm_allocator;

var env_map: std.process.Environ.Map = undefined;
var env_map_initialized: bool = false;
var memory: []align(16) u8 = &.{};
var menu_state: MenuState = undefined;
var engine: ae.Engine = undefined;
var initialized: bool = false;

export fn aether_wasm_init(width: u32, height: u32) bool {
    if (initialized) return true;

    game_config.init();
    env_map = std.process.Environ.Map.init(gpa);
    env_map_initialized = true;

    memory = gpa.alignedAlloc(u8, .fromByteUnits(16), game_config.main_memory_bytes()) catch {
        env_map.deinit();
        env_map_initialized = false;
        return false;
    };

    const state = menu_state.state();
    engine.init(std.Io.Threaded.global_single_threaded.io(), &env_map, memory, &.{
        .memory = game_config.init_memory(),
        .width = width,
        .height = height,
        .title = aether_options.title,
        .app_name = ae.AppOptions.resolve_app_name(aether_options),
        .vsync = true,
        .resizable = true,
    }, &state) catch {
        gpa.free(memory);
        memory = &.{};
        env_map.deinit();
        env_map_initialized = false;
        return false;
    };
    engine.begin_run();
    initialized = true;
    return true;
}

export fn aether_wasm_frame() bool {
    if (!initialized) return false;
    return engine.step_frame() catch false;
}

export fn aether_wasm_deinit() void {
    if (!initialized) return;
    initialized = false;
    ResourcePack.deinit();
    engine.deinit();
    gpa.free(memory);
    memory = &.{};
    if (env_map_initialized) {
        env_map.deinit();
        env_map_initialized = false;
    }
}

export fn aether_wasm_alloc(len: usize) ?[*]u8 {
    const buf = gpa.alloc(u8, len) catch return null;
    return buf.ptr;
}

export fn aether_wasm_free(ptr: [*]u8, len: usize) void {
    gpa.free(ptr[0..len]);
}
