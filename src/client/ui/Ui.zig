const std = @import("std");
const assert = std.debug.assert;
const ae = @import("aether");
const Rendering = ae.Rendering;
const input_api = ae.Core.input;
const log = std.log.scoped(.ui);

const core = @import("core");
const layout_mod = ae.UI.layout;
const texture_region = ae.UI.texture_region;
const widget_style = @import("WidgetStyle.zig");
const prompt_strip = @import("PromptStrip.zig");
const prompts_mod = @import("Prompts.zig");
const ui_input = @import("input.zig");
const widget_id = @import("widget_id.zig");
const FontBatcher = ae.UI.FontBatcher;
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

pub const Axis = enum { horizontal, vertical };
pub const CrossAlign = enum { start, center, end, stretch };

pub const Size = union(enum) {
    fixed: i16,
    content,
    fill,
};

pub const Box = struct {
    width: Size = .content,
    height: Size = .content,
    min_w: i16 = 0,
    min_h: i16 = 0,
    max_w: i16 = std.math.maxInt(i16),
    max_h: i16 = std.math.maxInt(i16),
};

pub const Padding = struct {
    left: i16 = 0,
    right: i16 = 0,
    top: i16 = 0,
    bottom: i16 = 0,

    pub fn all(amount: i16) Padding {
        return .{ .left = amount, .right = amount, .top = amount, .bottom = amount };
    }

    pub fn xy(x: i16, y: i16) Padding {
        return .{ .left = x, .right = x, .top = y, .bottom = y };
    }

    pub fn horizontal(self: Padding) i16 {
        return self.left + self.right;
    }

    pub fn vertical(self: Padding) i16 {
        return self.top + self.bottom;
    }
};

const Ui = @This();

pub const MAX_DEPTH: u8 = 8;
pub const MAX_ITEMS: u8 = 96;
pub const MAX_FOCUSABLES: u8 = UiState.MAX_FOCUSABLES;
pub const LABEL_ARENA: u16 = 1536;

draw: *UiDrawList,
state: *UiState,
input: *const UiInput,
fonts: *const FontBatcher,
gui_tex: *const Rendering.Texture,
glyphs_tex: *const Rendering.Texture,
layer_base: u8 = 0,
screen: LogicalRect,

scopes: [MAX_DEPTH]Scope = undefined,
depth: u8 = 0,
items: [MAX_ITEMS]Item = undefined,
item_count: u8 = 0,

focusables: [MAX_FOCUSABLES]UiState.Focusable = undefined,
focus_count: u8 = 0,
scroll_views: [UiState.MAX_SCROLLS]UiState.ScrollView = undefined,
scroll_view_count: u8 = 0,

label_buf: [LABEL_ARENA]u8 = undefined,
label_used: u16 = 0,

claimed_confirm: bool = false,
claimed_click: bool = false,
cancel_consumed: bool = false,
close_requested: bool = false,

const Item = struct {
    draw_start: u16,
    draw_end: u16,
    focus_start: u8,
    focus_end: u8,
    scroll_start: u8,
    scroll_end: u8,
    rect: LogicalRect,
};

const Scope = struct {
    axis: Axis,
    anchor: Anchor,
    cross_align: CrossAlign,
    gap: i16,
    padding: Padding,
    box: Box,
    overlay_mode: bool,
    scroll_clip: ?UiState.ScrollClip,

    cursor_main: i16,
    max_cross: i16,
    children: u16,
    draw_start: u16,
    focus_start: u8,
    scroll_start: u8,
    item_start: u8,
    item_indices: [MAX_ITEMS]u8,
    item_count: u8,
    reserved_rect: ?LogicalRect,
    origin_override: ?Point,
    is_scroll: bool,
    scroll_id: WidgetId,
    scroll_wheel_step: i16,
    size: Point,
    origin: Point,
};

pub const ScopeHandle = struct {
    ui: *Ui,
    pub fn end(self: ScopeHandle) void {
        self.ui.pop_scope();
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
    var self: Ui = .{
        .draw = args.draw,
        .state = args.state,
        .input = args.input,
        .fonts = args.fonts,
        .gui_tex = args.gui_tex,
        .glyphs_tex = args.glyphs_tex,
        .layer_base = args.layer_base,
        .screen = args.screen,
    };
    self.scopes[0] = .{
        .axis = .vertical,
        .anchor = .top_left,
        .cross_align = .start,
        .gap = 0,
        .padding = .{},
        .box = .{ .width = .fill, .height = .fill },
        .overlay_mode = true,
        .scroll_clip = null,
        .cursor_main = 0,
        .max_cross = 0,
        .children = 0,
        .draw_start = self.draw.count,
        .focus_start = 0,
        .scroll_start = 0,
        .item_start = 0,
        .item_indices = undefined,
        .item_count = 0,
        .reserved_rect = self.screen,
        .origin_override = .{ .x = self.screen.x0, .y = self.screen.y0 },
        .is_scroll = false,
        .scroll_id = widget_id.raw(0),
        .scroll_wheel_step = 0,
        .size = .{ .x = self.screen.width(), .y = self.screen.height() },
        .origin = .{ .x = self.screen.x0, .y = self.screen.y0 },
    };
    self.depth = 1;
    self.route_pre_frame();
    return self;
}

fn input_system(self: *const Ui) ?*input_api.InputSystem {
    return self.input.input_system;
}

/// End the engine session alongside the UI-side field state. Aether permits
/// only one non-terminal text session, so clearing just `UiState.active_text`
/// leaves the next pointer-selected field unable to begin editing.
fn cancel_active_text(self: *Ui) void {
    if (self.state.active_text != null) {
        if (self.input_system()) |sys| {
            if (sys.current_text_session()) |session| {
                if (!session.is_terminal()) sys.cancel_text() catch {};
            }
        }
    }
    self.state.cancel_active_text();
}

pub fn end(self: *Ui) void {
    assert(self.depth == 1);

    self.state.focusable_count = self.focus_count;
    var i: u8 = 0;
    while (i < self.focus_count) : (i += 1) self.state.focusables[i] = self.focusables[i];

    self.state.scroll_view_count = self.scroll_view_count;
    i = 0;
    while (i < self.scroll_view_count) : (i += 1) self.state.scroll_views[i] = self.scroll_views[i];

    if (self.state.focused) |id| {
        if (self.find_current_visible_id(id) == null) self.state.focused = null;
    }
    if (self.state.hovered) |id| {
        if (self.find_current_visible_id(id) == null) self.state.hovered = null;
    }
    if (self.state.active_text) |id| {
        if (self.find_current_visible_id(id) == null) self.cancel_active_text();
    }
    if (self.state.captured) |id| {
        if (self.find_current_visible_id(id) == null) {
            self.state.captured = null;
            self.state.captured_via_click = false;
        }
    }
    if (self.state.focus_source == .pad and self.state.focused == null) {
        if (first_visible_focusable_idx(self.focusables[0..self.focus_count])) |idx| {
            self.state.focused = self.focusables[idx].id;
        }
    }
    self.depth = 0;
}

pub const StackOpts = struct {
    axis: Axis = .vertical,
    anchor: Anchor = .middle_center,
    cross_align: CrossAlign = .center,
    gap: i16 = 0,
    padding: Padding = .{},
    box: Box = .{},
};

pub fn stack(self: *Ui, opts: StackOpts) ScopeHandle {
    self.push_scope(.{
        .axis = opts.axis,
        .anchor = opts.anchor,
        .cross_align = opts.cross_align,
        .gap = opts.gap,
        .padding = opts.padding,
        .box = opts.box,
        .overlay_mode = false,
        .scroll_clip = self.current_scroll_clip(),
    });
    return .{ .ui = self };
}

pub fn label(self: *Ui, text: []const u8) void {
    const draw_start = self.draw.count;
    const focus_start = self.focus_count;
    const scroll_start = self.scroll_view_count;
    const w = if (text.len == 0) 0 else self.fonts.string_width(text, 0, 1);
    const rect = self.alloc_rect(.{ .x = w, .y = if (text.len == 0) 0 else 8 });
    if (text.len > 0) {
        self.draw.add_text(&.{
            .str = self.persist(text),
            .pos_x = rect.x0,
            .pos_y = rect.y0,
            .color = Colors.white_fg,
            .shadow_color = Colors.menu_gray,
            .spacing = 0,
            .layer = self.layer_base + 3,
            .reference = .top_left,
            .origin = .top_left,
        });
    }
    self.record_child(draw_start, self.draw.count, focus_start, self.focus_count, scroll_start, self.scroll_view_count, rect);
}

pub fn spacer(self: *Ui, w: i16, h: i16) void {
    const draw_start = self.draw.count;
    const focus_start = self.focus_count;
    const scroll_start = self.scroll_view_count;
    const rect = self.alloc_rect(.{ .x = w, .y = h });
    self.record_child(draw_start, self.draw.count, focus_start, self.focus_count, scroll_start, self.scroll_view_count, rect);
}

pub const ButtonOpts = struct {
    width: i16 = 200,
    height: i16 = 20,
    enabled: bool = true,
    style: *const ButtonStyle = &ButtonStyle.classic,
};

pub fn button(self: *Ui, id: WidgetId, text: []const u8, opts: ButtonOpts) bool {
    const draw_start = self.draw.count;
    const focus_start = self.focus_count;
    const scroll_start = self.scroll_view_count;
    const rect = self.alloc_rect(.{ .x = opts.width, .y = opts.height });
    if (opts.enabled) self.push_focusable(.{ .id = id, .kind = .button, .rect = rect, .enabled = true });

    const focused = opts.enabled and self.state_focused_eq(id);
    const hovered = opts.enabled and self.state_hovered_eq(id);
    draw_button(self, rect, text, focused or hovered, opts);
    self.record_child(draw_start, self.draw.count, focus_start, self.focus_count, scroll_start, self.scroll_view_count, rect);

    if (!opts.enabled) return false;
    if (self.input.click_edge and self.state_hovered_eq(id) and !self.claimed_click) {
        self.claimed_click = true;
        self.state.focused = id;
        self.state.focus_source = .mouse;
        self.cancel_active_text();
        self.state.captured = null;
        self.state.captured_via_click = false;
        return true;
    }
    if (self.input.confirm_edge and self.state_focused_eq(id) and !self.claimed_confirm) {
        self.claimed_confirm = true;
        self.cancel_active_text();
        self.state.captured = null;
        self.state.captured_via_click = false;
        return true;
    }
    return false;
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
    const draw_start = self.draw.count;
    const focus_start = self.focus_count;
    const scroll_start = self.scroll_view_count;
    const rect = self.alloc_rect(.{ .x = opts.width, .y = opts.height });
    self.push_focusable(.{ .id = id, .kind = .slider, .rect = rect });

    var changed = false;
    if (self.input.click_edge and self.state_hovered_eq(id) and !self.claimed_click) {
        self.claimed_click = true;
        self.state.focused = id;
        self.state.focus_source = .mouse;
        self.cancel_active_text();
        self.state.captured = id;
        self.state.captured_via_click = true;
        changed = self.set_slider_from_cursor(id, value, opts);
    } else if (self.state.captured != null and self.state.captured.? == id) {
        if (self.state.captured_via_click) {
            if (self.input.cursor_available) {
                if (self.input.click_held) {
                    changed = self.set_slider_from_cursor(id, value, opts);
                } else {
                    self.state.captured = null;
                    self.state.captured_via_click = false;
                }
            }
        } else if (self.input.nav == .left or self.input.nav == .right) {
            changed = nudge_slider_value(value, opts, self.input.nav);
        }
    } else if (self.input.confirm_edge and self.state_focused_eq(id) and !self.claimed_confirm) {
        self.claimed_confirm = true;
        self.state.focus_source = .pad;
        self.state.captured = id;
        self.state.captured_via_click = false;
    }

    const focused = self.state_focused_eq(id) or self.state_hovered_eq(id);
    draw_slider(self, rect, id, value.*, opts, focused);
    self.record_child(draw_start, self.draw.count, focus_start, self.focus_count, scroll_start, self.scroll_view_count, rect);
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

pub fn text_field(self: *Ui, id: WidgetId, buf: *TextBuf, opts: TextOpts) TextEvent {
    const draw_start = self.draw.count;
    const focus_start = self.focus_count;
    const scroll_start = self.scroll_view_count;
    const rect = self.alloc_rect(.{ .x = opts.width, .y = opts.height });
    self.push_focusable(.{ .id = id, .kind = .text_field, .rect = rect });

    var event: TextEvent = .none;
    if (self.input.click_edge and self.state_hovered_eq(id) and !self.claimed_click) {
        self.claimed_click = true;
        self.state.focused = id;
        self.state.focus_source = .mouse;
        self.state.captured = null;
        self.state.captured_via_click = false;
        if (uses_modal_text_input()) {
            if (self.fire_modal_text_input(id, buf, opts)) event = .changed;
        } else {
            self.set_active_text(id, buf, opts);
        }
    }
    if (self.state_active_text_eq(id) and self.state.text_session_started and self.text_submit_edge() and !self.claimed_confirm) {
        self.claimed_confirm = true;
        if (self.input_system()) |sys| sys.submit_text() catch {};
    } else if (self.input.confirm_edge and self.state_focused_eq(id) and !self.claimed_confirm and !self.state_active_text_eq(id)) {
        self.claimed_confirm = true;
        self.state.focus_source = .pad;
        if (uses_modal_text_input()) {
            if (self.fire_modal_text_input(id, buf, opts)) event = .changed;
        } else {
            self.set_active_text(id, buf, opts);
        }
    }
    const sync = self.sync_session_to_field(id, buf);
    if (sync == .submit) event = .submit else if (sync == .changed and event == .none) event = .changed;

    draw_textfield(self, rect, id, buf, opts);
    self.record_child(draw_start, self.draw.count, focus_start, self.focus_count, scroll_start, self.scroll_view_count, rect);
    return event;
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
    const draw_start = self.draw.count;
    const focus_start = self.focus_count;
    const scroll_start = self.scroll_view_count;
    const size = slot_grid_size(opts);
    const rect = self.alloc_rect(size);
    if (opts.interactive) self.push_focusable(.{ .id = id, .kind = .slot_grid, .rect = rect });

    var activated: ?u8 = null;
    if (opts.interactive and self.input.cursor_moved and self.state_hovered_eq(id)) {
        _ = self.snap_slot_to_cursor(id, opts);
    }
    if (opts.interactive and self.state_focused_eq(id) and self.input.nav != .none) {
        nudge_slot(opts, self.input.nav);
    }
    if (opts.interactive and self.input.click_edge and self.state_hovered_eq(id) and !self.claimed_click) {
        self.claimed_click = true;
        self.state.focused = id;
        self.state.focus_source = .mouse;
        if (self.snap_slot_to_cursor(id, opts)) activated = opts.cursor.*;
    }
    if (opts.interactive and self.input.confirm_edge and self.state_focused_eq(id) and !self.claimed_confirm) {
        self.claimed_confirm = true;
        if (slot_valid(opts, opts.cursor.*)) activated = opts.cursor.*;
    }

    draw_slot_grid(self, rect, opts);
    self.record_child(draw_start, self.draw.count, focus_start, self.focus_count, scroll_start, self.scroll_view_count, rect);
    return activated;
}

pub const ScrollListOpts = struct {
    width: i16,
    height: i16,
    gap: i16 = 0,
    padding: Padding = .{},
    cross_align: CrossAlign = .center,
    wheel_step: i16 = 22,
};

pub fn scroll_list(self: *Ui, id: WidgetId, opts: ScrollListOpts) ScopeHandle {
    const parent = &self.scopes[self.depth - 1];
    const rect = self.reserve_rect(parent, .{ .x = opts.width, .y = opts.height });
    const scroll_y = self.state.scroll_y(id);
    const clip: LogicalRect = .{
        .x0 = 0,
        .y0 = scroll_y,
        .x1 = opts.width,
        .y1 = scroll_y + opts.height,
    };
    self.push_scope(.{
        .axis = .vertical,
        .anchor = .top_left,
        .cross_align = opts.cross_align,
        .gap = opts.gap,
        .padding = opts.padding,
        .box = .{},
        .overlay_mode = false,
        .scroll_clip = .{ .list_id = id, .viewport = clip },
        .reserved_rect = rect,
        .origin_override = .{ .x = rect.x0, .y = rect.y0 - scroll_y },
        .is_scroll = true,
        .scroll_id = id,
        .scroll_wheel_step = opts.wheel_step,
    });
    self.draw.push_clip(clip);
    return .{ .ui = self };
}

pub fn prompts(self: *Ui, list: []const Prompt) void {
    prompt_strip.draw_into(
        self.draw,
        self.glyphs_tex,
        self.fonts,
        list,
        .bottom_left,
        prompt_strip.DEFAULT_POS_X,
        prompt_strip.DEFAULT_POS_Y,
        self.layer_base + 2,
        self.layer_base + 3,
    );
}

pub fn contextual_prompts(self: *Ui) void {
    if (self.state.captured) |id| {
        if (self.current_focusable_kind(id)) |kind| {
            if (kind == .slider) {
                self.prompts(&.{ prompts_mod.left_right(), prompts_mod.exit_adjust() });
                return;
            }
        }
    }
    if (self.state.active_text) |id| {
        if (self.current_focusable_kind(id)) |kind| {
            if (kind == .text_field) {
                self.prompts(&.{ prompts_mod.done(), prompts_mod.cancel() });
                return;
            }
        }
    }

    const kind = self.prompt_focusable_kind() orelse {
        self.prompts(&.{ prompts_mod.select(), prompts_mod.back() });
        return;
    };
    switch (kind) {
        .text_field => self.prompts(&.{ prompts_mod.edit(), prompts_mod.back() }),
        .slider => self.prompts(&.{ prompts_mod.adjust(), prompts_mod.back() }),
        else => self.prompts(&.{ prompts_mod.select(), prompts_mod.back() }),
    }
}

pub fn cancel_pressed(self: *const Ui) bool {
    return self.input.cancel_edge and !self.cancel_consumed and !self.claimed_confirm;
}

pub fn inventory_pressed(self: *const Ui) bool {
    return self.input.inventory_edge and !self.cancel_consumed and !self.claimed_confirm;
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

const ScopeInit = struct {
    axis: Axis,
    anchor: Anchor,
    cross_align: CrossAlign,
    gap: i16,
    padding: Padding,
    box: Box,
    overlay_mode: bool,
    scroll_clip: ?UiState.ScrollClip,
    reserved_rect: ?LogicalRect = null,
    origin_override: ?Point = null,
    is_scroll: bool = false,
    scroll_id: WidgetId = widget_id.raw(0),
    scroll_wheel_step: i16 = 0,
};

fn push_scope(self: *Ui, a: ScopeInit) void {
    assert(self.depth < MAX_DEPTH);
    self.scopes[self.depth] = .{
        .axis = a.axis,
        .anchor = a.anchor,
        .cross_align = a.cross_align,
        .gap = a.gap,
        .padding = a.padding,
        .box = a.box,
        .overlay_mode = a.overlay_mode,
        .scroll_clip = a.scroll_clip,
        .cursor_main = if (a.axis == .vertical) a.padding.top else a.padding.left,
        .max_cross = 0,
        .children = 0,
        .draw_start = self.draw.count,
        .focus_start = self.focus_count,
        .scroll_start = self.scroll_view_count,
        .item_start = self.item_count,
        .item_indices = undefined,
        .item_count = 0,
        .reserved_rect = a.reserved_rect,
        .origin_override = a.origin_override,
        .is_scroll = a.is_scroll,
        .scroll_id = a.scroll_id,
        .scroll_wheel_step = a.scroll_wheel_step,
        .size = .{ .x = 0, .y = 0 },
        .origin = .{ .x = 0, .y = 0 },
    };
    self.depth += 1;
}

fn pop_scope(self: *Ui) void {
    assert(self.depth > 1);
    const idx = self.depth - 1;
    var s = &self.scopes[idx];

    const main_end_pad: i16 = if (s.axis == .vertical) s.padding.bottom else s.padding.right;
    const cross_pad: i16 = if (s.axis == .vertical) s.padding.horizontal() else s.padding.vertical();
    const main: i16 = s.cursor_main + main_end_pad;
    const cross: i16 = s.max_cross + cross_pad;
    s.size = if (s.axis == .vertical)
        .{ .x = cross, .y = main }
    else
        .{ .x = main, .y = cross };
    s.size.x = resolve_dim(s.box.width, s.size.x, self.screen.width(), s.box.min_w, s.box.max_w);
    s.size.y = resolve_dim(s.box.height, s.size.y, self.screen.height(), s.box.min_h, s.box.max_h);

    self.align_scope_children(s);

    if (s.is_scroll) {
        self.draw.pop_clip();
        self.push_scroll_view(.{
            .list_id = s.scroll_id,
            .viewport = s.scroll_clip.?.viewport,
            .content_h = s.size.y,
            .wheel_step = s.scroll_wheel_step,
        });
    }

    const parent = &self.scopes[idx - 1];
    const rect: LogicalRect = if (s.reserved_rect) |r|
        r
    else if (parent.overlay_mode) blk: {
        const origin = layout_mod.place_in_parent(parent_rect(parent.*), s.size, s.anchor);
        break :blk LogicalRect{ .x0 = origin.x, .y0 = origin.y, .x1 = origin.x + s.size.x, .y1 = origin.y + s.size.y };
    } else self.reserve_rect(parent, s.size);
    s.origin = s.origin_override orelse .{ .x = rect.x0, .y = rect.y0 };

    self.draw.offset_range(s.draw_start, self.draw.count, s.origin.x, s.origin.y);
    self.offset_focus_range(s.focus_start, self.focus_count, s.origin.x, s.origin.y);
    self.offset_scroll_range(s.scroll_start, self.scroll_view_count, s.origin.x, s.origin.y);

    self.depth -= 1;
    self.record_child(s.draw_start, self.draw.count, s.focus_start, self.focus_count, s.scroll_start, self.scroll_view_count, rect);
}

fn alloc_rect(self: *Ui, sz: Point) LogicalRect {
    const s = &self.scopes[self.depth - 1];
    return self.reserve_rect(s, sz);
}

fn reserve_rect(_: *Ui, s: *Scope, sz: Point) LogicalRect {
    if (s.children > 0) s.cursor_main += s.gap;
    const rect: LogicalRect = if (s.axis == .vertical)
        .{
            .x0 = s.padding.left,
            .y0 = s.cursor_main,
            .x1 = s.padding.left + sz.x,
            .y1 = s.cursor_main + sz.y,
        }
    else
        .{
            .x0 = s.cursor_main,
            .y0 = s.padding.top,
            .x1 = s.cursor_main + sz.x,
            .y1 = s.padding.top + sz.y,
        };
    const main: i16 = if (s.axis == .vertical) sz.y else sz.x;
    const cross: i16 = if (s.axis == .vertical) sz.x else sz.y;
    s.cursor_main += main;
    if (cross > s.max_cross) s.max_cross = cross;
    s.children += 1;
    return rect;
}

fn record_child(
    self: *Ui,
    draw_start: u16,
    draw_end: u16,
    focus_start: u8,
    focus_end: u8,
    scroll_start: u8,
    scroll_end: u8,
    rect: LogicalRect,
) void {
    if (self.depth == 0) return;
    const s = &self.scopes[self.depth - 1];
    assert(self.item_count < MAX_ITEMS);
    const item_idx = self.item_count;
    self.items[item_idx] = .{
        .draw_start = draw_start,
        .draw_end = draw_end,
        .focus_start = focus_start,
        .focus_end = focus_end,
        .scroll_start = scroll_start,
        .scroll_end = scroll_end,
        .rect = rect,
    };
    s.item_indices[s.item_count] = item_idx;
    self.item_count += 1;
    s.item_count += 1;
}

fn align_scope_children(self: *Ui, s: *Scope) void {
    const content_cross: i16 = if (s.axis == .vertical)
        @max(s.size.x - s.padding.horizontal(), 0)
    else
        @max(s.size.y - s.padding.vertical(), 0);
    var i: u8 = 0;
    while (i < s.item_count) : (i += 1) {
        const item_idx = s.item_indices[i];
        var item = &self.items[item_idx];
        const child_cross: i16 = if (s.axis == .vertical) item.rect.width() else item.rect.height();
        const wanted_cross: i16 = switch (s.cross_align) {
            .start, .stretch => 0,
            .center => @divTrunc(content_cross - child_cross, 2),
            .end => content_cross - child_cross,
        };
        const wanted_pos: i16 = if (s.axis == .vertical)
            s.padding.left + wanted_cross
        else
            s.padding.top + wanted_cross;
        const cur_pos: i16 = if (s.axis == .vertical) item.rect.x0 else item.rect.y0;
        const delta = wanted_pos - cur_pos;
        if (delta == 0) continue;
        if (s.axis == .vertical) {
            self.draw.offset_range(item.draw_start, item.draw_end, delta, 0);
            self.offset_focus_range(item.focus_start, item.focus_end, delta, 0);
            self.offset_scroll_range(item.scroll_start, item.scroll_end, delta, 0);
            item.rect.x0 += delta;
            item.rect.x1 += delta;
        } else {
            self.draw.offset_range(item.draw_start, item.draw_end, 0, delta);
            self.offset_focus_range(item.focus_start, item.focus_end, 0, delta);
            self.offset_scroll_range(item.scroll_start, item.scroll_end, 0, delta);
            item.rect.y0 += delta;
            item.rect.y1 += delta;
        }
    }
}

fn resolve_dim(size: Size, intrinsic: i16, parent: i16, min: i16, max: i16) i16 {
    const raw = switch (size) {
        .fixed => |v| v,
        .content => intrinsic,
        .fill => parent,
    };
    return std.math.clamp(raw, min, max);
}

fn parent_rect(s: Scope) LogicalRect {
    if (s.reserved_rect) |r| return r;
    return .{ .x0 = s.origin.x, .y0 = s.origin.y, .x1 = s.origin.x + s.size.x, .y1 = s.origin.y + s.size.y };
}

fn push_focusable(self: *Ui, f_in: UiState.Focusable) void {
    assert(self.focus_count < MAX_FOCUSABLES);
    var f = f_in;
    if (f.scroll_clip == null) f.scroll_clip = self.current_scroll_clip();
    self.focusables[self.focus_count] = f;
    self.focus_count += 1;
}

fn push_scroll_view(self: *Ui, v: UiState.ScrollView) void {
    if (self.scroll_view_count >= UiState.MAX_SCROLLS) return;
    self.scroll_views[self.scroll_view_count] = v;
    self.scroll_view_count += 1;
}

fn current_scroll_clip(self: *const Ui) ?UiState.ScrollClip {
    if (self.depth == 0) return null;
    return self.scopes[self.depth - 1].scroll_clip;
}

fn focusable_in_clip(rect: LogicalRect, clip: ?UiState.ScrollClip) bool {
    const c = clip orelse return true;
    const v = c.viewport;
    return !(rect.x1 <= v.x0 or rect.x0 >= v.x1 or rect.y1 <= v.y0 or rect.y0 >= v.y1);
}

fn first_visible_focusable_idx(focusables: []const UiState.Focusable) ?u8 {
    var fallback: ?u8 = null;
    for (focusables, 0..) |f, i| {
        if (fallback == null) fallback = @intCast(i);
        if (focusable_in_clip(f.rect, f.scroll_clip)) return @intCast(i);
    }
    return fallback;
}

fn offset_focus_range(self: *Ui, start: u8, finish: u8, dx: i16, dy: i16) void {
    if (dx == 0 and dy == 0) return;
    var i = start;
    while (i < finish) : (i += 1) {
        self.focusables[i].rect.x0 += dx;
        self.focusables[i].rect.x1 += dx;
        self.focusables[i].rect.y0 += dy;
        self.focusables[i].rect.y1 += dy;
        if (self.focusables[i].scroll_clip) |*c| {
            c.viewport.x0 += dx;
            c.viewport.x1 += dx;
            c.viewport.y0 += dy;
            c.viewport.y1 += dy;
        }
    }
}

fn offset_scroll_range(self: *Ui, start: u8, finish: u8, dx: i16, dy: i16) void {
    if (dx == 0 and dy == 0) return;
    var i = start;
    while (i < finish) : (i += 1) {
        self.scroll_views[i].viewport.x0 += dx;
        self.scroll_views[i].viewport.x1 += dx;
        self.scroll_views[i].viewport.y0 += dy;
        self.scroll_views[i].viewport.y1 += dy;
    }
}

fn route_pre_frame(self: *Ui) void {
    if (self.input.cancel_edge and self.state.active_text != null) {
        self.cancel_active_text();
        self.cancel_consumed = true;
    }

    if (self.input.cancel_edge and self.state.captured != null and !self.cancel_consumed) {
        self.state.captured = null;
        self.state.captured_via_click = false;
        self.cancel_consumed = true;
    }

    if (self.input.cursor_available and self.input.wheel_dy != 0) {
        self.handle_wheel(self.input.cursor_x, self.input.cursor_y, self.input.wheel_dy);
    }

    const has_active_text = self.state.active_text != null;
    const refresh_pointer_pick = self.input.cursor_available and (self.input.cursor_moved or self.input.click_edge);
    var pointer_pick: ?u8 = null;
    if (refresh_pointer_pick) {
        const idx = self.pick_previous(self.input.cursor_x, self.input.cursor_y);
        pointer_pick = idx;
        self.state.hovered = if (idx) |i| self.state.focusables[i].id else null;
        if (!has_active_text) {
            if (idx) |i| {
                self.state.focused = self.state.focusables[i].id;
                self.state.focus_source = .mouse;
            } else if (self.state.focus_source == .mouse) {
                self.state.focused = null;
            }
        }
    }

    if (self.input.cursor_available and self.input.click_edge) {
        const idx = if (refresh_pointer_pick) pointer_pick else self.pick_previous(self.input.cursor_x, self.input.cursor_y);
        if (idx != null) return;
        self.cancel_active_text();
        self.state.captured = null;
        self.state.captured_via_click = false;
    }

    if (!has_active_text and self.state.captured == null and self.input.nav != .none) {
        self.state.focus_source = .pad;
        if (self.focused_previous_idx()) |idx| {
            if (self.state.focusables[idx].kind != .slot_grid) self.spatial_advance(idx, self.input.nav);
        } else if (first_visible_focusable_idx(self.state.focusables[0..self.state.focusable_count])) |idx| {
            self.state.focused = self.state.focusables[idx].id;
        }
        self.autoscroll_to_focus();
    }
}

fn handle_wheel(self: *Ui, x: i16, y: i16, wheel_dy: i8) void {
    var i: u8 = 0;
    while (i < self.state.scroll_view_count) : (i += 1) {
        const v = self.state.scroll_views[i];
        if (!v.viewport.contains(x, y)) continue;
        const cur = self.state.scroll_y(v.list_id);
        const desired: i32 = @as(i32, cur) - @as(i32, wheel_dy) * @as(i32, v.wheel_step);
        self.state.set_scroll_y(v.list_id, clamp_scroll(v, desired));
        return;
    }
}

fn clamp_scroll(v: UiState.ScrollView, desired: i32) i16 {
    const span: i32 = @as(i32, v.content_h) - @as(i32, v.viewport.height());
    const max_scroll: i32 = @max(span, 0);
    return @intCast(std.math.clamp(desired, 0, max_scroll));
}

fn pick_previous(self: *const Ui, x: i16, y: i16) ?u8 {
    var i: u8 = 0;
    while (i < self.state.focusable_count) : (i += 1) {
        const f = self.state.focusables[i];
        if (!f.enabled or !f.rect.contains(x, y)) continue;
        if (f.scroll_clip) |c| {
            if (!c.viewport.contains(x, y)) continue;
        }
        return i;
    }
    return null;
}

fn find_previous_id(self: *const Ui, id: WidgetId) ?u8 {
    var i: u8 = 0;
    while (i < self.state.focusable_count) : (i += 1) {
        if (self.state.focusables[i].id == id) return i;
    }
    return null;
}

fn focused_previous_idx(self: *const Ui) ?u8 {
    const id = self.state.focused orelse return null;
    return self.find_previous_id(id);
}

fn find_current_id(self: *const Ui, id: WidgetId) ?u8 {
    var i: u8 = 0;
    while (i < self.focus_count) : (i += 1) {
        if (self.focusables[i].id == id) return i;
    }
    return null;
}

fn find_current_visible_id(self: *const Ui, id: WidgetId) ?u8 {
    const idx = self.find_current_id(id) orelse return null;
    const f = self.focusables[idx];
    if (!focusable_in_clip(f.rect, f.scroll_clip)) return null;
    return idx;
}

fn current_focusable_kind(self: *const Ui, id: WidgetId) ?UiState.FocusableKind {
    const idx = self.find_current_id(id) orelse return null;
    return self.focusables[idx].kind;
}

fn prompt_focusable_kind(self: *const Ui) ?UiState.FocusableKind {
    if (self.state.focused) |id| return self.current_focusable_kind(id);
    if (self.state.focus_source == .pad) {
        if (first_visible_focusable_idx(self.focusables[0..self.focus_count])) |idx| return self.focusables[idx].kind;
    }
    return null;
}

fn spatial_advance(self: *Ui, from_idx: u8, dir: ui_input.NavDir) void {
    if (dir == .none) return;
    const cur_focus = &self.state.focusables[from_idx];
    const cur = cur_focus.rect;
    const cur_cx: i32 = (@as(i32, cur.x0) + @as(i32, cur.x1)) >> 1;
    const cur_cy: i32 = (@as(i32, cur.y0) + @as(i32, cur.y1)) >> 1;

    var best: ?u8 = null;
    var best_score: i64 = std.math.maxInt(i64);
    var i: u8 = 0;
    while (i < self.state.focusable_count) : (i += 1) {
        if (i == from_idx) continue;
        if (!nav_candidate_visible(cur_focus, &self.state.focusables[i])) continue;
        const r = self.state.focusables[i].rect;
        const cx: i32 = (@as(i32, r.x0) + @as(i32, r.x1)) >> 1;
        const cy: i32 = (@as(i32, r.y0) + @as(i32, r.y1)) >> 1;
        const dx: i32 = cx - cur_cx;
        const dy: i32 = cy - cur_cy;
        switch (dir) {
            .up => if (dy >= 0) continue,
            .down => if (dy <= 0) continue,
            .left => if (dx >= 0) continue,
            .right => if (dx <= 0) continue,
            .none => return,
        }
        const overlaps: bool = switch (dir) {
            .up, .down => !(r.x0 >= cur.x1 or r.x1 <= cur.x0),
            .left, .right => !(r.y0 >= cur.y1 or r.y1 <= cur.y0),
            .none => false,
        };
        const primary: i32 = switch (dir) {
            .up, .down => @intCast(@abs(dy)),
            .left, .right => @intCast(@abs(dx)),
            .none => 0,
        };
        const secondary: i32 = switch (dir) {
            .up, .down => @intCast(@abs(dx)),
            .left, .right => @intCast(@abs(dy)),
            .none => 0,
        };
        const score = (if (overlaps) @as(i64, 0) else 1_000_000_000) + @as(i64, primary) * 1_000 + @as(i64, secondary);
        if (score < best_score) {
            best_score = score;
            best = i;
        }
    }
    if (best) |b| self.state.focused = self.state.focusables[b].id;
}

fn nav_candidate_visible(cur: *const UiState.Focusable, candidate: *const UiState.Focusable) bool {
    if (focusable_in_clip(candidate.rect, candidate.scroll_clip)) return true;
    const cur_clip = cur.scroll_clip orelse return false;
    const candidate_clip = candidate.scroll_clip orelse return false;
    return cur_clip.list_id == candidate_clip.list_id;
}

fn autoscroll_to_focus(self: *Ui) void {
    const fid = self.state.focused orelse return;
    const idx = self.find_previous_id(fid) orelse return;
    const f = self.state.focusables[idx];
    const clip = f.scroll_clip orelse return;
    var delta: i16 = 0;
    if (f.rect.y0 < clip.viewport.y0) {
        delta = f.rect.y0 - clip.viewport.y0;
    } else if (f.rect.y1 > clip.viewport.y1) {
        delta = f.rect.y1 - clip.viewport.y1;
    } else return;
    var i: u8 = 0;
    while (i < self.state.scroll_view_count) : (i += 1) {
        const v = self.state.scroll_views[i];
        if (v.list_id != clip.list_id) continue;
        self.state.set_scroll_y(v.list_id, clamp_scroll(v, @as(i32, self.state.scroll_y(v.list_id)) + delta));
        return;
    }
}

fn state_focused_eq(self: *const Ui, id: WidgetId) bool {
    const f = self.state.focused orelse return false;
    return f == id;
}

fn state_hovered_eq(self: *const Ui, id: WidgetId) bool {
    const h = self.state.hovered orelse return false;
    return h == id;
}

fn state_active_text_eq(self: *const Ui, id: WidgetId) bool {
    const a = self.state.active_text orelse return false;
    return a == id;
}

fn persist(self: *Ui, text: []const u8) []const u8 {
    if (self.label_used + text.len > self.label_buf.len) return text;
    const dst = self.label_buf[self.label_used .. self.label_used + text.len];
    @memcpy(dst, text);
    self.label_used += @intCast(text.len);
    return dst;
}

fn slider_pos_from_value(value: f32, opts: SliderOpts) f32 {
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

fn set_slider_from_cursor(self: *Ui, id: WidgetId, value: *f32, opts: SliderOpts) bool {
    const idx = self.find_previous_id(id) orelse return false;
    const rect = self.state.focusables[idx].rect;
    const usable: i32 = @as(i32, rect.width()) - @as(i32, opts.style.knob_w);
    if (usable <= 0) return false;
    const rel = std.math.clamp(
        @as(i32, self.input.cursor_x) - @as(i32, rect.x0) - @divTrunc(@as(i32, opts.style.knob_w), 2),
        0,
        usable,
    );
    const pos = @as(f32, @floatFromInt(rel)) / @as(f32, @floatFromInt(usable));
    const new_value = slider_value_from_pos(opts, pos);
    if (new_value == value.*) return false;
    value.* = new_value;
    return true;
}

fn nudge_slider_value(value: *f32, opts: SliderOpts, dir: ui_input.NavDir) bool {
    const step: f32 = if (opts.nudge != 0) opts.nudge else 0.05;
    const sign: f32 = if (dir == .right) 1.0 else -1.0;
    const new_value = slider_value_from_pos(opts, slider_pos_from_value(value.*, opts) + sign * step);
    if (new_value == value.*) return false;
    value.* = new_value;
    return true;
}

fn set_active_text(self: *Ui, id: WidgetId, buf: *TextBuf, opts: TextOpts) void {
    if (self.state.active_text != null and self.state.active_text.? == id and self.state.text_session_started) return;
    self.cancel_active_text();
    self.state.active_text = id;
    self.state.text_session_started = false;
    if (uses_modal_text_input()) return;

    const target: input_api.TextInputTarget = .{ .id = opts.session_id };
    const input_opts: input_api.TextInputOptions = .{
        .max_bytes = buf.max,
        .initial = if (buf.len.* > 0) buf.bytes[0..buf.len.*] else null,
    };
    const sys = self.input_system() orelse {
        self.finish_active_text();
        return;
    };
    // A screen can be replaced outside this UI pass. Recover from any
    // orphaned non-terminal session before claiming this field.
    if (sys.current_text_session()) |session| {
        if (!session.is_terminal()) sys.cancel_text() catch {};
    }
    _ = sys.begin_text_input(&target, &input_opts) catch {
        self.finish_active_text();
        return;
    };
    self.state.text_session_started = true;
}

fn uses_modal_text_input() bool {
    return switch (ae.platform) {
        .psp, .nintendo_3ds, .nintendo_switch => true,
        else => false,
    };
}

fn fire_modal_text_input(self: *Ui, id: WidgetId, buf: *TextBuf, opts: TextOpts) bool {
    const sys = self.input_system() orelse return false;
    if (sys.current_text_session()) |s| {
        if (!s.is_terminal()) sys.cancel_text() catch {};
    }
    const target: input_api.TextInputTarget = .{ .id = opts.session_id };
    const input_opts: input_api.TextInputOptions = .{
        .max_bytes = buf.max,
        .initial = if (buf.len.* > 0) buf.bytes[0..buf.len.*] else null,
    };
    _ = sys.begin_text_input(&target, &input_opts) catch |err| {
        log.warn("modal text input '{s}' failed to open: {}", .{ opts.session_id, err });
        return false;
    };
    self.state.active_text = id;
    self.state.text_session_started = false;
    const session = sys.current_text_session() orelse {
        log.warn("modal text input '{s}' produced no session", .{opts.session_id});
        self.finish_active_text();
        return false;
    };
    if (session.status != .submitted) {
        if (session.status != .cancelled) {
            log.warn("modal text input '{s}' returned non-terminal status {s}", .{ opts.session_id, @tagName(session.status) });
        }
        if (!session.is_terminal()) sys.cancel_text() catch {};
        self.finish_active_text();
        return false;
    }
    const changed = copy_session_to_buf(session.buffer.items, buf);
    self.finish_active_text();
    return changed;
}

fn sync_session_to_field(self: *Ui, id: WidgetId, buf: *TextBuf) TextEvent {
    if (self.state.active_text == null or self.state.active_text.? != id or !self.state.text_session_started) return .none;
    const sys = self.input_system() orelse return .none;
    const session = sys.current_text_session() orelse return .none;
    self.apply_text_session_events(session);
    if (session.status == .submitted) {
        _ = copy_session_to_buf(session.buffer.items, buf);
        self.finish_active_text();
        return .submit;
    }
    if (session.status == .cancelled) {
        self.finish_active_text();
        return .none;
    }
    return if (copy_session_to_buf(session.buffer.items, buf)) .changed else .none;
}

fn apply_text_session_events(self: *Ui, session_const: *const input_api.TextInputSession) void {
    if (!self.input.text_events or session_const.status != .active) return;
    const sys = self.input_system() orelse return;
    const session: *input_api.TextInputSession = @constCast(session_const);
    for (sys.frame_events()) |ev| {
        switch (ev.kind) {
            .key_down => |k| {
                if (k.key == .Backspace) pop_text_codepoint(session);
            },
            else => {},
        }
    }
}

fn text_submit_edge(self: *const Ui) bool {
    if (!self.input.text_events) return false;
    const sys = self.input_system() orelse return false;
    for (sys.frame_events()) |ev| {
        switch (ev.kind) {
            .key_down => |k| {
                if (k.key == .Enter) return true;
            },
            .gamepad_button_down => |b| {
                if (b.button == .A) return true;
            },
            else => {},
        }
    }
    return false;
}

fn pop_text_codepoint(session: *input_api.TextInputSession) void {
    if (session.buffer.items.len == 0) return;
    var start = session.buffer.items.len - 1;
    while (start > 0 and (session.buffer.items[start] & 0b1100_0000) == 0b1000_0000) {
        start -= 1;
    }
    session.buffer.items.len = start;
}

fn finish_active_text(self: *Ui) void {
    self.state.active_text = null;
    self.state.text_session_started = false;
}

fn copy_session_to_buf(items: []const u8, buf: *TextBuf) bool {
    const take = @min(items.len, @as(usize, buf.max));
    const old = buf.bytes[0..buf.len.*];
    const changed = old.len != take or !std.mem.eql(u8, old, items[0..take]);
    if (take > 0) std.mem.copyForwards(u8, buf.bytes[0..take], items[0..take]);
    buf.len.* = @intCast(take);
    return changed;
}

test "pointer text-field transitions release the prior text session" {
    var sys: input_api.InputSystem = .{};
    try sys.init(std.testing.allocator);
    defer sys.deinit();

    var state: UiState = .{};
    var in: UiInput = .{
        .input_system = &sys,
        .cursor_x = 0,
        .cursor_y = 0,
        .cursor_available = false,
        .cursor_moved = false,
        .click_edge = false,
        .click_held = false,
        .nav = .none,
        .confirm_edge = false,
        .cancel_edge = false,
        .pause_edge = false,
        .title_exit_edge = false,
        .inventory_edge = false,
        .wheel_dy = 0,
        .text_events = true,
    };
    var ui: Ui = undefined;
    ui.state = &state;
    ui.input = &in;

    var first_bytes: [8]u8 = undefined;
    var first_len: u8 = 0;
    var first: TextBuf = .{ .bytes = &first_bytes, .len = &first_len, .max = first_bytes.len };
    const first_id = widget_id.raw(1);
    ui.set_active_text(first_id, &first, .{ .session_id = "first" });
    try std.testing.expectEqual(first_id, state.active_text.?);
    try std.testing.expectEqualStrings("first", sys.current_text_session().?.target.id);

    // A screen transition can clear its local state before its next UI pass.
    // Starting another field must recover from that orphaned Aether session.
    state.cancel_active_text();
    var second_bytes: [8]u8 = undefined;
    var second_len: u8 = 0;
    var second: TextBuf = .{ .bytes = &second_bytes, .len = &second_len, .max = second_bytes.len };
    const second_id = widget_id.raw(2);
    ui.set_active_text(second_id, &second, .{ .session_id = "second" });

    try std.testing.expectEqual(second_id, state.active_text.?);
    const session = sys.current_text_session().?;
    try std.testing.expectEqual(input_api.TextInputStatus.active, session.status);
    try std.testing.expectEqualStrings("second", session.target.id);

    // An outside click must end the Aether session as well as local UI focus,
    // so a subsequent click-to-type field can start normally.
    in.cursor_available = true;
    in.click_edge = true;
    ui.route_pre_frame();
    try std.testing.expect(state.active_text == null);
    try std.testing.expectEqual(input_api.TextInputStatus.cancelled, sys.current_text_session().?.status);

    in.cursor_available = false;
    in.click_edge = false;
    const third_id = widget_id.raw(3);
    ui.set_active_text(third_id, &first, .{ .session_id = "third" });
    try std.testing.expectEqual(third_id, state.active_text.?);
    try std.testing.expectEqualStrings("third", sys.current_text_session().?.target.id);
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

fn cell_at(opts: SlotGridOpts, inner: LogicalRect, x: i16, y: i16) ?u8 {
    if (x < inner.x0 or y < inner.y0 or x >= inner.x1 or y >= inner.y1) return null;
    const col_i = @divTrunc(x - inner.x0, opts.cell);
    const row_i = @divTrunc(y - inner.y0, opts.cell);
    if (col_i < 0 or col_i >= @as(i16, @intCast(opts.cols))) return null;
    if (row_i < 0 or row_i >= @as(i16, @intCast(opts.rows))) return null;
    return @intCast(row_i * @as(i16, @intCast(opts.cols)) + col_i);
}

fn snap_slot_to_cursor(self: *Ui, id: WidgetId, opts: SlotGridOpts) bool {
    const idx = self.find_previous_id(id) orelse return false;
    const inner = slot_grid_inner_rect(opts, self.state.focusables[idx].rect);
    const slot = cell_at(opts, inner, self.input.cursor_x, self.input.cursor_y) orelse return false;
    if (!slot_valid(opts, slot)) return false;
    opts.cursor.* = slot;
    return true;
}

fn nudge_slot(opts: SlotGridOpts, dir: ui_input.NavDir) void {
    const cols: i16 = @intCast(opts.cols);
    const capacity: i16 = cols * @as(i16, @intCast(opts.rows));
    const delta: i16 = switch (dir) {
        .left => -1,
        .right => 1,
        .up => -cols,
        .down => cols,
        .none => return,
    };
    const candidate: i16 = @as(i16, opts.cursor.*) + delta;
    if (candidate < 0 or candidate >= capacity) return;
    const idx: u8 = @intCast(candidate);
    if (!slot_valid(opts, idx)) return;
    opts.cursor.* = idx;
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
    const focused = ui.state_focused_eq(id) or ui.state_hovered_eq(id);
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
