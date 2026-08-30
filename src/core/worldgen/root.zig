const std = @import("std");
const assert = std.debug.assert;

pub const level = @import("level.zig");
pub const Random = @import("random.zig");
pub const noise = @import("noise.zig");
pub const terrain = @import("terrain.zig");
pub const carve = @import("carve.zig");
pub const ore = @import("ore.zig");

/// `allocator` owns the returned level's block buffer (long-lived -- callers
/// adopt it as world storage); `scratch` backs the generator's transient
/// workspace (elevation cache, flood queues) and is fully released on return.
pub fn generate(
    allocator: std.mem.Allocator,
    scratch: std.mem.Allocator,
    seed: i64,
    dimensions: level.world_dimensions,
) std.mem.Allocator.Error!level {
    assert(dimensions.validate());

    var generated_level: level = .{
        .seed = seed,
        .random = .init(seed),
        .level_random = .init(seed),
        .dimensions = dimensions,
        .blocks = try allocator.alloc(u8, dimensions.volume()),
    };
    errdefer allocator.free(generated_level.blocks);

    try generated_level.generate(scratch);

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
