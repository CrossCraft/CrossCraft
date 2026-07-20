const UI = @import("aether").UI;

pub const Color = UI.Color;

pub const none = Color.rgba(0, 0, 0, 0);
pub const gold = Color.rgba(255, 170, 0, 255);

// Minecraft Classic chat color palette (foreground / background pairs),
// indexed by the '&' code (&0..&f). Names use the "alternate" naming.
pub const black_fg = Color.rgba(0, 0, 0, 255);
pub const black_bg = Color.rgba(0, 0, 0, 255);
pub const navy_fg = Color.rgba(0, 0, 170, 255);
pub const navy_bg = Color.rgba(0, 0, 42, 255);
pub const green_fg = Color.rgba(0, 170, 0, 255);
pub const green_bg = Color.rgba(0, 42, 0, 255);
pub const teal_fg = Color.rgba(0, 170, 170, 255);
pub const teal_bg = Color.rgba(0, 42, 42, 255);
pub const maroon_fg = Color.rgba(170, 0, 0, 255);
pub const maroon_bg = Color.rgba(42, 0, 0, 255);
pub const purple_fg = Color.rgba(170, 0, 170, 255);
pub const purple_bg = Color.rgba(42, 0, 42, 255);
pub const gold_fg = Color.rgba(170, 170, 0, 255);
pub const gold_bg = Color.rgba(42, 42, 0, 255);
pub const silver_fg = Color.rgba(170, 170, 170, 255);
pub const silver_bg = Color.rgba(42, 42, 42, 255);
pub const gray_fg = Color.rgba(85, 85, 85, 255);
pub const gray_bg = Color.rgba(21, 21, 21, 255);
pub const blue_fg = Color.rgba(85, 85, 255, 255);
pub const blue_bg = Color.rgba(21, 21, 63, 255);
pub const lime_fg = Color.rgba(85, 255, 85, 255);
pub const lime_bg = Color.rgba(21, 63, 21, 255);
pub const aqua_fg = Color.rgba(85, 255, 255, 255);
pub const aqua_bg = Color.rgba(21, 63, 63, 255);
pub const red_fg = Color.rgba(255, 85, 85, 255);
pub const red_bg = Color.rgba(63, 21, 21, 255);
pub const pink_fg = Color.rgba(255, 85, 255, 255);
pub const pink_bg = Color.rgba(63, 21, 63, 255);
pub const yellow_fg = Color.rgba(255, 255, 85, 255);
pub const yellow_bg = Color.rgba(63, 63, 21, 255);
pub const white_fg = Color.rgba(255, 255, 255, 255);
pub const white_bg = Color.rgba(63, 63, 63, 255);

pub const be_mtx_gold = Color.rgba(221, 214, 5, 255);
pub const select_front = Color.rgba(255, 255, 160, 255);
pub const select_back = Color.rgba(63, 63, 40, 255);
pub const splash_front = Color.rgba(255, 255, 0, 255);
pub const splash_back = Color.rgba(62, 62, 0, 255);
pub const menu_version = Color.rgba(22, 22, 21, 255);
pub const menu_copyright = Color.rgba(62, 62, 62, 255);
pub const menu_tiles = Color.rgba(70, 70, 70, 255);
pub const menu_gray = Color.rgba(50, 50, 50, 255);
pub const progress_bar = Color.rgba(0x80, 0xFF, 0x80, 0xFF);
pub const progress_bg = Color.rgba(0x80, 0x80, 0x80, 0xFF);
pub const game_daytime = Color.rgba(191, 216, 255, 255);
pub const game_daytime_zenith = Color.rgba(119, 167, 255, 255);
pub const game_underwater = Color.rgba(5, 5, 21, 255);
pub const game_underlava = Color.rgba(153, 25, 0, 255);
