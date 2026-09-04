//! Remote player positions and names populated by multiplayer packets.

const std = @import("std");
const ae = @import("aether");
const Rendering = ae.Rendering;

const core = @import("core");

const UiDrawList = @import("UiDrawList.zig");
const Scaling = ae.UI.Scaling;
const Colors = @import("../graphics/Color.zig");
const Color = Colors.Color;

const PlayerList = @This();

const ROW_H: i16 = 10;
const PAD: i16 = 6;
const PANEL_W: i16 = 120;
const PANEL_TOP: i16 = 20;
const HEADER_H: i16 = 12;

// Below inventory (247+) and hotbar (250+).
const PANEL_LAYER: u8 = 244;
const TEXT_LAYER: u8 = 245;

// Leave PSP font entries available for concurrent HUD text.
const MAX_VISIBLE: u8 = if (ae.platform == .psp) 4 else 60;

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

entries: [core.Server.MaxPlayers]Entry,

pub fn init() PlayerList {
    return .{ .entries = std.mem.zeroes([core.Server.MaxPlayers]Entry) };
}

/// Trim trailing spaces/NULs from the first 16 bytes of the protocol name.
pub fn spawn(self: *PlayerList, pid: i8, raw: []const u8, x: u16, y: u16, z: u16, yaw: u8, pitch: u8) void {
    if (pid < 0) return;
    const idx: usize = @intCast(pid);
    if (idx >= core.Server.MaxPlayers) return;
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

pub fn despawn(self: *PlayerList, pid: i8) void {
    if (pid < 0) return;
    const idx: usize = @intCast(pid);
    if (idx >= core.Server.MaxPlayers) return;
    self.entries[idx].active = false;
}

pub fn update_position(self: *PlayerList, pid: i8, x: u16, y: u16, z: u16, yaw: u8, pitch: u8) void {
    if (pid < 0) return;
    const idx: usize = @intCast(pid);
    if (idx >= core.Server.MaxPlayers) return;
    if (!self.entries[idx].active) return;
    self.entries[idx].x = x;
    self.entries[idx].y = y;
    self.entries[idx].z = z;
    self.entries[idx].yaw = yaw;
    self.entries[idx].pitch = pitch;
}

pub fn draw_into(self: *const PlayerList, list: *UiDrawList, local_name: []const u8) void {
    const screen_w = Rendering.gfx.surface.get_width();
    const screen_h = Rendering.gfx.surface.get_height();
    const scale = Scaling.compute(screen_w, screen_h);
    const max_lx: i16 = @intCast(screen_w / scale);
    const max_ly: i16 = @intCast(screen_h / scale);

    const available_rows: i16 = @divTrunc(max_ly - PANEL_TOP - HEADER_H - 2 * PAD, ROW_H);
    const rows_cap: u8 = if (available_rows > 0)
        @intCast(@min(available_rows, MAX_VISIBLE))
    else
        0;

    var remote_count: u8 = 0;
    for (&self.entries) |*e| {
        if (e.active) remote_count += 1;
        if (1 + remote_count >= rows_cap) break;
    }
    const count: u8 = 1 + remote_count;

    const panel_h: i16 = HEADER_H + PAD + @as(i16, count) * ROW_H + PAD;
    const panel_left: i16 = @divTrunc(max_lx - PANEL_W, 2);

    list.add_rect(&.{
        .pos_offset = .{ .x = panel_left, .y = PANEL_TOP },
        .pos_extent = .{ .x = PANEL_W, .y = panel_h },
        .color = Color.rgba(0, 0, 0, 160),
        .layer = PANEL_LAYER,
        .reference = .top_left,
        .origin = .top_left,
    });

    list.add_text(&.{
        .str = "Players",
        .pos_x = 0,
        .pos_y = PANEL_TOP + PAD,
        .color = Colors.white_fg,
        .shadow_color = Colors.menu_gray,
        .spacing = 0,
        .layer = TEXT_LAYER,
        .reference = .top_center,
        .origin = .top_center,
    });

    if (local_name.len > 0) {
        list.add_text(&.{
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

    var drawn: u8 = 0;
    for (&self.entries) |*e| {
        if (!e.active or e.name_len == 0) continue;
        if (1 + drawn >= rows_cap) break;
        const row_y: i16 = PANEL_TOP + HEADER_H + PAD + @as(i16, 1 + drawn) * ROW_H;
        list.add_text(&.{
            .str = e.name[0..e.name_len],
            .pos_x = 0,
            .pos_y = row_y,
            .color = Colors.white_fg,
            .shadow_color = Colors.menu_gray,
            .spacing = 0,
            .layer = TEXT_LAYER,
            .reference = .top_center,
            .origin = .top_center,
        });
        drawn += 1;
    }
}
