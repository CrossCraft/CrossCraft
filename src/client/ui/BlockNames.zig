// Display names for blocks shown in the Classic block-picker tooltip.
// Returns an empty slice for ids without a player-facing name (Air, Bedrock,
// fluids, the technical Double_Slab, undefined ids 50..255). Display-only;
// belongs in client UI rather than `common`, which stays graphics-free.

const c = @import("common").consts;
const B = c.Block;

pub fn get(block: u8) []const u8 {
    return switch (block) {
        B.Stone => "Stone",
        B.Cobblestone => "Cobblestone",
        B.Brick => "Brick",
        B.Dirt => "Dirt",
        B.Planks => "Wood",
        B.Log => "Log",
        B.Leaves => "Leaves",
        B.Glass => "Glass",
        B.Slab => "Slab",
        B.Mossy_Rocks => "Mossy rocks",
        B.Sapling => "Sapling",
        B.Flower1 => "Dandelion",
        B.Flower2 => "Rose",
        B.Mushroom1 => "Brown mushroom",
        B.Mushroom2 => "Red mushroom",
        B.Sand => "Sand",
        B.Gravel => "Gravel",
        B.Sponge => "Sponge",
        B.Red_Wool => "Red Cloth",
        B.Orange_Wool => "Orange Cloth",
        B.Yellow_Wool => "Yellow Cloth",
        B.Chartreuse_Wool => "Chartreuse Cloth",
        B.Green_Wool => "Green Cloth",
        B.Spring_Green_Wool => "Spring Green Cloth",
        B.Cyan_Wool => "Cyan Cloth",
        B.Capri_Wool => "Capri Cloth",
        B.Ultramarine_Wool => "Ultramarine Cloth",
        B.Purple_Wool => "Purple Cloth",
        B.Violet_Wool => "Violet Cloth",
        B.Magenta_Wool => "Magenta Cloth",
        B.Rose_Wool => "Rose Cloth",
        B.Dark_Gray_Wool => "Dark Gray Cloth",
        B.Light_Gray_Wool => "Light Gray Cloth",
        B.White_Wool => "White Cloth",
        B.Coal_Ore => "Coal ore",
        B.Iron_Ore => "Iron ore",
        B.Gold_Ore => "Gold ore",
        B.Iron => "Iron",
        B.Gold => "Gold",
        B.Bookshelf => "Bookshelf",
        B.TNT => "TNT",
        B.Obsidian => "Obsidian",
        else => "",
    };
}
