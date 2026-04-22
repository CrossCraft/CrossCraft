const std = @import("std");
const c = @import("consts.zig");
const Block = c.Block;
const T = Block.Type;
pub const Face = c.Face;

/// Tile coordinates in the 16x16 terrain atlas grid (col, row).
pub const Tile = packed struct(u16) {
    col: u8,
    row: u8,
};

/// Per-block face textures: top (+Y), bottom (-Y), and four sides.
pub const FaceTiles = struct {
    top: Tile,
    bottom: Tile,
    side: Tile,
};

/// Sound-material classification. Selects which dig/step sound bank a block uses.
/// Mirrors the Classic sound pack: stone / grass / gravel / wood / glass / cloth / sand.
pub const Material = enum(u3) { stone, grass, gravel, wood, glass, cloth, sand };

/// Fluid classification for submersion and interaction checks. `none` for non-fluids.
pub const FluidKind = enum(u2) { none, water, lava };

const Self = @This();

/// Mesher-path flags. Touched in the chunk-meshing hot loop every block per
/// face, so this deliberately fits in a single byte: a full 256-entry table
/// is 256 B, co-resident in a handful of cache lines with the mesher's
/// neighbor bitmasks.
pub const MeshProps = packed struct(u8) {
    @"opaque": bool = false,
    visible: bool = false,
    fluid: bool = false,
    cross: bool = false,
    leaf: bool = false,
    slab: bool = false,
    /// Non-opaque block that culls faces against same-type neighbors (glass).
    glass: bool = false,
    /// Self-lit block whose faces ignore shadow tinting (lava). Read in the
    /// per-face shadow decision; kept here to avoid a second table lookup.
    emits_light: bool = false,
};

/// Simulation / gameplay flags. Cold relative to the mesher; these are read
/// by player input, audio, UI, the server-side tick scheduler, and server
/// heightmap logic -- not the per-face meshing loop.
pub const SimProps = packed struct(u8) {
    solid: bool = false,
    selectable: bool = false,
    breakable: bool = false,
    step_sound: bool = false,
    in_inventory: bool = false,
    /// Sunlight passes through this block (server heightmap / plant updates).
    /// Distinct from !opaque: fluids and slabs are non-opaque but still block
    /// sunlight for heightmap purposes.
    light_passes: bool = false,
    /// Scheduled for per-block update ticks (fluids, vegetation, gravity).
    ticks: bool = false,
    /// Uses the fast 4-tick cadence (fluids + gravity). Otherwise random slow.
    fast_tick: bool = false,
};

/// Classic block-picker grid: 9 columns x 5 rows = 45 slots. Trailing entries
/// are .air padding (see `sim_props[id].in_inventory` for the placeable set).
pub const INVENTORY_SLOTS: u8 = 45;
pub const INVENTORY_FILLED: u8 = 42;

// -- Tables ------------------------------------------------------------------

/// Mesh-path flags indexed by block id. See MeshProps for cache rationale.
mesh_props: [256]MeshProps,
/// Gameplay flags indexed by block id.
sim_props: [256]SimProps,
face_tiles: [256]FaceTiles,
/// Sound material per block id. Drives dig/step sound bank selection.
material: [256]Material,
/// Fluid kind per block id (none for non-fluids).
fluid_kind: [256]FluidKind,
/// Collision AABB top height in sixteenths of a block (0 = passable, 8 = slab, 16 = full).
collision_height_16: [256]u8,
/// Player-facing display name for the block-picker tooltip. Empty string for
/// technical/unnamed ids (air, bedrock, fluids, double_slab, undefined).
display_name: [256][]const u8,
inventory_order: [INVENTORY_SLOTS]T,

/// Global registry instance. `defaults()` is comptime-evaluable so the full
/// table baked into the binary; no init call is required at startup.
pub const global: Self = defaults();

/// Returns the atlas tile for a given block and face direction.
pub fn get_face_tile(self: *const Self, block: Block, face: Face) Tile {
    const ft = self.face_tiles[@intFromEnum(block.id)];
    return switch (face) {
        .y_pos => ft.top,
        .y_neg => ft.bottom,
        .x_neg, .x_pos, .z_neg, .z_pos => ft.side,
    };
}

// -- Helpers ------------------------------------------------------------------

fn all(col: u8, row: u8) FaceTiles {
    const t = Tile{ .col = col, .row = row };
    return .{ .top = t, .bottom = t, .side = t };
}

fn top_side_bot(tc: u8, tr: u8, sc: u8, sr: u8, bc: u8, br: u8) FaceTiles {
    return .{
        .top = .{ .col = tc, .row = tr },
        .bottom = .{ .col = bc, .row = br },
        .side = .{ .col = sc, .row = sr },
    };
}

fn idx(b: T) usize {
    return @intFromEnum(b);
}

// -- Default registration -----------------------------------------------------

fn defaults() Self {
    var self: Self = .{
        .mesh_props = [_]MeshProps{.{}} ** 256,
        .sim_props = [_]SimProps{.{}} ** 256,
        .face_tiles = [_]FaceTiles{all(0, 0)} ** 256,
        .material = [_]Material{.grass} ** 256,
        .fluid_kind = [_]FluidKind{.none} ** 256,
        .collision_height_16 = [_]u8{0} ** 256,
        .display_name = [_][]const u8{""} ** 256,
        .inventory_order = [_]T{.air} ** INVENTORY_SLOTS,
    };

    register_mesh_props(&self);
    register_sim_props(&self);
    register_fluids(&self);
    register_collision(&self);
    register_sound(&self);
    register_face_tiles(&self);
    register_inventory(&self);
    register_display_names(&self);

    return self;
}

fn register_mesh_props(self: *Self) void {
    // Defined ids (1..49) default to opaque + visible; helpers below carve out
    // exceptions.
    for (1..50) |i| {
        self.mesh_props[i] = .{ .@"opaque" = true, .visible = true };
    }

    // Non-opaque (mesher leaves cull on these; they don't occlude neighbors).
    // Slab is half-height: flagged non-opaque so it doesn't cull its own top
    // face or neighbors' hidden halves -- mesher uses the dedicated slab path.
    const non_opaque = [_]T{
        .air,          .sapling,    .flowing_water, .still_water,
        .flowing_lava, .still_lava, .leaves,        .glass,
        .flower_1,     .flower_2,   .mushroom_1,    .mushroom_2,
        .slab,
    };
    for (non_opaque) |b| self.mesh_props[idx(b)].@"opaque" = false;

    const invisible = [_]T{
        .air, .sapling, .flower_1, .flower_2, .mushroom_1, .mushroom_2,
    };
    for (invisible) |b| self.mesh_props[idx(b)].visible = false;

    const cross = [_]T{ .sapling, .flower_1, .flower_2, .mushroom_1, .mushroom_2 };
    for (cross) |b| self.mesh_props[idx(b)].cross = true;

    self.mesh_props[idx(.leaves)].leaf = true;
    self.mesh_props[idx(.slab)].slab = true;
    self.mesh_props[idx(.glass)].glass = true;

    const fluids = [_]T{ .flowing_water, .still_water, .flowing_lava, .still_lava };
    for (fluids) |b| self.mesh_props[idx(b)].fluid = true;

    self.mesh_props[idx(.flowing_lava)].emits_light = true;
    self.mesh_props[idx(.still_lava)].emits_light = true;
}

fn register_sim_props(self: *Self) void {
    // Defined ids (1..49) default to solid / selectable / breakable / step_sound.
    for (1..50) |i| {
        self.sim_props[i] = .{
            .solid = true,
            .selectable = true,
            .breakable = true,
            .step_sound = true,
        };
    }

    const passables = [_]T{
        .sapling,    .flowing_water, .still_water, .flowing_lava,
        .still_lava, .flower_1,      .flower_2,    .mushroom_1,
        .mushroom_2,
    };
    for (passables) |b| self.sim_props[idx(b)].solid = false;

    // Fluids are not selectable for break/place and suppress step sounds.
    const fluids = [_]T{ .flowing_water, .still_water, .flowing_lava, .still_lava };
    for (fluids) |b| {
        self.sim_props[idx(b)].selectable = false;
        self.sim_props[idx(b)].step_sound = false;
    }

    self.sim_props[idx(.bedrock)].breakable = false;

    // Sunlight-transparent blocks (heightmap + plant lifecycle).
    // `air` is zero-initialized, so set it explicitly.
    const sunlight = [_]T{
        .air,      .sapling,  .leaves,     .glass,
        .flower_1, .flower_2, .mushroom_1, .mushroom_2,
    };
    for (sunlight) |b| self.sim_props[idx(b)].light_passes = true;

    // Tick scheduling: blocks with per-tick update behavior.
    const ticked = [_]T{
        .dirt,       .grass,         .sapling,     .flower_1,
        .flower_2,   .mushroom_1,    .mushroom_2,  .sand,
        .gravel,     .flowing_water, .still_water, .flowing_lava,
        .still_lava,
    };
    for (ticked) |b| self.sim_props[idx(b)].ticks = true;

    // Fast cadence (4 ticks): gravity-affected blocks and fluids. Others that
    // tick use the slow random-delay cadence.
    const fast = [_]T{
        .sand, .gravel, .flowing_water, .still_water, .flowing_lava, .still_lava,
    };
    for (fast) |b| self.sim_props[idx(b)].fast_tick = true;
}

fn register_fluids(self: *Self) void {
    const waters = [_]T{ .flowing_water, .still_water };
    const lavas = [_]T{ .flowing_lava, .still_lava };
    for (waters) |b| self.fluid_kind[idx(b)] = .water;
    for (lavas) |b| self.fluid_kind[idx(b)] = .lava;
}

fn register_collision(self: *Self) void {
    // Full-block height for all defined ids, then carve out passables / slab.
    for (1..50) |i| self.collision_height_16[i] = 16;
    const passables = [_]T{
        .sapling,    .flowing_water, .still_water, .flowing_lava,
        .still_lava, .flower_1,      .flower_2,    .mushroom_1,
        .mushroom_2,
    };
    for (passables) |b| self.collision_height_16[idx(b)] = 0;
    self.collision_height_16[idx(.slab)] = 8;
}

fn register_sound(self: *Self) void {
    // Default material is .grass; override specific classes below.
    const stone_blocks = [_]T{
        .stone,    .cobblestone, .bedrock,     .gold_ore, .iron_ore, .coal_ore,
        .gold,     .iron,        .double_slab, .slab,     .brick,    .mossy_rocks,
        .obsidian,
    };
    for (stone_blocks) |b| self.material[idx(b)] = .stone;

    const wood_blocks = [_]T{ .planks, .log, .bookshelf };
    for (wood_blocks) |b| self.material[idx(b)] = .wood;

    const gravel_blocks = [_]T{ .dirt, .gravel };
    for (gravel_blocks) |b| self.material[idx(b)] = .gravel;

    self.material[idx(.sand)] = .sand;
    self.material[idx(.glass)] = .glass;

    const wool_blocks = [_]T{
        .red_wool,         .orange_wool,       .yellow_wool,     .chartreuse_wool,
        .green_wool,       .spring_green_wool, .cyan_wool,       .capri_wool,
        .ultramarine_wool, .purple_wool,       .violet_wool,     .magenta_wool,
        .rose_wool,        .dark_gray_wool,    .light_gray_wool, .white_wool,
    };
    for (wool_blocks) |b| self.material[idx(b)] = .cloth;
}

fn register_face_tiles(self: *Self) void {
    self.face_tiles[idx(.stone)] = all(1, 0);
    self.face_tiles[idx(.grass)] = top_side_bot(0, 0, 3, 0, 2, 0);
    self.face_tiles[idx(.dirt)] = all(2, 0);
    self.face_tiles[idx(.cobblestone)] = all(0, 1);
    self.face_tiles[idx(.planks)] = all(4, 0);
    self.face_tiles[idx(.sapling)] = all(15, 0);
    self.face_tiles[idx(.bedrock)] = all(1, 1);
    self.face_tiles[idx(.flowing_water)] = all(14, 0);
    self.face_tiles[idx(.still_water)] = all(14, 0);
    self.face_tiles[idx(.flowing_lava)] = all(14, 1);
    self.face_tiles[idx(.still_lava)] = all(14, 1);
    self.face_tiles[idx(.sand)] = all(2, 1);
    self.face_tiles[idx(.gravel)] = all(3, 1);
    self.face_tiles[idx(.gold_ore)] = all(0, 2);
    self.face_tiles[idx(.iron_ore)] = all(1, 2);
    self.face_tiles[idx(.coal_ore)] = all(2, 2);
    self.face_tiles[idx(.log)] = top_side_bot(5, 1, 4, 1, 5, 1);
    self.face_tiles[idx(.leaves)] = all(6, 1);
    self.face_tiles[idx(.sponge)] = all(0, 3);
    self.face_tiles[idx(.glass)] = all(1, 3);

    self.face_tiles[idx(.red_wool)] = all(0, 4);
    self.face_tiles[idx(.orange_wool)] = all(1, 4);
    self.face_tiles[idx(.yellow_wool)] = all(2, 4);
    self.face_tiles[idx(.chartreuse_wool)] = all(3, 4);
    self.face_tiles[idx(.green_wool)] = all(4, 4);
    self.face_tiles[idx(.spring_green_wool)] = all(5, 4);
    self.face_tiles[idx(.cyan_wool)] = all(6, 4);
    self.face_tiles[idx(.capri_wool)] = all(7, 4);
    self.face_tiles[idx(.ultramarine_wool)] = all(8, 4);
    self.face_tiles[idx(.purple_wool)] = all(9, 4);
    self.face_tiles[idx(.violet_wool)] = all(10, 4);
    self.face_tiles[idx(.magenta_wool)] = all(11, 4);
    self.face_tiles[idx(.rose_wool)] = all(12, 4);
    self.face_tiles[idx(.dark_gray_wool)] = all(13, 4);
    self.face_tiles[idx(.light_gray_wool)] = all(14, 4);
    self.face_tiles[idx(.white_wool)] = all(15, 4);

    self.face_tiles[idx(.flower_1)] = all(13, 0);
    self.face_tiles[idx(.flower_2)] = all(12, 0);
    self.face_tiles[idx(.mushroom_1)] = all(13, 1);
    self.face_tiles[idx(.mushroom_2)] = all(12, 1);
    self.face_tiles[idx(.iron)] = top_side_bot(7, 1, 7, 2, 7, 1);
    self.face_tiles[idx(.gold)] = top_side_bot(8, 1, 8, 2, 8, 1);
    self.face_tiles[idx(.double_slab)] = top_side_bot(6, 0, 5, 0, 6, 0);
    self.face_tiles[idx(.slab)] = top_side_bot(6, 0, 5, 0, 6, 0);
    self.face_tiles[idx(.brick)] = all(7, 0);
    self.face_tiles[idx(.tnt)] = top_side_bot(9, 0, 8, 0, 10, 0);
    self.face_tiles[idx(.bookshelf)] = top_side_bot(4, 0, 3, 2, 4, 0);
    self.face_tiles[idx(.mossy_rocks)] = all(4, 2);
    self.face_tiles[idx(.obsidian)] = all(5, 2);
}

fn register_inventory(self: *Self) void {
    const grid = [_]T{
        .stone,       .cobblestone,      .brick,           .dirt,              .planks,
        .log,         .leaves,           .glass,           .slab,              .mossy_rocks,
        .sapling,     .flower_1,         .flower_2,        .mushroom_1,        .mushroom_2,
        .sand,        .gravel,           .sponge,          .red_wool,          .orange_wool,
        .yellow_wool, .chartreuse_wool,  .green_wool,      .spring_green_wool, .cyan_wool,
        .capri_wool,  .ultramarine_wool, .purple_wool,     .violet_wool,       .magenta_wool,
        .rose_wool,   .dark_gray_wool,   .light_gray_wool, .white_wool,        .coal_ore,
        .iron_ore,    .gold_ore,         .iron,            .gold,              .bookshelf,
        .tnt,         .obsidian,
    };
    comptime std.debug.assert(grid.len == INVENTORY_FILLED);

    for (grid, 0..) |b, i| {
        self.inventory_order[i] = b;
        self.sim_props[idx(b)].in_inventory = true;
    }
}

fn register_display_names(self: *Self) void {
    const pairs = [_]struct { T, []const u8 }{
        .{ .stone, "Stone" },
        .{ .cobblestone, "Cobblestone" },
        .{ .brick, "Brick" },
        .{ .dirt, "Dirt" },
        .{ .planks, "Wood" },
        .{ .log, "Log" },
        .{ .leaves, "Leaves" },
        .{ .glass, "Glass" },
        .{ .slab, "Slab" },
        .{ .mossy_rocks, "Mossy rocks" },
        .{ .sapling, "Sapling" },
        .{ .flower_1, "Dandelion" },
        .{ .flower_2, "Rose" },
        .{ .mushroom_1, "Brown mushroom" },
        .{ .mushroom_2, "Red mushroom" },
        .{ .sand, "Sand" },
        .{ .gravel, "Gravel" },
        .{ .sponge, "Sponge" },
        .{ .red_wool, "Red Cloth" },
        .{ .orange_wool, "Orange Cloth" },
        .{ .yellow_wool, "Yellow Cloth" },
        .{ .chartreuse_wool, "Chartreuse Cloth" },
        .{ .green_wool, "Green Cloth" },
        .{ .spring_green_wool, "Spring Green Cloth" },
        .{ .cyan_wool, "Cyan Cloth" },
        .{ .capri_wool, "Capri Cloth" },
        .{ .ultramarine_wool, "Ultramarine Cloth" },
        .{ .purple_wool, "Purple Cloth" },
        .{ .violet_wool, "Violet Cloth" },
        .{ .magenta_wool, "Magenta Cloth" },
        .{ .rose_wool, "Rose Cloth" },
        .{ .dark_gray_wool, "Dark Gray Cloth" },
        .{ .light_gray_wool, "Light Gray Cloth" },
        .{ .white_wool, "White Cloth" },
        .{ .coal_ore, "Coal ore" },
        .{ .iron_ore, "Iron ore" },
        .{ .gold_ore, "Gold ore" },
        .{ .iron, "Iron" },
        .{ .gold, "Gold" },
        .{ .bookshelf, "Bookshelf" },
        .{ .tnt, "TNT" },
        .{ .obsidian, "Obsidian" },
    };
    for (pairs) |p| self.display_name[idx(p[0])] = p[1];
}
