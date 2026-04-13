const builtin = @import("builtin");

pub const MAX_PLAYERS = if (builtin.os.tag == .psp) 4 else 128;

pub const WorldLength = 256;
pub const WorldHeight = 64;
pub const WorldDepth = 256;

pub const Message = [64]u8;

pub const Water_Level = 32;

pub const Location = packed struct(u32) {
    x: u8,
    z: u8,
    y: u8,
    _reserved: u8 = 0,

    pub fn to_index(self: Location) u32 {
        return (@as(u32, self.y) * WorldDepth + @as(u32, self.z)) * WorldLength + self.x;
    }
};

/// Axis-aligned bounding box within a voxel, expressed on a 16x16x16 subgrid.
/// Each coordinate ranges from 0 to 16 (one block = 16 subvoxels per axis).
pub const SubvoxelBounds = struct {
    min_x: u5,
    min_y: u5,
    min_z: u5,
    max_x: u5,
    max_y: u5,
    max_z: u5,

    pub const full: SubvoxelBounds = .{ .min_x = 0, .min_y = 0, .min_z = 0, .max_x = 16, .max_y = 16, .max_z = 16 };
    pub const slab: SubvoxelBounds = .{ .min_x = 0, .min_y = 0, .min_z = 0, .max_x = 16, .max_y = 8, .max_z = 16 };
    pub const dandelion: SubvoxelBounds = .{ .min_x = 6, .min_y = 0, .min_z = 6, .max_x = 10, .max_y = 8, .max_z = 10 };
    pub const rose: SubvoxelBounds = .{ .min_x = 6, .min_y = 0, .min_z = 6, .max_x = 10, .max_y = 12, .max_z = 10 };
    pub const mushroom: SubvoxelBounds = .{ .min_x = 5, .min_y = 0, .min_z = 5, .max_x = 11, .max_y = 6, .max_z = 11 };
    pub const sapling: SubvoxelBounds = .{ .min_x = 2, .min_y = 0, .min_z = 2, .max_x = 14, .max_y = 16, .max_z = 14 };

    pub fn is_full(self: SubvoxelBounds) bool {
        return self.min_x == 0 and self.min_y == 0 and self.min_z == 0 and
            self.max_x == 16 and self.max_y == 16 and self.max_z == 16;
    }
};

pub fn block_bounds(id: u8) SubvoxelBounds {
    return switch (id) {
        Block.Slab => SubvoxelBounds.slab,
        Block.Flower1 => SubvoxelBounds.dandelion,
        Block.Flower2 => SubvoxelBounds.rose,
        Block.Sapling => SubvoxelBounds.sapling,
        Block.Mushroom1, Block.Mushroom2 => SubvoxelBounds.mushroom,
        else => SubvoxelBounds.full,
    };
}

pub const Block = struct {
    pub const Air = 0;
    pub const Stone = 1;
    pub const Grass = 2;
    pub const Dirt = 3;
    pub const Cobblestone = 4;
    pub const Planks = 5;
    pub const Sapling = 6;
    pub const Bedrock = 7;
    pub const Flowing_Water = 8;
    pub const Still_Water = 9;
    pub const Flowing_Lava = 10;
    pub const Still_Lava = 11;
    pub const Sand = 12;
    pub const Gravel = 13;
    pub const Gold_Ore = 14;
    pub const Iron_Ore = 15;
    pub const Coal_Ore = 16;
    pub const Log = 17;
    pub const Leaves = 18;
    pub const Sponge = 19;
    pub const Glass = 20;
    pub const Red_Wool = 21;
    pub const Orange_Wool = 22;
    pub const Yellow_Wool = 23;
    pub const Chartreuse_Wool = 24;
    pub const Green_Wool = 25;
    pub const Spring_Green_Wool = 26;
    pub const Cyan_Wool = 27;
    pub const Capri_Wool = 28;
    pub const Ultramarine_Wool = 29;
    pub const Purple_Wool = 30;
    pub const Violet_Wool = 31;
    pub const Magenta_Wool = 32;
    pub const Rose_Wool = 33;
    pub const Dark_Gray_Wool = 34;
    pub const Light_Gray_Wool = 35;
    pub const White_Wool = 36;
    pub const Flower1 = 37;
    pub const Flower2 = 38;
    pub const Mushroom1 = 39;
    pub const Mushroom2 = 40;
    pub const Gold = 41;
    pub const Iron = 42;
    pub const Double_Slab = 43;
    pub const Slab = 44;
    pub const Brick = 45;
    pub const TNT = 46;
    pub const Bookshelf = 47;
    pub const Mossy_Rocks = 48;
    pub const Obsidian = 49;
};
