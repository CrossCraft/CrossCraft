const std = @import("std");
const assert = std.debug.assert;
const Ui = @import("../Ui.zig");
const Prompts = @import("../Prompts.zig");
const widget_id = @import("../widget_id.zig");

const log = std.log.scoped(.menu);

pub const WidgetId = widget_id.WidgetId;

pub const Widget = enum(u16) {
    delete_world = 1,
    create_world = 2,
    cancel = 3,
    list = 4,
    _,
};

pub const Result = union(enum) {
    none,
    cancel,
    toggle_delete,
    create,
    select: u8,
};

pub fn wid(w: Widget) WidgetId {
    return widget_id.from(Widget, w);
}

pub const max_worlds: u8 = 60;
pub const max_file_name_len: usize = 96;
pub const max_path_len: usize = 112;
pub const max_label_len: usize = 64;
pub const max_display_name_len: usize = 16;
pub const visible_rows: u8 = 5;
pub const row_base: u16 = 200;

pub fn wid_for_row(i: u8) WidgetId {
    assert(i < max_worlds);
    return widget_id.raw(row_base + @as(u16, i));
}

pub const Entry = struct {
    label_buf: [max_label_len]u8 = undefined,
    label_len: u8 = 0,
    file_name_buf: [max_file_name_len]u8 = undefined,
    file_name_len: u8 = 0,
    path_buf: [max_path_len]u8 = undefined,
    path_len: u8 = 0,
    byte_size: u64 = 0,

    pub fn label(self: *const Entry) []const u8 {
        return self.label_buf[0..self.label_len];
    }

    pub fn file_name(self: *const Entry) []const u8 {
        return self.file_name_buf[0..self.file_name_len];
    }

    pub fn path(self: *const Entry) []const u8 {
        return self.path_buf[0..self.path_len];
    }
};

pub fn run(ui: *Ui, entries: []const Entry, delete_mode: bool) Result {
    var col = ui.stack(.{ .axis = .vertical, .anchor = .middle_center, .cross_align = .center, .gap = 6 });
    var result: Result = .none;

    ui.label("Select world");
    {
        var list = ui.scroll_list(wid(.list), .{
            .width = 200,
            .height = visible_rows * 22 - 2,
            .gap = 2,
        });
        defer list.end();

        for (entries, 0..) |*entry, i| {
            const row: u8 = @intCast(i);
            if (ui.button(wid_for_row(row), entry.label(), .{}) and result == .none) result = .{ .select = row };
        }

        var empty_row: u8 = @intCast(@min(entries.len, visible_rows));
        while (empty_row < visible_rows) : (empty_row += 1) {
            if (ui.button(wid_for_row(empty_row), "- empty -", .{}) and result == .none) result = .create;
        }
    }

    ui.spacer(0, 8);
    const delete_label = if (delete_mode) "Cancel delete" else "Delete world...";
    if (ui.button(wid(.delete_world), delete_label, .{}) and result == .none) result = .toggle_delete;
    if (ui.button(wid(.create_world), "Create world", .{}) and result == .none) result = .create;
    if (ui.button(wid(.cancel), "Cancel", .{}) and result == .none) result = .cancel;
    col.end();

    ui.prompts(&.{ Prompts.select(), Prompts.back() });
    if (result == .none and ui.cancel_pressed()) result = .cancel;
    return result;
}

pub fn scan(io: std.Io, data_dir: std.Io.Dir, out: *[max_worlds]Entry) u8 {
    var count: u8 = 0;
    var dir = data_dir.openDir(io, "saves", .{ .iterate = true }) catch |err| {
        log.warn("saves/ not iterable: {}", .{err});
        return 0;
    };
    defer dir.close(io);

    var iter = dir.iterate();
    while (iter.next(io) catch null) |entry| {
        if (count >= max_worlds) break;
        if (entry.kind != .file) continue;
        if (!has_cw_ext(entry.name)) continue;

        const size = stat_file_size(io, data_dir, entry.name) orelse continue;
        add_entry(out, &count, entry.name, size);
    }

    sort_entries(out[0..count]);
    format_labels(out[0..count]);
    return count;
}

pub fn delete_entry(io: std.Io, data_dir: std.Io.Dir, entry: *const Entry) bool {
    data_dir.deleteFile(io, entry.path()) catch |err| {
        log.warn("failed to delete save '{s}': {}", .{ entry.path(), err });
        return false;
    };
    return true;
}

fn has_cw_ext(name: []const u8) bool {
    if (name.len < 3) return false;
    return std.ascii.eqlIgnoreCase(name[name.len - 3 ..], ".cw");
}

fn stat_file_size(io: std.Io, data_dir: std.Io.Dir, name: []const u8) ?u64 {
    var path_buf: [max_path_len]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "saves/{s}", .{name}) catch return null;

    // Do not open the save relative to the temporary iterable directory.
    // PSP's I/O layer tracks the base path for open directory handles in a
    // small table; once that is full, iteration still works but relative file
    // opens fail. Statting through the stable data directory avoids that
    // handle-pressure failure and does not consume another file handle.
    const st = data_dir.statFile(io, path, .{}) catch |err| {
        log.warn("failed to stat save '{s}': {}", .{ path, err });
        return null;
    };
    return st.size;
}

fn add_entry(out: *[max_worlds]Entry, count: *u8, file_name: []const u8, byte_size: u64) void {
    if (count.* >= max_worlds) return;
    if (file_name.len > max_file_name_len) return;

    var e: Entry = .{ .byte_size = byte_size };
    @memcpy(e.file_name_buf[0..file_name.len], file_name);
    e.file_name_len = @intCast(file_name.len);

    const path = std.fmt.bufPrint(&e.path_buf, "saves/{s}", .{file_name}) catch return;
    e.path_len = @intCast(path.len);

    out[count.*] = e;
    count.* += 1;
}

fn sort_entries(entries: []Entry) void {
    var i: usize = 0;
    while (i < entries.len) : (i += 1) {
        var min = i;
        var j = i + 1;
        while (j < entries.len) : (j += 1) {
            if (std.mem.lessThan(u8, entries[j].file_name(), entries[min].file_name())) min = j;
        }
        if (min != i) std.mem.swap(Entry, &entries[i], &entries[min]);
    }
}

fn format_labels(entries: []Entry) void {
    for (entries) |*entry| {
        const mb_x100 = (entry.byte_size + 5_000) / 10_000;
        const mb_whole = mb_x100 / 100;
        const mb_frac = mb_x100 % 100;
        var display_name_buf: [max_display_name_len]u8 = undefined;
        const shown_name = display_name(entry.file_name(), &display_name_buf);
        const label = std.fmt.bufPrint(
            &entry.label_buf,
            "{s} ({d}.{d:0>2} MB)",
            .{ shown_name, mb_whole, mb_frac },
        ) catch "";
        entry.label_len = @intCast(label.len);
    }
}

fn display_name(file_name: []const u8, out: *[max_display_name_len]u8) []const u8 {
    if (file_name.len <= max_display_name_len) return file_name;

    const ext_len: usize = 3;
    const stem_len = max_display_name_len - ext_len;
    @memcpy(out[0..stem_len], file_name[0..stem_len]);
    @memcpy(out[stem_len..max_display_name_len], file_name[file_name.len - ext_len ..]);
    return out[0..max_display_name_len];
}
