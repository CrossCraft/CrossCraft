const std = @import("std");
const c = @import("common").consts;
const B = c.Block;
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
    _reserved: u2 = 0,
};

@"opaque": BitSet,
visible: BitSet,
cross: BitSet,
leaf: BitSet,
fluid: BitSet,
slab: BitSet,
face_tiles: [256]FaceTiles,
/// Packed per-block properties. One lookup replaces 6 BitSet checks.
props: [256]Props,

/// Global registry instance - call init() before use.
pub var global: Self = undefined;

pub fn init() void {
    global = defaults();
}

/// Returns the atlas tile for a given block and face direction.
pub fn get_face_tile(self: *const Self, block: u8, face: Face) Tile {
    const ft = self.face_tiles[block];
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
        .face_tiles = [_]FaceTiles{all(0, 0)} ** 256,
        .props = [_]Props{.{}} ** 256,
    };

    // -- Opaque: clear non-opaque blocks --
    self.@"opaque".unset(B.Air);
    self.@"opaque".unset(B.Sapling);
    self.@"opaque".unset(B.Flowing_Water);
    self.@"opaque".unset(B.Still_Water);
    self.@"opaque".unset(B.Flowing_Lava);
    self.@"opaque".unset(B.Still_Lava);
    self.@"opaque".unset(B.Leaves);
    self.@"opaque".unset(B.Glass);
    self.@"opaque".unset(B.Flower1);
    self.@"opaque".unset(B.Flower2);
    self.@"opaque".unset(B.Mushroom1);
    self.@"opaque".unset(B.Mushroom2);
    // Slab is half-height; treating it as opaque would (a) cull neighbors'
    // faces hidden behind the missing top half and (b) cause its own top
    // face to be culled by whatever sits above it. Mark non-opaque and let
    // the dedicated slab path in the mesher handle geometry.
    self.@"opaque".unset(B.Slab);
    // Clear undefined block IDs 50-255 as non-opaque
    for (50..256) |i| self.@"opaque".unset(i);

    // -- Slab blocks (half-height geometry) --
    self.slab.set(B.Slab);

    // -- Visible: clear invisible blocks --
    self.visible.unset(B.Air);
    self.visible.unset(B.Sapling);
    self.visible.unset(B.Flower1);
    self.visible.unset(B.Flower2);
    self.visible.unset(B.Mushroom1);
    self.visible.unset(B.Mushroom2);
    // Clear undefined block IDs 50-255 as invisible
    for (50..256) |i| self.visible.unset(i);

    // -- Cross-plant blocks --
    self.cross.set(B.Sapling);
    self.cross.set(B.Flower1);
    self.cross.set(B.Flower2);
    self.cross.set(B.Mushroom1);
    self.cross.set(B.Mushroom2);

    // -- Leaf blocks --
    self.leaf.set(B.Leaves);

    // -- Fluid blocks --
    self.fluid.set(B.Flowing_Water);
    self.fluid.set(B.Still_Water);
    self.fluid.set(B.Flowing_Lava);
    self.fluid.set(B.Still_Lava);

    // -- Face tiles (texture atlas coordinates) --
    self.face_tiles[B.Stone] = all(1, 0);
    self.face_tiles[B.Grass] = top_side_bot(0, 0, 3, 0, 2, 0);
    self.face_tiles[B.Dirt] = all(2, 0);
    self.face_tiles[B.Cobblestone] = all(0, 1);
    self.face_tiles[B.Planks] = all(4, 0);
    self.face_tiles[B.Sapling] = all(15, 0);
    self.face_tiles[B.Bedrock] = all(1, 1);
    self.face_tiles[B.Flowing_Water] = all(14, 0);
    self.face_tiles[B.Still_Water] = all(14, 0);
    self.face_tiles[B.Flowing_Lava] = all(14, 1);
    self.face_tiles[B.Still_Lava] = all(14, 1);
    self.face_tiles[B.Sand] = all(2, 1);
    self.face_tiles[B.Gravel] = all(3, 1);
    self.face_tiles[B.Gold_Ore] = all(0, 2);
    self.face_tiles[B.Iron_Ore] = all(1, 2);
    self.face_tiles[B.Coal_Ore] = all(2, 2);
    self.face_tiles[B.Log] = top_side_bot(5, 1, 4, 1, 5, 1);
    self.face_tiles[B.Leaves] = all(6, 1);
    self.face_tiles[B.Sponge] = all(0, 3);
    self.face_tiles[B.Glass] = all(1, 3);

    // Wool colors
    self.face_tiles[B.Red_Wool] = all(0, 4);
    self.face_tiles[B.Orange_Wool] = all(1, 4);
    self.face_tiles[B.Yellow_Wool] = all(2, 4);
    self.face_tiles[B.Chartreuse_Wool] = all(3, 4);
    self.face_tiles[B.Green_Wool] = all(4, 4);
    self.face_tiles[B.Spring_Green_Wool] = all(5, 4);
    self.face_tiles[B.Cyan_Wool] = all(6, 4);
    self.face_tiles[B.Capri_Wool] = all(7, 4);
    self.face_tiles[B.Ultramarine_Wool] = all(8, 4);
    self.face_tiles[B.Purple_Wool] = all(9, 4);
    self.face_tiles[B.Violet_Wool] = all(10, 4);
    self.face_tiles[B.Magenta_Wool] = all(11, 4);
    self.face_tiles[B.Rose_Wool] = all(12, 4);
    self.face_tiles[B.Dark_Gray_Wool] = all(13, 4);
    self.face_tiles[B.Light_Gray_Wool] = all(14, 4);
    self.face_tiles[B.White_Wool] = all(15, 4);

    self.face_tiles[B.Flower1] = all(13, 0);
    self.face_tiles[B.Flower2] = all(12, 0);
    self.face_tiles[B.Mushroom1] = all(13, 1);
    self.face_tiles[B.Mushroom2] = all(12, 1);
    self.face_tiles[B.Iron] = top_side_bot(7, 1, 7, 2, 7, 1);
    self.face_tiles[B.Gold] = top_side_bot(8, 1, 8, 2, 8, 1);
    self.face_tiles[B.Double_Slab] = top_side_bot(6, 0, 5, 0, 6, 0);
    self.face_tiles[B.Slab] = top_side_bot(6, 0, 5, 0, 6, 0);
    self.face_tiles[B.Brick] = all(7, 0);
    self.face_tiles[B.TNT] = top_side_bot(9, 0, 8, 0, 10, 0);
    self.face_tiles[B.Bookshelf] = top_side_bot(4, 0, 3, 2, 4, 0);
    self.face_tiles[B.Mossy_Rocks] = all(4, 2);
    self.face_tiles[B.Obsidian] = all(5, 2);

    // Pack all BitSet properties into a single byte per block.
    for (0..256) |i| {
        self.props[i] = .{
            .@"opaque" = self.@"opaque".isSet(i),
            .visible = self.visible.isSet(i),
            .fluid = self.fluid.isSet(i),
            .cross = self.cross.isSet(i),
            .leaf = self.leaf.isSet(i),
            .slab = self.slab.isSet(i),
        };
    }

    return self;
}
