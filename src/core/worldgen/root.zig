const std = @import("std");
const assert = std.debug.assert;

pub const level = @import("level.zig");
pub const generation_phase = level.generation_phase;
const Random = @import("random.zig");
const noise = @import("noise.zig");
const terrain = @import("terrain.zig");
const carve = @import("carve.zig");
const ore = @import("ore.zig");

/// `allocator` owns the returned level's block buffer (long-lived -- callers
/// adopt it as world storage); `scratch` backs the generator's transient
/// workspace (elevation cache, flood queues) and is fully released on return.
pub fn generate(
    allocator: std.mem.Allocator,
    scratch: std.mem.Allocator,
    seed: i64,
    dimensions: level.world_dimensions,
    on_phase: ?*const fn (generation_phase) void,
) std.mem.Allocator.Error!level {
    assert(dimensions.validate());

    var generated_level: level = .{
        .blocks = try allocator.alloc(u8, dimensions.volume()),
    };
    errdefer allocator.free(generated_level.blocks);

    try generated_level.generate(scratch, seed, dimensions, on_phase);

    return generated_level;
}

test {
    _ = Random;
    _ = noise;
    _ = terrain;
    _ = carve;
    _ = ore;
    _ = level;
}
