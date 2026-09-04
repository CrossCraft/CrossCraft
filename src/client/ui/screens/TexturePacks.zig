const std = @import("std");
const Ui = @import("../Ui.zig");
const Prompts = @import("../Prompts.zig");
const widget_id = @import("../widget_id.zig");
const Options = @import("../../Options.zig");

const log = std.log.scoped(.menu);

pub const WidgetId = widget_id.WidgetId;

pub const Widget = enum(u16) {
    done = 1,
    list = 2,
    _,
};

pub const Result = union(enum) {
    none,
    done,
    select: u8,
};

pub fn wid(w: Widget) WidgetId {
    return widget_id.from(Widget, w);
}

pub const max_packs: u8 = 12;
pub const max_path_len: u8 = 96;
pub const default_path = "pack.zip";
pub const row_base: u16 = 100;

pub fn wid_for_row(i: u8) WidgetId {
    std.debug.assert(i <= max_packs);
    return widget_id.raw(row_base + @as(u16, i));
}

pub const Entry = struct {
    label_buf: [max_path_len]u8 = undefined,
    label_len: u8 = 0,
    path_buf: [max_path_len]u8 = undefined,
    path_len: u8 = 0,
    dir: std.Io.Dir = undefined,

    pub fn label(self: *const Entry) []const u8 {
        return self.label_buf[0..self.label_len];
    }

    pub fn path(self: *const Entry) []const u8 {
        return self.path_buf[0..self.path_len];
    }
};

pub fn run(ui: *Ui, entries: []const Entry, selected_index: ?u8) Result {
    var col = ui.stack(.{ .axis = .vertical, .anchor = .middle_center, .cross_align = .center, .gap = 6 });
    var result: Result = .none;

    ui.label("Select Texture Pack");
    {
        var list = ui.scroll_list(wid(.list), .{
            .width = 200,
            .height = 6 * 22 - 2,
            .gap = 2,
        });
        defer list.end();

        for (entries, 0..) |*entry, i| {
            const row: u8 = @intCast(i);
            const is_active = if (selected_index) |si| si == row else false;
            if (ui.button(wid_for_row(row), entry.label(), .{ .enabled = !is_active }) and result == .none) result = .{ .select = row };
        }
    }
    if (ui.button(wid(.done), "Done", .{}) and result == .none) result = .done;
    col.end();
    ui.prompts(&.{ Prompts.select(), Prompts.back() });
    if (result == .none and ui.cancel_pressed()) result = .done;
    return result;
}

pub fn scan(io: std.Io, default_pack_dir: std.Io.Dir, data_dir: std.Io.Dir, out: *[max_packs + 1]Entry) u8 {
    var count: u8 = 0;
    add_entry(out, &count, "Default", default_path, default_pack_dir);

    var dir = data_dir.openDir(io, "texturepacks", .{ .iterate = true }) catch |err| {
        log.warn("texturepacks/ not iterable: {}", .{err});
        return count;
    };
    defer dir.close(io);

    var iter = dir.iterate();
    while (iter.next(io) catch null) |entry| {
        if (count >= max_packs + 1) break;
        if (entry.kind != .file) continue;
        if (entry.name.len < 4) continue;
        const ext = entry.name[entry.name.len - 4 ..];
        if (!std.ascii.eqlIgnoreCase(ext, ".zip")) continue;

        var path_tmp: [max_path_len]u8 = undefined;
        const full_path = std.fmt.bufPrint(&path_tmp, "texturepacks/{s}", .{entry.name}) catch continue;
        const stem = entry.name[0 .. entry.name.len - 4];
        add_entry(out, &count, stem, full_path, data_dir);
    }
    return count;
}

fn add_entry(out: *[max_packs + 1]Entry, count: *u8, label: []const u8, path: []const u8, dir: std.Io.Dir) void {
    if (count.* >= max_packs + 1) return;
    if (label.len > max_path_len or path.len > max_path_len) return;

    var e: Entry = .{ .dir = dir };
    @memcpy(e.label_buf[0..label.len], label);
    e.label_len = @intCast(label.len);
    @memcpy(e.path_buf[0..path.len], path);
    e.path_len = @intCast(path.len);

    out[count.*] = e;
    count.* += 1;
}

pub fn find_active_index(entries: []const Entry) ?u8 {
    const saved = Options.current.active_texturepack();
    var i: u8 = 0;
    while (i < entries.len) : (i += 1) {
        const path = entries[i].path();
        const is_default_entry = std.mem.eql(u8, path, default_path);
        if (is_default_entry) {
            if (saved.len == 0) return i;
        } else if (std.mem.eql(u8, path, saved)) {
            return i;
        }
    }
    return null;
}
