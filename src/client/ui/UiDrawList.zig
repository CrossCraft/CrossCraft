//! CrossCraft artwork/block adapters around Aether's bounded command list.
const std = @import("std");
const ae = @import("aether");
const caps = @import("capabilities").ClientType(ae);
const Rendering = ae.Rendering;
const Native = ae.Ui.DrawList;
const IsoBlockDrawer = @import("IsoBlockDrawer.zig");
const Screen = @import("Screen.zig");
pub const Colors = @import("../graphics/Color.zig");
pub const Anchor = ae.Ui.Anchor;
pub const Point = ae.Ui.Point;
pub const SpriteCmd = ae.Ui.SpriteBatcher.Sprite;
pub const ElidedSpriteCmd = ae.Ui.SpriteBatcher.ElidedSprite;
pub const TextCmd = ae.Ui.FontBatcher.TextEntry;
pub const RectCmd = struct { pos_offset: Point, pos_extent: Point, color: ae.Ui.Color, layer: u8, reference: Anchor = .top_left, origin: Anchor = .top_left };
pub const IsoBlockCmd = IsoBlockDrawer.Payload;
pub const MaxCmds = caps.ui.max_draw_commands * 2;
const List = @This();
commands: [MaxCmds]Native.Command = undefined,
text: [32768]u8 = undefined,
clips: [16]ae.Ui.LogicalRect = undefined,
implementation: ?Native = null,
font: ?*const ae.Ui.FontBatcher = null,
count: usize = 0,
var placeholder_font: ae.Ui.FontBatcher = undefined;

pub fn native(self: *List) *Native {
    if (self.implementation == null) self.implementation = .{ .allocator = undefined, .commands = &self.commands, .text_buffer = &self.text, .clips = &self.clips };
    return &self.implementation.?;
}
pub fn bind_font(self: *List, font: *const ae.Ui.FontBatcher) void {
    self.font = font;
}
fn checked(self: *List, result: Native.Error!void) void {
    result catch |err| std.debug.panic("UI command failed: {s}", .{@errorName(err)});
    self.count = self.native().count;
}
pub fn add_sprite(self: *List, command: *const SpriteCmd) void {
    self.checked(self.native().add_sprite(command.*));
}
pub fn add_sprite_elided(self: *List, command: *const ElidedSpriteCmd) void {
    const screen = Screen.logical_rect();
    const ref = ae.Ui.layout.anchor_point(command.reference, screen.width(), screen.height());
    const origin = ae.Ui.layout.anchor_point(command.origin, command.dst_w, command.dst_h);
    const x = ref.x + command.pos_offset.x - origin.x;
    const y = ref.y + command.pos_offset.y - origin.y;
    self.checked(self.native().add_region(command.texture, command.region, .{ .x0 = x, .y0 = y, .x1 = x + command.dst_w, .y1 = y + command.dst_h }, command.color, command.layer, .{ .center_elide = command.sizing }));
}
pub fn add_rect(self: *List, command: *const RectCmd) void {
    const screen = Screen.logical_rect();
    const ref = ae.Ui.layout.anchor_point(command.reference, screen.width(), screen.height());
    const origin = ae.Ui.layout.anchor_point(command.origin, command.pos_extent.x, command.pos_extent.y);
    const x = ref.x + command.pos_offset.x - origin.x;
    const y = ref.y + command.pos_offset.y - origin.y;
    self.checked(self.native().add_rect(.{ .x0 = x, .y0 = y, .x1 = x + command.pos_extent.x, .y1 = y + command.pos_extent.y }, command.color, command.layer));
}
pub fn add_text(self: *List, command: *const TextCmd) void {
    self.checked(self.native().add_text(self.font orelse &placeholder_font, command.*));
}
pub fn add_iso_block(self: *List, payload: *const IsoBlockCmd) void {
    const extent = payload.half_extent_px * 2;
    const bounds: ae.Ui.LogicalRect = .{ .x0 = @intFromFloat(@floor(payload.cx - extent)), .y0 = @intFromFloat(@floor(payload.cy - extent)), .x1 = @intFromFloat(@ceil(payload.cx + extent)), .y1 = @intFromFloat(@ceil(payload.cy + extent)) };
    var local = payload.*;
    local.cx -= @floatFromInt(bounds.x0);
    local.cy -= @floatFromInt(bounds.y0);
    self.checked(self.native().add_custom(ae.Ui.CustomRenderable.Command.init(.app0, bounds, IsoBlockDrawer.IsoLayer, .reject_bounds, @intCast(self.native().count), local)));
}
pub fn push_clip(self: *List, bounds: ae.Ui.LogicalRect) void {
    self.checked(self.native().push_clip(bounds));
}
pub fn pop_clip(self: *List) void {
    self.checked(self.native().pop_clip());
}
pub fn offset_range(self: *List, first: usize, last: usize, x: i16, y: i16) void {
    self.checked(self.native().offset_range(first, last, .{ .x = x, .y = y }));
}

pub const Prepared = struct {
    allocator: std.mem.Allocator,
    registry: *ae.Ui.CustomRenderable.Registry,
    blocks: ?*IsoBlockDrawer,
    implementation: Native.Prepared,
    pub fn deinit(self: *Prepared) void {
        self.implementation.deinit();
        if (self.blocks) |blocks| {
            blocks.deinit();
            self.allocator.destroy(blocks);
        }
        self.allocator.destroy(self.registry);
        self.* = undefined;
    }
    pub fn draw(self: *Prepared) void {
        self.implementation.draw();
    }
};
pub fn prepare(self: *List, fonts: *const ae.Ui.FontBatcher, iso: ?*const IsoBlockDrawer) !Prepared {
    const allocator = fonts.allocator;
    const registry = try allocator.create(ae.Ui.CustomRenderable.Registry);
    errdefer allocator.destroy(registry);
    registry.* = .{};
    var blocks: ?*IsoBlockDrawer = null;
    errdefer if (blocks) |value| {
        value.deinit();
        allocator.destroy(value);
    };
    if (iso) |source| {
        const value = try allocator.create(IsoBlockDrawer);
        errdefer allocator.destroy(value);
        value.* = try IsoBlockDrawer.init(allocator, source.terrain, source.atlas);
        blocks = value;
        registry.register(.app0, value.renderer());
    }
    const list = self.native();
    for (list.commands[0..list.count]) |*command| if (command.value == .text) {
        command.value.text.font = fonts;
    };
    const surface = Rendering.surface_size();
    return .{ .allocator = allocator, .registry = registry, .blocks = blocks, .implementation = try list.prepare(allocator, registry, &Rendering.Texture.Default, surface.width, surface.height, ae.Ui.Scaling.compute(surface.width, surface.height)) };
}

/// Keeps GPU meshes and CPU buffers alive while a screen is displayed.
pub fn prepare_into(self: *List, output: *?Prepared, fonts: *const ae.Ui.FontBatcher, iso: ?*const IsoBlockDrawer) !void {
    if (output.*) |*prepared| {
        if (prepared.blocks) |blocks| if (iso) |source| {
            blocks.terrain = source.terrain;
            blocks.atlas = source.atlas;
        };
        const list = self.native();
        for (list.commands[0..list.count]) |*command| if (command.value == .text) {
            command.value.text.font = fonts;
        };
        const surface = Rendering.surface_size();
        try list.rebuild(&prepared.implementation, &Rendering.Texture.Default, surface.width, surface.height, ae.Ui.Scaling.compute(surface.width, surface.height));
    } else output.* = try self.prepare(fonts, iso);
}
