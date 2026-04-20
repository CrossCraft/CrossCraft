// Display names for blocks shown in the Classic block-picker tooltip.
// Returns an empty slice for ids without a player-facing name (Air, Bedrock,
// fluids, the technical Double_Slab, undefined ids 50..255). Display-only;
// belongs in client UI rather than `common`, which stays graphics-free.

const c = @import("common").consts;
const Block = c.Block;

pub fn get(block: Block) []const u8 {
    return switch (block) {
        .stone => "Stone",
        .cobblestone => "Cobblestone",
        .brick => "Brick",
        .dirt => "Dirt",
        .planks => "Wood",
        .log => "Log",
        .leaves => "Leaves",
        .glass => "Glass",
        .slab => "Slab",
        .mossy_rocks => "Mossy rocks",
        .sapling => "Sapling",
        .flower_1 => "Dandelion",
        .flower_2 => "Rose",
        .mushroom_1 => "Brown mushroom",
        .mushroom_2 => "Red mushroom",
        .sand => "Sand",
        .gravel => "Gravel",
        .sponge => "Sponge",
        .red_wool => "Red Cloth",
        .orange_wool => "Orange Cloth",
        .yellow_wool => "Yellow Cloth",
        .chartreuse_wool => "Chartreuse Cloth",
        .green_wool => "Green Cloth",
        .spring_green_wool => "Spring Green Cloth",
        .cyan_wool => "Cyan Cloth",
        .capri_wool => "Capri Cloth",
        .ultramarine_wool => "Ultramarine Cloth",
        .purple_wool => "Purple Cloth",
        .violet_wool => "Violet Cloth",
        .magenta_wool => "Magenta Cloth",
        .rose_wool => "Rose Cloth",
        .dark_gray_wool => "Dark Gray Cloth",
        .light_gray_wool => "Light Gray Cloth",
        .white_wool => "White Cloth",
        .coal_ore => "Coal ore",
        .iron_ore => "Iron ore",
        .gold_ore => "Gold ore",
        .iron => "Iron",
        .gold => "Gold",
        .bookshelf => "Bookshelf",
        .tnt => "TNT",
        .obsidian => "Obsidian",
        else => "",
    };
}
