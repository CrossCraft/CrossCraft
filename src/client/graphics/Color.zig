pub const Color = packed struct(u32) {
    r: u8,
    g: u8,
    b: u8,
    a: u8,

    pub fn rgba(r: u8, g: u8, b: u8, a: u8) Color {
        return .{ .r = r, .g = g, .b = b, .a = a };
    }

    pub const none = rgba(0, 0, 0, 0);
    pub const black = rgba(0, 0, 0, 255);
    pub const dark_blue = rgba(0, 0, 170, 255);
    pub const dark_green = rgba(0, 170, 0, 255);
    pub const dark_aqua = rgba(0, 170, 170, 255);
    pub const dark_red = rgba(170, 0, 0, 255);
    pub const dark_purple = rgba(170, 0, 170, 255);
    pub const gold = rgba(255, 170, 0, 255);
    pub const light_gray = rgba(170, 170, 170, 255);
    pub const dark_gray = rgba(85, 85, 85, 255);
    pub const blue = rgba(85, 85, 255, 255);
    pub const green = rgba(85, 255, 85, 255);
    pub const aqua = rgba(85, 255, 255, 255);
    pub const red = rgba(255, 85, 85, 255);
    pub const light_purple = rgba(255, 85, 255, 255);
    pub const yellow = rgba(255, 255, 85, 255);
    pub const white = rgba(255, 255, 255, 255);
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
