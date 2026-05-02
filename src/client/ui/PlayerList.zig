// Hold-Tab player list overlay.
//
// Stores remote player names populated by ClientConn on SpawnPlayer /
// DespawnPlayer packets and draws them as a centred translucent panel while
// `player.playerlist_held` is true. Display-only: does not intercept mouse
// input or change `mouse_captured`.

const std = @import("std");
const ae = @import("aether");
const Rendering = ae.Rendering;

const c = @import("common").consts;

const SpriteBatcher = @import("SpriteBatcher.zig");
const FontBatcher = @import("FontBatcher.zig");
const Scaling = @import("Scaling.zig");
const Color = @import("../graphics/Color.zig").Color;

const Self = @This();

// --- Layout constants (logical pixels) ---

const ROW_H: i16 = 10;
const PAD: i16 = 6;
const PANEL_W: i16 = 120;
// Distance from the logical top of the screen to the top of the panel.
const PANEL_TOP: i16 = 20;
// Extra vertical space reserved for the "Players" header row.
const HEADER_H: i16 = 12;

// Layer values: sit below the inventory (247+) and hotbar (250+) but above
// world geometry. Panel layer must be lower than text layer.
const PANEL_LAYER: u8 = 244;
const TEXT_LAYER: u8 = 245;

// Hard ceiling on drawn rows. FontBatcher allocates 64 entries on PSP and 128
// on desktop; leaving half the budget free keeps the overlay compatible with
// concurrent font users (hotbar tooltip, etc.). The actual per-frame limit is
// also clamped to what fits on screen in draw(), so this is a safety backstop.
const MAX_VISIBLE: u8 = if (ae.platform == .psp) 4 else 60;

// --- Data ---

const Entry = struct {
    active: bool,
    name: [16]u8,
    name_len: u8,
    x: u16,
    y: u16,
    z: u16,
    yaw: u8,
    pitch: u8,
};

entries: [c.MAX_PLAYERS]Entry,

// --- Lifecycle ---

pub fn init() Self {
    return .{ .entries = std.mem.zeroes([c.MAX_PLAYERS]Entry) };
}

// --- Data mutations (called from ClientConn packet handlers) ---

/// Register a remote player. `raw` is the 64-byte space-padded name from the
/// SpawnPlayer packet. Only the first 16 non-space bytes are stored.
pub fn spawn(self: *Self, pid: i8, raw: []const u8, x: u16, y: u16, z: u16, yaw: u8, pitch: u8) void {
    if (pid < 0) return;
    const idx: usize = @intCast(pid);
    if (idx >= c.MAX_PLAYERS) return;
    const copy_len = @min(raw.len, 16);
    var len: u8 = 0;
    var i: usize = 0;
    while (i < copy_len) : (i += 1) {
        self.entries[idx].name[i] = raw[i];
        if (raw[i] != ' ' and raw[i] != 0) len = @intCast(i + 1);
    }
    self.entries[idx].name_len = len;
    self.entries[idx].x = x;
    self.entries[idx].y = y;
    self.entries[idx].z = z;
    self.entries[idx].yaw = yaw;
    self.entries[idx].pitch = pitch;
    self.entries[idx].active = true;
}

/// Remove a remote player.
pub fn despawn(self: *Self, pid: i8) void {
    if (pid < 0) return;
    const idx: usize = @intCast(pid);
    if (idx >= c.MAX_PLAYERS) return;
    self.entries[idx].active = false;
}

/// Update a remote player's position and orientation.
pub fn update_position(self: *Self, pid: i8, x: u16, y: u16, z: u16, yaw: u8, pitch: u8) void {
    if (pid < 0) return;
    const idx: usize = @intCast(pid);
    if (idx >= c.MAX_PLAYERS) return;
    if (!self.entries[idx].active) return;
    self.entries[idx].x = x;
    self.entries[idx].y = y;
    self.entries[idx].z = z;
    self.entries[idx].yaw = yaw;
    self.entries[idx].pitch = pitch;
}

// --- Draw ---

pub fn draw(self: *const Self, batcher: *SpriteBatcher, fonts: *FontBatcher, local_name: []const u8) void {
    const screen_w = Rendering.gfx.surface.get_width();
    const screen_h = Rendering.gfx.surface.get_height();
    const scale = Scaling.compute(screen_w, screen_h);
    const max_lx: i16 = @intCast(screen_w / scale);
    const max_ly: i16 = @intCast(screen_h / scale);

    // How many rows fit between the panel top and the bottom margin (PAD).
    // This keeps the panel on-screen regardless of player count or resolution.
    const available_rows: i16 = @divTrunc(max_ly - PANEL_TOP - HEADER_H - 2 * PAD, ROW_H);
    const rows_cap: u8 = if (available_rows > 0)
        @intCast(@min(available_rows, MAX_VISIBLE))
    else
        0;

    // Count rows: local player (always 1) + active remote entries, capped.
    var remote_count: u8 = 0;
    for (&self.entries) |*e| {
        if (e.active) remote_count += 1;
        if (1 + remote_count >= rows_cap) break;
    }
    const count: u8 = 1 + remote_count; // local player always included

    const panel_h: i16 = HEADER_H + PAD + @as(i16, count) * ROW_H + PAD;
    const panel_left: i16 = @divTrunc(max_lx - PANEL_W, 2);

    // Translucent black background panel.
    batcher.add_sprite(&.{
        .texture = &Rendering.Texture.Default,
        .pos_offset = .{ .x = panel_left, .y = PANEL_TOP },
        .pos_extent = .{ .x = PANEL_W, .y = panel_h },
        .tex_offset = .{ .x = 0, .y = 0 },
        .tex_extent = .{ .x = 1, .y = 1 },
        .color = Color.rgba(0, 0, 0, 160),
        .layer = PANEL_LAYER,
        .reference = .top_left,
        .origin = .top_left,
    });

    // "Players" header, horizontally centred.
    fonts.add_text(&.{
        .str = "Players",
        .pos_x = 0,
        .pos_y = PANEL_TOP + PAD,
        .color = .white_fg,
        .shadow_color = .menu_gray,
        .spacing = 0,
        .layer = TEXT_LAYER,
        .reference = .top_center,
        .origin = .top_center,
    });

    // Local player first (yellow to distinguish from remote players).
    if (local_name.len > 0) {
        fonts.add_text(&.{
            .str = local_name,
            .pos_x = 0,
            .pos_y = PANEL_TOP + HEADER_H + PAD,
            .color = Color.rgba(255, 255, 0, 255),
            .shadow_color = Color.rgba(50, 50, 0, 255),
            .spacing = 0,
            .layer = TEXT_LAYER,
            .reference = .top_center,
            .origin = .top_center,
        });
    }

    // Remote players, one row each, stopping at the screen-derived cap.
    var drawn: u8 = 0;
    for (&self.entries) |*e| {
        if (!e.active or e.name_len == 0) continue;
        if (1 + drawn >= rows_cap) break;
        const row_y: i16 = PANEL_TOP + HEADER_H + PAD + @as(i16, 1 + drawn) * ROW_H;
        fonts.add_text(&.{
            .str = e.name[0..e.name_len],
            .pos_x = 0,
            .pos_y = row_y,
            .color = .white_fg,
            .shadow_color = .menu_gray,
            .spacing = 0,
            .layer = TEXT_LAYER,
            .reference = .top_center,
            .origin = .top_center,
        });
        drawn += 1;
    }
}
