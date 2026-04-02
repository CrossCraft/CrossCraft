const c = @import("common").consts;
const B = c.Block;
const face_mod = @import("face.zig");
pub const Face = face_mod.Face;

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

// -- Block property LUTs (comptime, indexed by block ID 0-49) ----------

pub const opaque_lut: [50]bool = blk: {
    var t: [50]bool = @splat(true);
    // Non-opaque blocks:
    t[B.Air] = false;
    t[B.Sapling] = false;
    t[B.Flowing_Water] = false;
    t[B.Still_Water] = false;
    t[B.Flowing_Lava] = false;
    t[B.Still_Lava] = false;
    t[B.Leaves] = false;
    t[B.Glass] = false;
    t[B.Flower1] = false;
    t[B.Flower2] = false;
    t[B.Mushroom1] = false;
    t[B.Mushroom2] = false;
    break :blk t;
};

pub const visible_lut: [50]bool = blk: {
    var t: [50]bool = @splat(true);
    t[B.Air] = false;
    // Cross-plants don't emit cube faces (they get X-planes instead)
    t[B.Sapling] = false;
    t[B.Flower1] = false;
    t[B.Flower2] = false;
    t[B.Mushroom1] = false;
    t[B.Mushroom2] = false;
    break :blk t;
};

/// Cross-plant blocks: rendered as two intersecting diagonal planes.
pub const cross_lut: [50]bool = blk: {
    var t: [50]bool = @splat(false);
    t[B.Sapling] = true;
    t[B.Flower1] = true;
    t[B.Flower2] = true;
    t[B.Mushroom1] = true;
    t[B.Mushroom2] = true;
    break :blk t;
};

/// Leaf blocks: LOD suppresses internal leaf-leaf faces at distance.
pub const leaf_lut: [50]bool = blk: {
    var t: [50]bool = @splat(false);
    t[B.Leaves] = true;
    break :blk t;
};

/// Fluid blocks: suppress internal faces between same-type fluids.
pub const fluid_lut: [50]bool = blk: {
    var t: [50]bool = @splat(false);
    t[B.Flowing_Water] = true;
    t[B.Still_Water] = true;
    t[B.Flowing_Lava] = true;
    t[B.Still_Lava] = true;
    break :blk t;
};

/// Terrain.png atlas tile positions per block type.
/// Standard Minecraft Classic 16x16 terrain atlas layout.
pub const face_tiles: [50]FaceTiles = blk: {
    var t: [50]FaceTiles = @splat(all(0, 0));

    t[B.Stone] = all(1, 0);
    t[B.Grass] = top_side_bot(0, 0, 3, 0, 2, 0);
    t[B.Dirt] = all(2, 0);
    t[B.Cobblestone] = all(0, 1);
    t[B.Planks] = all(4, 0);
    t[B.Sapling] = all(15, 0);
    t[B.Bedrock] = all(1, 1);
    t[B.Flowing_Water] = all(14, 0);
    t[B.Still_Water] = all(14, 0);
    t[B.Flowing_Lava] = all(14, 1);
    t[B.Still_Lava] = all(14, 1);
    t[B.Sand] = all(2, 1);
    t[B.Gravel] = all(3, 1);
    t[B.Gold_Ore] = all(0, 2);
    t[B.Iron_Ore] = all(1, 2);
    t[B.Coal_Ore] = all(2, 2);
    t[B.Log] = top_side_bot(5, 1, 4, 1, 5, 1);
    t[B.Leaves] = all(4, 3);
    t[B.Sponge] = all(0, 3);
    t[B.Glass] = all(1, 3);

    // Wool colors -- row 4, columns 0-15
    t[B.White_Wool] = all(0, 4);
    t[B.Orange_Wool] = all(1, 4);
    t[B.Magenta_Wool] = all(2, 4);
    t[B.Light_Blue_Wool] = all(3, 4);
    t[B.Yellow_Wool] = all(4, 4);
    t[B.Lime_Wool] = all(5, 4);
    t[B.Pink_Wool] = all(6, 4);
    t[B.Gray_Wool] = all(7, 4);
    t[B.Light_Gray_Wool] = all(8, 4);
    t[B.Cyan_Wool] = all(9, 4);
    t[B.Purple_Wool] = all(10, 4);
    t[B.Blue_Wool] = all(11, 4);
    t[B.Brown_Wool] = all(12, 4);
    t[B.Green_Wool] = all(13, 4);
    t[B.Red_Wool] = all(14, 4);
    t[B.Black_Wool] = all(15, 4);

    t[B.Flower1] = all(13, 0);
    t[B.Flower2] = all(12, 0);
    t[B.Mushroom1] = all(13, 1);
    t[B.Mushroom2] = all(12, 1);
    t[B.Gold] = all(7, 1);
    t[B.Iron] = all(6, 1);
    t[B.Double_Slab] = top_side_bot(6, 0, 5, 0, 6, 0);
    t[B.Slab] = top_side_bot(6, 0, 5, 0, 6, 0);
    t[B.Brick] = all(7, 0);
    t[B.TNT] = top_side_bot(9, 0, 8, 0, 10, 0);
    t[B.Bookshelf] = top_side_bot(4, 0, 4, 0, 3, 2);
    t[B.Mossy_Rocks] = all(4, 2);
    t[B.Obsidian] = all(5, 2);

    break :blk t;
};

/// Returns the atlas tile for a given block and face direction.
pub fn get_face_tile(block: u8, face: Face) Tile {
    const ft = if (block < 50) face_tiles[block] else face_tiles[0];
    return switch (face) {
        .y_pos => ft.top,
        .y_neg => ft.bottom,
        .x_neg, .x_pos, .z_neg, .z_pos => ft.side,
    };
}
