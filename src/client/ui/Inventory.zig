// Minecraft Classic block-picker overlay.
//
// A 9x5 grid of iso-projected block icons drawn over a translucent black
// panel, with a tooltip naming the focused block. Opens with the
// `inventory_toggle` action (B on desktop, L+R on PSP) and replaces
// the player's currently selected hotbar slot when a cell is confirmed.
//
// Cursor hover and gamepad d-pad navigation share the same `focus` field.
// On confirm, the focused block id is written to player.hotbar[selected_slot]
// and the overlay closes. Cancel (Esc / gamepad B / Start) closes without
// changing the hotbar.

const std = @import("std");
const ae = @import("aether");
const Rendering = ae.Rendering;
const input = ae.Core.input;

const c = @import("common").consts;
const Block = c.Block;

const Player = @import("../player/Player.zig");
const SpriteBatcher = @import("SpriteBatcher.zig");
const FontBatcher = @import("FontBatcher.zig");
const IsoBlockDrawer = @import("IsoBlockDrawer.zig");
const Scaling = @import("Scaling.zig");
const layout_mod = @import("layout.zig");
const ui_input = @import("input.zig");
const Color = @import("../graphics/Color.zig").Color;
const BlockRegistry = @import("common").BlockRegistry;

const Self = @This();

// -- Layout constants (logical pixels) --------------------------------------

pub const COLS: u8 = 9;
pub const ROWS: u8 = 5;
pub const CAPACITY: u8 = COLS * ROWS; // 45 cells
pub const FILLED: u8 = BlockRegistry.INVENTORY_FILLED; // first N cells hold real blocks

comptime {
    std.debug.assert(CAPACITY == BlockRegistry.INVENTORY_SLOTS);
}

// Hotbar slot stride is 20 px; the inventory uses a slightly larger 24 px to
// give the bigger blocks (and the hover-grow state) breathing room without
// dwarfing the hotbar style.
const SLOT_STRIDE: i16 = 24;
const BLOCK_HALF_EXTENT: f32 = 4.5;
const HOVER_HALF_EXTENT: f32 = 6.0;
const PANEL_PAD: i16 = 8;
// Vertical strip at the top of the panel reserved for the tooltip text.
const TOOLTIP_GAP: i16 = 12;

// Layer ordering: panel sits below the hotbar background (250) so the hotbar
// remains readable; the tooltip sits above the hotbar selector frame (251).
// Inventory iso blocks share the IsoBlockDrawer layer with the hotbar's iso
// blocks (the panel and hotbar bg are geometrically disjoint, so there is no
// overlap to resolve).
const PANEL_LAYER: u8 = 247;
const HIGHLIGHT_LAYER: u8 = 248;
const TOOLTIP_LAYER: u8 = 252;

// -- Grid accessor ----------------------------------------------------------

/// Block shown in slot `idx`. Slots past INVENTORY_FILLED are .air padding.
fn slot(idx: u8) Block {
    return BlockRegistry.inventory_block(idx);
}

// -- Fields -----------------------------------------------------------------

open: bool,
focus: u8,
saved_mouse_captured: bool,
ui_repeat: ui_input.Repeat,

pub fn init() Self {
    return .{
        .open = false,
        .focus = 0,
        .saved_mouse_captured = true,
        .ui_repeat = .{},
    };
}

// -- Lifecycle --------------------------------------------------------------

pub fn open_overlay(self: *Self, player: *Player) void {
    if (self.open) return;
    self.open = true;
    self.focus = if (player.selected_slot < FILLED) player.selected_slot else 0;
    self.saved_mouse_captured = player.mouse_captured;
    player.mouse_captured = false;
    input.set_mouse_relative_mode(false);
    self.ui_repeat = .{};
}

pub fn close_overlay(self: *Self, player: *Player) void {
    if (!self.open) return;
    self.open = false;
    player.mouse_captured = self.saved_mouse_captured;
    input.set_mouse_relative_mode(self.saved_mouse_captured);
    // Discard the spurious delta the input system generates when
    // snapping the cursor back to center on mode switch.
    player.look_delta = .{ 0, 0 };
}

// -- Per-frame update -------------------------------------------------------

pub fn update(self: *Self, ui_in: *const ui_input.UiInput, player: *Player) void {
    std.debug.assert(self.open);

    const screen_w = Rendering.gfx.surface.get_width();
    const screen_h = Rendering.gfx.surface.get_height();
    const lay = layout(screen_w, screen_h);

    // Cursor hover (only on profiles with a pointer). Hovering over a filled
    // cell snaps focus to it; clicks below are then evaluated against this
    // updated focus.
    if (ui_in.cursor_available) {
        if (cell_at_cursor(&lay, ui_in.cursor_x, ui_in.cursor_y)) |idx| {
            if (!slot(idx).is_air()) self.focus = idx;
        }
    }

    // Pad / arrow-key navigation. Movement that would land on Air or out of
    // bounds is rejected so the focused cell is always selectable.
    switch (ui_in.nav) {
        .left => self.try_move(-1),
        .right => self.try_move(1),
        .up => self.try_move(-@as(i16, COLS)),
        .down => self.try_move(@as(i16, COLS)),
        .none => {},
    }

    // Confirm via mouse click on a filled slot, or via gamepad/keyboard
    // confirm (A / Enter / Space).
    var confirmed = ui_in.confirm_edge;
    if (ui_in.click_edge and ui_in.cursor_available) {
        if (cell_at_cursor(&lay, ui_in.cursor_x, ui_in.cursor_y)) |idx| {
            if (!slot(idx).is_air()) {
                self.focus = idx;
                confirmed = true;
            }
        }
    }

    const focused = slot(self.focus);
    if (confirmed and !focused.is_air()) {
        std.debug.assert(player.selected_slot < Player.HOTBAR_SLOTS);
        player.hotbar[player.selected_slot] = focused;
        self.close_overlay(player);
        return;
    }

    if (ui_in.cancel_edge) self.close_overlay(player);
}

fn try_move(self: *Self, delta: i16) void {
    const candidate: i16 = @as(i16, self.focus) + delta;
    if (candidate < 0 or candidate >= @as(i16, CAPACITY)) return;
    const idx: u8 = @intCast(candidate);
    if (slot(idx).is_air()) return;
    self.focus = idx;
}

// -- Layout helpers ---------------------------------------------------------

const Layout = struct {
    panel_left: i16,
    panel_top: i16,
    panel_w: i16,
    panel_h: i16,
    grid_left: i16,
    grid_top: i16,
};

fn layout(screen_w: u32, screen_h: u32) Layout {
    const scale = Scaling.compute(screen_w, screen_h);
    const max_lx: i16 = @intCast(layout_mod.logical_width(screen_w, scale));
    const max_ly: i16 = @intCast(layout_mod.logical_height(screen_h, scale));
    const panel_w: i16 = @as(i16, COLS) * SLOT_STRIDE + 2 * PANEL_PAD;
    const panel_h: i16 = @as(i16, ROWS) * SLOT_STRIDE + 2 * PANEL_PAD + TOOLTIP_GAP;
    const panel_left: i16 = @divTrunc(max_lx - panel_w, 2);
    const panel_top: i16 = @divTrunc(max_ly - panel_h, 2);
    return .{
        .panel_left = panel_left,
        .panel_top = panel_top,
        .panel_w = panel_w,
        .panel_h = panel_h,
        .grid_left = panel_left + PANEL_PAD,
        .grid_top = panel_top + PANEL_PAD + TOOLTIP_GAP,
    };
}

fn cell_center(lay: *const Layout, idx: u8) struct { f32, f32 } {
    const col: i16 = @intCast(idx % COLS);
    const row: i16 = @intCast(idx / COLS);
    const cx: f32 = @floatFromInt(lay.grid_left + col * SLOT_STRIDE + @divTrunc(SLOT_STRIDE, 2));
    const cy: f32 = @floatFromInt(lay.grid_top + row * SLOT_STRIDE + @divTrunc(SLOT_STRIDE, 2));
    return .{ cx, cy };
}

fn cell_at_cursor(lay: *const Layout, cursor_x: i16, cursor_y: i16) ?u8 {
    if (cursor_x < lay.grid_left or cursor_y < lay.grid_top) return null;
    const dx = cursor_x - lay.grid_left;
    const dy = cursor_y - lay.grid_top;
    const col_i = @divTrunc(dx, SLOT_STRIDE);
    const row_i = @divTrunc(dy, SLOT_STRIDE);
    if (col_i < 0 or col_i >= @as(i16, COLS)) return null;
    if (row_i < 0 or row_i >= @as(i16, ROWS)) return null;
    return @intCast(row_i * @as(i16, COLS) + col_i);
}

// -- Draw -------------------------------------------------------------------

pub fn draw(
    self: *const Self,
    batcher: *SpriteBatcher,
    iso: *IsoBlockDrawer,
    fonts: *FontBatcher,
) void {
    std.debug.assert(self.open);

    const screen_w = Rendering.gfx.surface.get_width();
    const screen_h = Rendering.gfx.surface.get_height();
    const lay = layout(screen_w, screen_h);

    // Translucent black panel covering the grid + tooltip strip.
    batcher.add_sprite(&.{
        .texture = &Rendering.Texture.Default,
        .pos_offset = .{ .x = lay.panel_left, .y = lay.panel_top },
        .pos_extent = .{ .x = lay.panel_w, .y = lay.panel_h },
        .tex_offset = .{ .x = 0, .y = 0 },
        .tex_extent = .{ .x = 1, .y = 1 },
        .color = Color.rgba(0, 0, 0, 160),
        .layer = PANEL_LAYER,
        .reference = .top_left,
        .origin = .top_left,
    });

    // Iso block icons. Queue the focused slot LAST so its enlarged footprint
    // overlaps neighbors on top of them within the single iso draw call.
    var i: u8 = 0;
    while (i < CAPACITY) : (i += 1) {
        if (i == self.focus) continue;
        const block = slot(i);
        if (block.is_air()) continue;
        const center = cell_center(&lay, i);
        iso.add_block(block, center[0], center[1], BLOCK_HALF_EXTENT);
    }
    const focused = slot(self.focus);
    if (!focused.is_air()) {
        const center = cell_center(&lay, self.focus);

        // Translucent light square behind the focused block for selection clarity.
        const highlight_size: i16 = SLOT_STRIDE + SLOT_STRIDE / 5; // ~20% larger
        const half: i16 = @divTrunc(highlight_size, 2);
        batcher.add_sprite(&.{
            .texture = &Rendering.Texture.Default,
            .pos_offset = .{ .x = @as(i16, @intFromFloat(center[0])) - half, .y = @as(i16, @intFromFloat(center[1])) - half },
            .pos_extent = .{ .x = highlight_size, .y = highlight_size },
            .tex_offset = .{ .x = 0, .y = 0 },
            .tex_extent = .{ .x = 1, .y = 1 },
            .color = Color.rgba(255, 255, 255, 48),
            .layer = HIGHLIGHT_LAYER,
            .reference = .top_left,
            .origin = .top_left,
        });

        iso.add_block(focused, center[0], center[1], HOVER_HALF_EXTENT);
    }

    // Tooltip: focused block name centered horizontally above the grid. The
    // panel is itself horizontally centered, so a screen-anchored top_center
    // text aligns with the panel automatically.
    const name = focused.display_name();
    if (name.len > 0) {
        fonts.add_text(&.{
            .str = name,
            .pos_x = 0,
            .pos_y = lay.panel_top + PANEL_PAD,
            .color = .white_fg,
            .shadow_color = .menu_gray,
            .spacing = 0,
            .layer = TOOLTIP_LAYER,
            .reference = .top_center,
            .origin = .top_center,
        });
    }
}
