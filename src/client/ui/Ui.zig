const std = @import("std");
const assert = std.debug.assert;
const ae = @import("aether");
const caps = @import("capabilities").ClientType(ae);
const Rendering = ae.Rendering;

const core = @import("core");
const layout_mod = ae.Ui.layout;
const texture_region = ae.Ui.texture_region;
const widget_style = @import("WidgetStyle.zig");
const prompt_strip = @import("PromptStrip.zig");
const prompts_mod = @import("Prompts.zig");
const ui_input = @import("input.zig");
const widget_id = @import("widget_id.zig");
const FontBatcher = ae.Ui.FontBatcher;
const UiDrawList = @import("UiDrawList.zig");
const UiState = @import("UiState.zig");
const Colors = @import("../graphics/Color.zig");

pub const LogicalRect = layout_mod.LogicalRect;
pub const Point = layout_mod.Point;
pub const Anchor = layout_mod.Anchor;
pub const TextureRegion = texture_region.TextureRegion;
pub const Color = Colors.Color;
pub const WidgetId = widget_id.WidgetId;
pub const ButtonStyle = widget_style.Button;
pub const SliderStyle = widget_style.Slider;
pub const TextFieldStyle = widget_style.TextField;
pub const Prompt = prompt_strip.Prompt;
pub const UiInput = ui_input.UiInput;

pub const Axis = ae.Ui.FlowLayout.Axis;
pub const CrossAlign = ae.Ui.FlowLayout.CrossAlign;
pub const Size = ae.Ui.FlowLayout.Size;
pub const Box = ae.Ui.FlowLayout.Box;
pub const Padding = ae.Ui.FlowLayout.Padding;
pub const StackOpts = ae.Ui.FlowLayout.Options;
const Ui = @This();
draw: *UiDrawList,
state: *UiState,
input: *const UiInput,
fonts: *const FontBatcher,
gui_tex: *const Rendering.Texture,
glyphs_tex: *const Rendering.Texture,
screen: LogicalRect,
layer_base: u8,
context: ae.Ui.Context,
flow_storage: [8]ae.Ui.FlowLayout.Scope = undefined,
item_storage: [96]ae.Ui.FlowLayout.Item = undefined,
flow: ?ae.Ui.FlowLayout = null,
label_buf: [1536]u8 = undefined,
label_used: usize = 0,
close_requested: bool = false,
pub const ScopeHandle = struct {
    ui: *Ui,
    pub fn end(self: ScopeHandle) void {
        self.ui.flow_ptr().end(&self.ui.context) catch |err| failed(err);
        self.ui.sync();
    }
};
pub const InitArgs = struct {
    draw: *UiDrawList,
    state: *UiState,
    input: *const UiInput,
    fonts: *const FontBatcher,
    gui_tex: *const Rendering.Texture,
    glyphs_tex: *const Rendering.Texture,
    screen: LogicalRect,
    layer_base: u8 = 0,
};

pub fn begin(args: InitArgs) Ui {
    args.draw.bind_font(args.fonts);
    const state = args.state.get(args.fonts.allocator);
    return .{ .draw = args.draw, .state = args.state, .input = args.input, .fonts = args.fonts, .gui_tex = args.gui_tex, .glyphs_tex = args.glyphs_tex, .screen = args.screen, .layer_base = args.layer_base, .context = ae.Ui.Context.begin(state, args.draw.native(), .{ .bounds = args.screen, .input = args.input.frame(), .font = args.fonts, .replay = !args.input.text_events, .deferred_hit_test = true, .pointer_activation = .press, .slider_capture = true, .paint = false, .live_text = true, .text_events = args.input.text_events }) catch |err| failed(err) };
}
fn failed(err: anyerror) noreturn {
    std.debug.panic("UI failed: {s}", .{@errorName(err)});
}
fn flow_ptr(self: *Ui) *ae.Ui.FlowLayout {
    if (self.flow == null) self.flow = ae.Ui.FlowLayout.init(self.screen, &self.flow_storage, &self.item_storage);
    return &self.flow.?;
}
fn sync(self: *Ui) void {
    self.state.sync();
    self.draw.count = self.draw.native().count;
}
pub fn end(self: *Ui) void {
    assert(self.flow_ptr().depth == 0);
    self.context.end() catch |err| failed(err);
    self.sync();
}
pub fn stack(self: *Ui, options: StackOpts) ScopeHandle {
    self.flow_ptr().stack(&self.context, options) catch |err| failed(err);
    return .{ .ui = self };
}
fn record(self: *Ui, first: ae.Ui.Context.Mark, rect: LogicalRect) void {
    self.flow_ptr().record(&self.context, first, rect) catch |err| failed(err);
    self.sync();
}
pub fn label(self: *Ui, text: []const u8) void {
    const first = self.context.mark();
    const rect = self.flow_ptr().reserve(.{ .x = self.fonts.string_width(text, 0, 1), .y = if (text.len > 0) 8 else 0 });
    if (text.len > 0) self.draw.add_text(&.{ .str = text, .pos_x = rect.x0, .pos_y = rect.y0, .color = Colors.white_fg, .shadow_color = Colors.menu_gray, .spacing = 0, .layer = self.layer_base + 3, .reference = .top_left, .origin = .top_left });
    self.record(first, rect);
}
pub fn spacer(self: *Ui, width: i16, height: i16) void {
    const first = self.context.mark();
    const rect = self.flow_ptr().reserve(.{ .x = width, .y = height });
    self.record(first, rect);
}
pub const ButtonOpts = struct {
    width: i16 = 200,
    height: i16 = 20,
    enabled: bool = true,
    style: *const ButtonStyle = &ButtonStyle.classic,
};

pub fn button(self: *Ui, id: WidgetId, text: []const u8, opts: ButtonOpts) bool {
    const first = self.context.mark();
    const rect = self.flow_ptr().reserve(.{ .x = opts.width, .y = opts.height });
    const activated = self.context.button_at(id, text, rect, opts.enabled) catch |err| failed(err);
    self.sync();
    draw_button(self, rect, text, self.state.focused == id or self.state.hovered == id, opts);
    self.record(first, rect);
    return activated;
}
pub const SliderOpts = struct {
    width: i16 = 150,
    height: i16 = 20,
    label: []const u8 = "",
    min: f32,
    max: f32,
    nudge: f32 = 0.05,
    scale: enum { linear, log10 } = .linear,
    style: *const SliderStyle = &SliderStyle.classic,
};

pub fn slider(self: *Ui, id: WidgetId, value: *f32, opts: SliderOpts) bool {
    const first = self.context.mark();
    const rect = self.flow_ptr().reserve(.{ .x = opts.width, .y = opts.height });
    var normalized = slider_pos_from_value(value.*, opts);
    const changed = self.context.slider(id, rect, &normalized, 0, 1, if (opts.nudge > 0) opts.nudge else 0.05, true) catch |err| failed(err);
    if (changed) value.* = slider_value_from_pos(opts, normalized);
    self.sync();
    draw_slider(self, rect, id, value.*, opts, self.state.focused == id or self.state.hovered == id);
    self.record(first, rect);
    return changed;
}
pub const TextBuf = struct { bytes: [*]u8, len: *u8, max: u8 };
pub const TextEvent = enum { none, changed, submit };
pub const TextOpts = struct {
    width: i16 = 200,
    height: i16 = 20,
    placeholder: []const u8 = "",
    session_id: []const u8,
    style: *const TextFieldStyle = &TextFieldStyle.classic,
};

pub fn text_field(self: *Ui, id: WidgetId, buffer: *TextBuf, opts: TextOpts) TextEvent {
    const first = self.context.mark();
    const rect = self.flow_ptr().reserve(.{ .x = opts.width, .y = opts.height });
    var length: usize = buffer.len.*;
    const result = self.context.text_field(id, rect, buffer.bytes[0..buffer.max], &length, true) catch |err| failed(err);
    buffer.len.* = @intCast(length);
    self.sync();
    draw_textfield(self, rect, id, buffer, opts);
    self.record(first, rect);
    return if (result.submitted) (if (caps.ui.system_text_entry) .changed else .submit) else if (result.changed) .changed else .none;
}
pub const SlotGridStyle = enum { pause, hotbar };
pub const SlotGridOpts = struct {
    cols: u8,
    rows: u8,
    cell: i16 = 24,
    blocks: []const core.blocks.Block,
    cursor: *u8,
    show_tooltip: bool = true,
    interactive: bool = true,
    style: SlotGridStyle = .pause,
    padding: Padding = Padding.all(8),
    tooltip_gap: i16 = 12,
    block_half_extent: f32 = 4.5,
    hover_half_extent: f32 = 6.0,
    panel_color: Color = Color.rgba(0, 0, 0, 160),
    highlight_color: Color = Color.rgba(255, 255, 255, 48),
};

pub fn slot_grid(self: *Ui, id: WidgetId, opts: SlotGridOpts) ?u8 {
    const first = self.context.mark();
    const rect = self.flow_ptr().reserve(slot_grid_size(opts));
    var cursor: usize = opts.cursor.*;
    const activated = self.context.selectable_grid(id, slot_grid_inner_rect(opts, rect), opts.blocks.len, opts.cols, &cursor, .{ .context = self, .draw = grid_item }, opts.interactive) catch |err| failed(err);
    opts.cursor.* = @intCast(cursor);
    self.sync();
    draw_slot_grid(self, rect, opts);
    self.record(first, rect);
    return if (activated and slot_valid(opts, opts.cursor.*)) opts.cursor.* else null;
}
fn grid_item(_: *anyopaque, _: *ae.Ui.Context, _: usize, _: LogicalRect, _: bool) !void {}
pub const ScrollListOpts = struct {
    width: i16,
    height: i16,
    gap: i16 = 0,
    padding: Padding = .{},
    cross_align: CrossAlign = .center,
    wheel_step: i16 = 22,
};

pub fn scroll_list(self: *Ui, id: WidgetId, opts: ScrollListOpts) ScopeHandle {
    self.flow_ptr().scroll(&self.context, id, .{ .x = opts.width, .y = opts.height }, .{ .axis = .vertical, .anchor = .top_left, .gap = opts.gap, .padding = opts.padding, .cross_align = opts.cross_align, .wheel_step = opts.wheel_step }) catch |err| failed(err);
    return .{ .ui = self };
}
pub fn prompts(self: *Ui, list: []const Prompt) void {
    prompt_strip.draw_into(
        self.draw,
        self.glyphs_tex,
        self.fonts,
        list,
        .bottom_left,
        prompt_strip.DefaultPosX,
        prompt_strip.DefaultPosY,
        self.layer_base + 2,
        self.layer_base + 3,
    );
}

pub fn contextual_prompts(self: *Ui) void {
    self.sync();
    if (self.state.captured != null) {
        self.prompts(&.{ prompts_mod.left_right(), prompts_mod.exit_adjust() });
        return;
    }
    if (self.state.active_text != null) {
        self.prompts(&.{ prompts_mod.done(), prompts_mod.cancel() });
        return;
    }
    const engine = self.context.state;
    for (engine.focusables[engine.current][0..engine.focus_count[engine.current]]) |item| if (engine.focused == item.id) {
        self.prompts(if (item.kind == .text_field) &.{ prompts_mod.edit(), prompts_mod.back() } else if (item.kind == .slider) &.{ prompts_mod.adjust(), prompts_mod.back() } else &.{ prompts_mod.select(), prompts_mod.back() });
        return;
    };
    self.prompts(&.{ prompts_mod.select(), prompts_mod.back() });
}
pub fn cancel_pressed(self: *const Ui) bool {
    return self.input.cancel_edge and !self.context.cancel_consumed and !self.context.confirm_claimed;
}
pub fn inventory_pressed(self: *const Ui) bool {
    return self.input.inventory_edge and !self.context.cancel_consumed and !self.context.confirm_claimed;
}
pub fn close_request(self: *Ui) void {
    self.close_requested = true;
}
pub fn fmt(self: *Ui, comptime f: []const u8, args: anytype) []const u8 {
    if (self.label_used >= self.label_buf.len) return &.{};
    const remaining = self.label_buf[self.label_used..];
    const out = std.fmt.bufPrint(remaining, f, args) catch return &.{};
    self.label_used += @intCast(out.len);
    return out;
}

fn persist(_: *Ui, text: []const u8) []const u8 {
    return text;
}
fn slider_pos_from_value(value: f32, opts: SliderOpts) f32 {
    assert(std.math.isFinite(value));
    const span = opts.max - opts.min;
    if (span <= 0) return 0;
    return switch (opts.scale) {
        .linear => std.math.clamp((value - opts.min) / span, 0.0, 1.0),
        .log10 => blk: {
            const lmin = std.math.log10(@max(opts.min, 1e-6));
            const lmax = std.math.log10(@max(opts.max, 1e-6));
            const lspan = lmax - lmin;
            if (lspan <= 0) break :blk 0;
            const lv = std.math.log10(@max(value, 1e-6));
            break :blk std.math.clamp((lv - lmin) / lspan, 0.0, 1.0);
        },
    };
}

fn slider_value_from_pos(opts: SliderOpts, pos: f32) f32 {
    assert(std.math.isFinite(pos));
    const p = std.math.clamp(pos, 0.0, 1.0);
    return switch (opts.scale) {
        .linear => opts.min + (opts.max - opts.min) * p,
        .log10 => blk: {
            const lmin = std.math.log10(@max(opts.min, 1e-6));
            const lmax = std.math.log10(@max(opts.max, 1e-6));
            const lv = lmin + (lmax - lmin) * p;
            break :blk std.math.pow(f32, 10.0, lv);
        },
    };
}

fn slot_grid_size(opts: SlotGridOpts) Point {
    const pad = if (opts.style == .hotbar) Padding{} else opts.padding;
    const tooltip_gap: i16 = if (opts.show_tooltip) opts.tooltip_gap else 0;
    return .{
        .x = @as(i16, @intCast(opts.cols)) * opts.cell + pad.horizontal(),
        .y = @as(i16, @intCast(opts.rows)) * opts.cell + pad.vertical() + tooltip_gap,
    };
}

fn slot_grid_inner_rect(opts: SlotGridOpts, rect: LogicalRect) LogicalRect {
    const pad = if (opts.style == .hotbar) Padding{} else opts.padding;
    const tooltip_gap: i16 = if (opts.show_tooltip) opts.tooltip_gap else 0;
    return .{
        .x0 = rect.x0 + pad.left,
        .y0 = rect.y0 + pad.top + tooltip_gap,
        .x1 = rect.x0 + pad.left + @as(i16, @intCast(opts.cols)) * opts.cell,
        .y1 = rect.y0 + pad.top + tooltip_gap + @as(i16, @intCast(opts.rows)) * opts.cell,
    };
}

fn slot_valid(opts: SlotGridOpts, idx: u8) bool {
    if (idx >= opts.blocks.len) return false;
    return !opts.blocks[idx].is_air();
}

fn draw_button(ui: *Ui, rect: LogicalRect, text: []const u8, focused: bool, opts: ButtonOpts) void {
    const style = opts.style;
    const region = if (!opts.enabled) style.disabled else if (focused) style.hover else style.normal;
    const elide = switch (style.sizing) {
        .center_elide => |c| c,
        else => unreachable,
    };
    ui.draw.add_sprite_elided(&.{
        .texture = ui.gui_tex,
        .region = region,
        .pos_offset = .{ .x = rect.x0, .y = rect.y0 },
        .dst_w = rect.width(),
        .dst_h = rect.height(),
        .color = Colors.white_fg,
        .layer = ui.layer_base + 2,
        .reference = .top_left,
        .origin = .top_left,
        .sizing = elide,
    });

    const inner_w: i16 = @max(rect.width() - 2 * style.text_padding_x, 0);
    const fit = ui.fonts.fit_width(text, inner_w, 0, 1);
    if (fit == 0) return;
    const label_color = if (!opts.enabled) style.label_color_disabled else if (focused) style.label_color_hover else style.label_color_normal;
    const shadow_color = if (focused) style.shadow_color_hover else style.shadow_color_normal;
    ui.draw.add_text(&.{
        .str = ui.persist(text[0..fit]),
        .pos_x = rect.x0 + @divTrunc(rect.width(), 2),
        .pos_y = rect.y0 + @divTrunc(rect.height() - 8, 2),
        .color = label_color,
        .shadow_color = shadow_color,
        .spacing = 0,
        .layer = ui.layer_base + 3,
        .reference = .top_left,
        .origin = .top_center,
    });
}

fn draw_rect_outline(ui: *Ui, rect: LogicalRect, thickness: i16, color: Color, layer: u8) void {
    const w = rect.width();
    const h = rect.height();
    if (thickness <= 0 or w <= 0 or h <= 0) return;

    const t = @min(thickness, @min(w, h));
    ui.draw.add_rect(&.{
        .pos_offset = .{ .x = rect.x0, .y = rect.y0 },
        .pos_extent = .{ .x = w, .y = t },
        .color = color,
        .layer = layer,
    });
    if (h > t) {
        ui.draw.add_rect(&.{
            .pos_offset = .{ .x = rect.x0, .y = rect.y1 - t },
            .pos_extent = .{ .x = w, .y = t },
            .color = color,
            .layer = layer,
        });
    }

    const side_h = h - 2 * t;
    if (side_h <= 0 or w <= t) return;
    ui.draw.add_rect(&.{
        .pos_offset = .{ .x = rect.x0, .y = rect.y0 + t },
        .pos_extent = .{ .x = t, .y = side_h },
        .color = color,
        .layer = layer,
    });
    ui.draw.add_rect(&.{
        .pos_offset = .{ .x = rect.x1 - t, .y = rect.y0 + t },
        .pos_extent = .{ .x = t, .y = side_h },
        .color = color,
        .layer = layer,
    });
}

fn draw_slider(ui: *Ui, rect: LogicalRect, id: WidgetId, value: f32, opts: SliderOpts, focused: bool) void {
    const style = opts.style;
    const elide = switch (style.sizing) {
        .center_elide => |c| c,
        else => unreachable,
    };
    ui.draw.add_sprite_elided(&.{
        .texture = ui.gui_tex,
        .region = style.track_normal,
        .pos_offset = .{ .x = rect.x0, .y = rect.y0 },
        .dst_w = rect.width(),
        .dst_h = rect.height(),
        .color = Colors.white_fg,
        .layer = ui.layer_base + 2,
        .reference = .top_left,
        .origin = .top_left,
        .sizing = elide,
    });
    const usable: i32 = @as(i32, rect.width()) - @as(i32, style.knob_w);
    const norm = slider_pos_from_value(value, opts);
    const offset: i32 = if (usable > 0) @intFromFloat(@round(norm * @as(f32, @floatFromInt(usable)))) else 0;
    const knob_x: i16 = rect.x0 + @as(i16, @intCast(offset));
    const dragging = ui.state.captured != null and ui.state.captured.? == id;
    const knob_region = if (dragging) style.knob_active else if (focused) style.knob_hover else style.knob_normal;
    ui.draw.add_sprite_elided(&.{
        .texture = ui.gui_tex,
        .region = knob_region,
        .pos_offset = .{ .x = knob_x, .y = rect.y0 },
        .dst_w = style.knob_w,
        .dst_h = rect.height(),
        .color = Colors.white_fg,
        .layer = ui.layer_base + 3,
        .reference = .top_left,
        .origin = .top_left,
        .sizing = elide,
    });
    if (dragging) {
        draw_rect_outline(ui, rect, style.active_outline_thickness, style.active_outline_color, ui.layer_base + 5);
    } else if (focused) {
        draw_rect_outline(ui, rect, style.focus_outline_thickness, style.focus_outline_color, ui.layer_base + 5);
    }
    if (opts.label.len == 0) return;
    const inner_w: i16 = @max(rect.width() - 2 * style.text_padding_x, 0);
    const fit = ui.fonts.fit_width(opts.label, inner_w, 0, 1);
    if (fit == 0) return;
    ui.draw.add_text(&.{
        .str = ui.persist(opts.label[0..fit]),
        .pos_x = rect.x0 + @divTrunc(rect.width(), 2),
        .pos_y = rect.y0 + @divTrunc(rect.height() - 8, 2),
        .color = if (focused) style.label_color_hover else style.label_color,
        .shadow_color = if (focused) style.shadow_color_hover else style.shadow_color_normal,
        .spacing = 0,
        .layer = ui.layer_base + 4,
        .reference = .top_left,
        .origin = .top_center,
    });
}

fn draw_textfield(ui: *Ui, rect: LogicalRect, id: WidgetId, buf: *TextBuf, opts: TextOpts) void {
    const style = opts.style;
    const elide = switch (style.sizing) {
        .center_elide => |c| c,
        else => unreachable,
    };
    ui.draw.add_sprite_elided(&.{
        .texture = ui.gui_tex,
        .region = style.bg_region,
        .pos_offset = .{ .x = rect.x0, .y = rect.y0 },
        .dst_w = rect.width(),
        .dst_h = rect.height(),
        .color = style.bg_color,
        .layer = ui.layer_base + 2,
        .reference = .top_left,
        .origin = .top_left,
        .sizing = elide,
    });
    const active = ui.state.active_text != null and ui.state.active_text.? == id;
    const focused = ui.state.focused == id or ui.state.hovered == id;
    if (active) {
        draw_rect_outline(ui, rect, style.active_outline_thickness, style.active_outline_color, ui.layer_base + 4);
    } else if (focused) {
        draw_rect_outline(ui, rect, style.focus_outline_thickness, style.focus_outline_color, ui.layer_base + 4);
    }
    const text_x = rect.x0 + style.text_padding_x;
    const text_y = rect.y0 + @divTrunc(rect.height() - 8, 2);
    const len = buf.len.*;
    if (len > 0) {
        const text = buf.bytes[0..len];
        ui.draw.add_text(&.{
            .str = ui.persist(text),
            .pos_x = text_x,
            .pos_y = text_y,
            .color = style.text_color,
            .shadow_color = style.text_shadow,
            .spacing = 0,
            .layer = ui.layer_base + 3,
            .reference = .top_left,
            .origin = .top_left,
        });
        if (active) {
            const tw = ui.fonts.string_width(text, 0, 1);
            ui.draw.add_text(&.{
                .str = "_",
                .pos_x = text_x + tw + 1,
                .pos_y = text_y,
                .color = style.cursor_color,
                .shadow_color = style.text_shadow,
                .spacing = 0,
                .layer = ui.layer_base + 3,
                .reference = .top_left,
                .origin = .top_left,
            });
        }
    } else {
        const display = if (active) "_" else opts.placeholder;
        if (display.len == 0) return;
        ui.draw.add_text(&.{
            .str = ui.persist(display),
            .pos_x = text_x,
            .pos_y = text_y,
            .color = if (active) style.cursor_color else style.placeholder_color,
            .shadow_color = style.text_shadow,
            .spacing = 0,
            .layer = ui.layer_base + 3,
            .reference = .top_left,
            .origin = .top_left,
        });
    }
}

fn draw_slot_grid(ui: *Ui, rect: LogicalRect, opts: SlotGridOpts) void {
    if (opts.style == .pause) {
        ui.draw.add_rect(&.{
            .pos_offset = .{ .x = rect.x0, .y = rect.y0 },
            .pos_extent = .{ .x = rect.width(), .y = rect.height() },
            .color = opts.panel_color,
            .layer = ui.layer_base + 0,
            .reference = .top_left,
            .origin = .top_left,
        });
    }

    const cols_i: i16 = @intCast(opts.cols);
    const inner = slot_grid_inner_rect(opts, rect);
    const focus_idx = opts.cursor.*;
    const has_focus_cell = slot_valid(opts, focus_idx);
    if (has_focus_cell) {
        const highlight_size: i16 = opts.cell + @divTrunc(opts.cell, 5);
        const half: i16 = @divTrunc(highlight_size, 2);
        const idx_i: i16 = @intCast(focus_idx);
        const col: i16 = @mod(idx_i, cols_i);
        const row: i16 = @divTrunc(idx_i, cols_i);
        const cx: i16 = inner.x0 + col * opts.cell + @divTrunc(opts.cell, 2);
        const cy: i16 = inner.y0 + row * opts.cell + @divTrunc(opts.cell, 2);
        ui.draw.add_rect(&.{
            .pos_offset = .{ .x = cx - half, .y = cy - half },
            .pos_extent = .{ .x = highlight_size, .y = highlight_size },
            .color = opts.highlight_color,
            .layer = ui.layer_base + 1,
            .reference = .top_left,
            .origin = .top_left,
        });
    }

    var i: u8 = 0;
    while (i < opts.blocks.len) : (i += 1) {
        if (has_focus_cell and i == focus_idx) continue;
        const block = opts.blocks[i];
        if (block.is_air()) continue;
        const idx_i: i16 = @intCast(i);
        const col: i16 = @mod(idx_i, cols_i);
        const row: i16 = @divTrunc(idx_i, cols_i);
        ui.draw.add_iso_block(&.{
            .block = block,
            .cx = @floatFromInt(inner.x0 + col * opts.cell + @divTrunc(opts.cell, 2)),
            .cy = @floatFromInt(inner.y0 + row * opts.cell + @divTrunc(opts.cell, 2)),
            .half_extent_px = opts.block_half_extent,
        });
    }
    if (has_focus_cell) {
        const idx_i: i16 = @intCast(focus_idx);
        const col: i16 = @mod(idx_i, cols_i);
        const row: i16 = @divTrunc(idx_i, cols_i);
        ui.draw.add_iso_block(&.{
            .block = opts.blocks[focus_idx],
            .cx = @floatFromInt(inner.x0 + col * opts.cell + @divTrunc(opts.cell, 2)),
            .cy = @floatFromInt(inner.y0 + row * opts.cell + @divTrunc(opts.cell, 2)),
            .half_extent_px = opts.hover_half_extent,
        });
    }
    if (!opts.show_tooltip or !has_focus_cell) return;
    const name = opts.blocks[focus_idx].display_name();
    if (name.len == 0) return;
    ui.draw.add_text(&.{
        .str = name,
        .pos_x = rect.x0 + @divTrunc(rect.width(), 2),
        .pos_y = rect.y0 + opts.padding.top,
        .color = Colors.white_fg,
        .shadow_color = Colors.menu_gray,
        .spacing = 0,
        .layer = ui.layer_base + 5,
        .reference = .top_left,
        .origin = .top_center,
    });
}

test "Aether menu adapter keeps centered click targets across draw replay" {
    var fonts: FontBatcher = undefined;
    fonts.style_parser = null;
    fonts.glyph_widths = @splat(4);
    fonts.allocator = std.testing.allocator;
    var texture: Rendering.Texture = undefined;
    texture.width = 256;
    texture.height = 256;
    var state: UiState = .{};
    defer state.deinit();

    var list: UiDrawList = .{};
    const screen: LogicalRect = .{ .x0 = 0, .y0 = 0, .x1 = 400, .y1 = 240 };
    var input_frame: UiInput = .{};
    var ui = begin(.{ .draw = &list, .state = &state, .input = &input_frame, .fonts = &fonts, .gui_tex = &texture, .glyphs_tex = &texture, .screen = screen });
    var column = ui.stack(.{});
    try std.testing.expect(!ui.button(1, "Test", .{}));
    column.end();
    ui.end();
    try std.testing.expectEqual(LogicalRect{ .x0 = 100, .y0 = 110, .x1 = 300, .y1 = 130 }, state.implementation.?.focusables[state.implementation.?.current][0].bounds);
    list.native().clear();
    input_frame = .{ .cursor_x = 110, .cursor_y = 115, .cursor_available = true, .cursor_moved = true, .click_edge = true, .click_held = true, .text_events = true };
    ui = begin(.{ .draw = &list, .state = &state, .input = &input_frame, .fonts = &fonts, .gui_tex = &texture, .glyphs_tex = &texture, .screen = screen });
    column = ui.stack(.{});
    try std.testing.expect(ui.button(1, "Test", .{}));
    column.end();
    ui.end();
}
