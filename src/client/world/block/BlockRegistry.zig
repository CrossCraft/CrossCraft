const std = @import("std");
const c = @import("common").consts;
const Block = c.Block;
const face_mod = @import("../chunk/face.zig");
pub const Face = face_mod.Face;

pub const BitSet = std.StaticBitSet(256);

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

const Self = @This();

pub const Props = packed struct(u8) {
    @"opaque": bool = false,
    visible: bool = false,
    fluid: bool = false,
    cross: bool = false,
    leaf: bool = false,
    slab: bool = false,
    /// Non-opaque block that culls faces against same-type neighbors (glass).
    glass: bool = false,
    _reserved: u1 = 0,
};

@"opaque": BitSet,
visible: BitSet,
cross: BitSet,
leaf: BitSet,
fluid: BitSet,
slab: BitSet,
glass: BitSet,
face_tiles: [256]FaceTiles,
/// Packed per-block properties. One lookup replaces 6 BitSet checks.
props: [256]Props,

/// Global registry instance - call init() before use.
pub var global: Self = undefined;

pub fn init() void {
    global = defaults();
}

/// Returns the atlas tile for a given block and face direction.
pub fn get_face_tile(self: *const Self, block: Block, face: Face) Tile {
    const ft = self.face_tiles[@intFromEnum(block)];
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

// -- Default registration -----------------------------------------------------

fn defaults() Self {
    var self: Self = .{
        .@"opaque" = BitSet.initFull(),
        .visible = BitSet.initFull(),
        .cross = BitSet.initEmpty(),
        .leaf = BitSet.initEmpty(),
        .fluid = BitSet.initEmpty(),
        .slab = BitSet.initEmpty(),
        .glass = BitSet.initEmpty(),
        .face_tiles = [_]FaceTiles{all(0, 0)} ** 256,
        .props = [_]Props{.{}} ** 256,
    };

    // -- Opaque: clear non-opaque blocks --
    self.@"opaque".unset(@intFromEnum(Block.air));
    self.@"opaque".unset(@intFromEnum(Block.sapling));
    self.@"opaque".unset(@intFromEnum(Block.flowing_water));
    self.@"opaque".unset(@intFromEnum(Block.still_water));
    self.@"opaque".unset(@intFromEnum(Block.flowing_lava));
    self.@"opaque".unset(@intFromEnum(Block.still_lava));
    self.@"opaque".unset(@intFromEnum(Block.leaves));
    self.@"opaque".unset(@intFromEnum(Block.glass));
    self.@"opaque".unset(@intFromEnum(Block.flower_1));
    self.@"opaque".unset(@intFromEnum(Block.flower_2));
    self.@"opaque".unset(@intFromEnum(Block.mushroom_1));
    self.@"opaque".unset(@intFromEnum(Block.mushroom_2));
    // Slab is half-height; treating it as opaque would (a) cull neighbors'
    // faces hidden behind the missing top half and (b) cause its own top
    // face to be culled by whatever sits above it. Mark non-opaque and let
    // the dedicated slab path in the mesher handle geometry.
    self.@"opaque".unset(@intFromEnum(Block.slab));
    // Clear undefined block IDs 50-255 as non-opaque
    for (50..256) |i| self.@"opaque".unset(i);

    // -- Slab blocks (half-height geometry) --
    self.slab.set(@intFromEnum(Block.slab));

    // -- Visible: clear invisible blocks --
    self.visible.unset(@intFromEnum(Block.air));
    self.visible.unset(@intFromEnum(Block.sapling));
    self.visible.unset(@intFromEnum(Block.flower_1));
    self.visible.unset(@intFromEnum(Block.flower_2));
    self.visible.unset(@intFromEnum(Block.mushroom_1));
    self.visible.unset(@intFromEnum(Block.mushroom_2));
    // Clear undefined block IDs 50-255 as invisible
    for (50..256) |i| self.visible.unset(i);

    // -- Cross-plant blocks --
    self.cross.set(@intFromEnum(Block.sapling));
    self.cross.set(@intFromEnum(Block.flower_1));
    self.cross.set(@intFromEnum(Block.flower_2));
    self.cross.set(@intFromEnum(Block.mushroom_1));
    self.cross.set(@intFromEnum(Block.mushroom_2));

    // -- Leaf blocks --
    self.leaf.set(@intFromEnum(Block.leaves));

    // -- Fluid blocks --
    self.fluid.set(@intFromEnum(Block.flowing_water));
    self.fluid.set(@intFromEnum(Block.still_water));
    self.fluid.set(@intFromEnum(Block.flowing_lava));
    self.fluid.set(@intFromEnum(Block.still_lava));

    // -- Glass blocks (cull faces against same-type neighbors) --
    self.glass.set(@intFromEnum(Block.glass));

    // -- Face tiles (texture atlas coordinates) --
    self.face_tiles[@intFromEnum(Block.stone)] = all(1, 0);
    self.face_tiles[@intFromEnum(Block.grass)] = top_side_bot(0, 0, 3, 0, 2, 0);
    self.face_tiles[@intFromEnum(Block.dirt)] = all(2, 0);
    self.face_tiles[@intFromEnum(Block.cobblestone)] = all(0, 1);
    self.face_tiles[@intFromEnum(Block.planks)] = all(4, 0);
    self.face_tiles[@intFromEnum(Block.sapling)] = all(15, 0);
    self.face_tiles[@intFromEnum(Block.bedrock)] = all(1, 1);
    self.face_tiles[@intFromEnum(Block.flowing_water)] = all(14, 0);
    self.face_tiles[@intFromEnum(Block.still_water)] = all(14, 0);
    self.face_tiles[@intFromEnum(Block.flowing_lava)] = all(14, 1);
    self.face_tiles[@intFromEnum(Block.still_lava)] = all(14, 1);
    self.face_tiles[@intFromEnum(Block.sand)] = all(2, 1);
    self.face_tiles[@intFromEnum(Block.gravel)] = all(3, 1);
    self.face_tiles[@intFromEnum(Block.gold_ore)] = all(0, 2);
    self.face_tiles[@intFromEnum(Block.iron_ore)] = all(1, 2);
    self.face_tiles[@intFromEnum(Block.coal_ore)] = all(2, 2);
    self.face_tiles[@intFromEnum(Block.log)] = top_side_bot(5, 1, 4, 1, 5, 1);
    self.face_tiles[@intFromEnum(Block.leaves)] = all(6, 1);
    self.face_tiles[@intFromEnum(Block.sponge)] = all(0, 3);
    self.face_tiles[@intFromEnum(Block.glass)] = all(1, 3);

    // Wool colors
    self.face_tiles[@intFromEnum(Block.red_wool)] = all(0, 4);
    self.face_tiles[@intFromEnum(Block.orange_wool)] = all(1, 4);
    self.face_tiles[@intFromEnum(Block.yellow_wool)] = all(2, 4);
    self.face_tiles[@intFromEnum(Block.chartreuse_wool)] = all(3, 4);
    self.face_tiles[@intFromEnum(Block.green_wool)] = all(4, 4);
    self.face_tiles[@intFromEnum(Block.spring_green_wool)] = all(5, 4);
    self.face_tiles[@intFromEnum(Block.cyan_wool)] = all(6, 4);
    self.face_tiles[@intFromEnum(Block.capri_wool)] = all(7, 4);
    self.face_tiles[@intFromEnum(Block.ultramarine_wool)] = all(8, 4);
    self.face_tiles[@intFromEnum(Block.purple_wool)] = all(9, 4);
    self.face_tiles[@intFromEnum(Block.violet_wool)] = all(10, 4);
    self.face_tiles[@intFromEnum(Block.magenta_wool)] = all(11, 4);
    self.face_tiles[@intFromEnum(Block.rose_wool)] = all(12, 4);
    self.face_tiles[@intFromEnum(Block.dark_gray_wool)] = all(13, 4);
    self.face_tiles[@intFromEnum(Block.light_gray_wool)] = all(14, 4);
    self.face_tiles[@intFromEnum(Block.white_wool)] = all(15, 4);

    self.face_tiles[@intFromEnum(Block.flower_1)] = all(13, 0);
    self.face_tiles[@intFromEnum(Block.flower_2)] = all(12, 0);
    self.face_tiles[@intFromEnum(Block.mushroom_1)] = all(13, 1);
    self.face_tiles[@intFromEnum(Block.mushroom_2)] = all(12, 1);
    self.face_tiles[@intFromEnum(Block.iron)] = top_side_bot(7, 1, 7, 2, 7, 1);
    self.face_tiles[@intFromEnum(Block.gold)] = top_side_bot(8, 1, 8, 2, 8, 1);
    self.face_tiles[@intFromEnum(Block.double_slab)] = top_side_bot(6, 0, 5, 0, 6, 0);
    self.face_tiles[@intFromEnum(Block.slab)] = top_side_bot(6, 0, 5, 0, 6, 0);
    self.face_tiles[@intFromEnum(Block.brick)] = all(7, 0);
    self.face_tiles[@intFromEnum(Block.tnt)] = top_side_bot(9, 0, 8, 0, 10, 0);
    self.face_tiles[@intFromEnum(Block.bookshelf)] = top_side_bot(4, 0, 3, 2, 4, 0);
    self.face_tiles[@intFromEnum(Block.mossy_rocks)] = all(4, 2);
    self.face_tiles[@intFromEnum(Block.obsidian)] = all(5, 2);

    // Pack all BitSet properties into a single byte per block.
    for (0..256) |i| {
        self.props[i] = .{
            .@"opaque" = self.@"opaque".isSet(i),
            .visible = self.visible.isSet(i),
            .fluid = self.fluid.isSet(i),
            .cross = self.cross.isSet(i),
            .leaf = self.leaf.isSet(i),
            .slab = self.slab.isSet(i),
            .glass = self.glass.isSet(i),
        };
    }

    return self;
}
