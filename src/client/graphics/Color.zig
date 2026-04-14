pub const Color = packed struct(u32) {
    r: u8,
    g: u8,
    b: u8,
    a: u8,

    pub fn rgba(r: u8, g: u8, b: u8, a: u8) Color {
        return .{ .r = r, .g = g, .b = b, .a = a };
    }

    pub const none = rgba(0, 0, 0, 0);
    pub const gold = rgba(255, 170, 0, 255);

    // Minecraft Classic chat color palette (foreground / background pairs),
    // indexed by the '&' code (&0..&f). Names use the "alternate" (HTML-style)
    // naming.
    pub const black_fg = rgba(0, 0, 0, 255);
    pub const black_bg = rgba(0, 0, 0, 255);
    pub const navy_fg = rgba(0, 0, 170, 255);
    pub const navy_bg = rgba(0, 0, 42, 255);
    pub const green_fg = rgba(0, 170, 0, 255);
    pub const green_bg = rgba(0, 42, 0, 255);
    pub const teal_fg = rgba(0, 170, 170, 255);
    pub const teal_bg = rgba(0, 42, 42, 255);
    pub const maroon_fg = rgba(170, 0, 0, 255);
    pub const maroon_bg = rgba(42, 0, 0, 255);
    pub const purple_fg = rgba(170, 0, 170, 255);
    pub const purple_bg = rgba(42, 0, 42, 255);
    pub const gold_fg = rgba(170, 170, 0, 255);
    pub const gold_bg = rgba(42, 42, 0, 255);
    pub const silver_fg = rgba(170, 170, 170, 255);
    pub const silver_bg = rgba(42, 42, 42, 255);
    pub const gray_fg = rgba(85, 85, 85, 255);
    pub const gray_bg = rgba(21, 21, 21, 255);
    pub const blue_fg = rgba(85, 85, 255, 255);
    pub const blue_bg = rgba(21, 21, 63, 255);
    pub const lime_fg = rgba(85, 255, 85, 255);
    pub const lime_bg = rgba(21, 63, 21, 255);
    pub const aqua_fg = rgba(85, 255, 255, 255);
    pub const aqua_bg = rgba(21, 63, 63, 255);
    pub const red_fg = rgba(255, 85, 85, 255);
    pub const red_bg = rgba(63, 21, 21, 255);
    pub const pink_fg = rgba(255, 85, 255, 255);
    pub const pink_bg = rgba(63, 21, 63, 255);
    pub const yellow_fg = rgba(255, 255, 85, 255);
    pub const yellow_bg = rgba(63, 63, 21, 255);
    pub const white_fg = rgba(255, 255, 255, 255);
    pub const white_bg = rgba(63, 63, 63, 255);

    pub const be_mtx_gold = rgba(221, 214, 5, 255);
    pub const select_front = rgba(255, 255, 160, 255);
    pub const select_back = rgba(63, 63, 40, 255);
    pub const splash_front = rgba(255, 255, 0, 255);
    pub const splash_back = rgba(62, 62, 0, 255);
    pub const menu_version = rgba(22, 22, 21, 255);
    pub const menu_copyright = rgba(62, 62, 62, 255);
    pub const menu_tiles = rgba(70, 70, 70, 255);
    pub const menu_gray = rgba(50, 50, 50, 255);
    pub const progress_bar = rgba(0x80, 0xFF, 0x80, 0xFF);
    pub const progress_bg = rgba(0x80, 0x80, 0x80, 0xFF);
    pub const game_daytime = rgba(191, 216, 255, 255);
    pub const game_daytime_zenith = rgba(119, 167, 255, 255);
    pub const game_underwater = rgba(5, 5, 21, 255);
    pub const game_underlava = rgba(153, 25, 0, 255);
};

comptime {
    @import("std").debug.assert(@sizeOf(Color) == 4);
}
