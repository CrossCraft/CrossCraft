pub const Color = packed struct(u32) {
    r: u8,
    g: u8,
    b: u8,
    a: u8,

    pub fn rgba(r: u8, g: u8, b: u8, a: u8) Color {
        return .{ .r = r, .g = g, .b = b, .a = a };
    }

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
    pub const select = rgba(255, 255, 160, 255);
    pub const splash = rgba(63, 63, 0, 255);
};

comptime {
    @import("std").debug.assert(@sizeOf(Color) == 4);
}
