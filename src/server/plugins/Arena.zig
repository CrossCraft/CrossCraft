//! Bounded arena world-edit jobs, template capture, and dirty-arena recovery.
//! Fill and restore jobs run in per-tick budgets through normal world
//! bookkeeping inside a claim the owning plugin already holds. Templates and
//! dirty records persist under the plugin's UUID so a crash before or during
//! a destructive match is repaired on the next startup, even when the owning
//! plugin is missing or disabled.
const std = @import("std");
const core = @import("core");
const Server = core.Server;
const Client = Server.Client;
const world = core.World;
const blocks = core.blocks;
const Plugins = @import("Plugins.zig");
const Regions = @import("Regions.zig");
const Manifest = @import("Manifest.zig");

const log = std.log.scoped(.plugins);
const assert = std.debug.assert;

pub const max_jobs = 4;
pub const max_template_cells: u32 = 262_144;
pub const cells_per_tick: u32 = 512;

/// Set while a validated owner job writes its own claim; the mutation guard
/// lets these writes through. Only the ordered tick thread toggles it.
pub var bypass_cells: bool = false;

const Job = struct {
    plugin: *Plugins.Plugin,
    box: Regions.Box,
    block: blocks.Block,
    template: ?[]u8 = null,
    cursor: u32 = 0,
    done_ref: i32,
    active: bool = false,
};

pub fn key_is_safe(key: []const u8) bool {
    if (key.len == 0 or key.len > 16) return false;
    for (key) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
    }
    return true;
}

fn box_in_world(box: Regions.Box) bool {
    const dims = world.data.dims;
    return box.x1 < dims.length and box.y1 < dims.height and box.z1 < dims.depth;
}

fn plugin_data_path(buf: *[128]u8, comptime fmt: []const u8, args: anytype) ?[]const u8 {
    const joined = std.fmt.bufPrint(buf, "plugin-data/" ++ fmt, args) catch return null;
    return joined;
}

fn template_path(plugin: *Plugins.Plugin, key: []const u8, buf: *[128]u8) ?[]const u8 {
    var uuid_buf: [36]u8 = undefined;
    return plugin_data_path(buf, "{s}.{s}.bin", .{ plugin.uuid_text(&uuid_buf), key });
}

const DirtyRecord = struct {
    template: []const u8 = "",
    x0: u32 = 0,
    y0: u32 = 0,
    z0: u32 = 0,
    x1: u32 = 0,
    y1: u32 = 0,
    z1: u32 = 0,
    uuid: []const u8 = "",
    length: u32 = 0,
    height: u32 = 0,
    depth: u32 = 0,
};

fn cell_at(box: Regions.Box, index: u32) [3]u16 {
    assert(index < box.volume());
    const width: u32 = @as(u32, box.x1) - box.x0 + 1;
    const depth: u32 = @as(u32, box.z1) - box.z0 + 1;
    const x: u32 = box.x0 + index % width;
    const z: u32 = box.z0 + (index / width) % depth;
    const y: u32 = box.y0 + index / (width * depth);
    return .{ @intCast(x), @intCast(y), @intCast(z) };
}

pub const Registry = struct {
    jobs: [max_jobs]Job = undefined,
    count: usize = 0,

    fn slot(self: *Registry) ?*Job {
        assert(self.count <= max_jobs);
        for (self.jobs[0..self.count]) |*job| {
            if (!job.active) return job;
        }
        if (self.count == max_jobs) return null;
        self.count += 1;
        return &self.jobs[self.count - 1];
    }

    fn box_inside_owner_claim(plugin: *Plugins.Plugin, box: Regions.Box) bool {
        const min = plugin.owner.regions.find(box.x0, box.y0, box.z0) orelse return false;
        const max = plugin.owner.regions.find(box.x1, box.y1, box.z1) orelse return false;
        return min == max and min.owner == plugin;
    }

    pub fn enqueue_fill(
        self: *Registry,
        plugin: *Plugins.Plugin,
        box: Regions.Box,
        block: blocks.Block,
        done_ref: i32,
    ) ?*Job {
        assert(box.x1 >= box.x0 and box.y1 >= box.y0 and box.z1 >= box.z0);
        if (!box_in_world(box) or !box_inside_owner_claim(plugin, box)) return null;
        const job = self.slot() orelse return null;
        job.* = .{ .plugin = plugin, .box = box, .block = block, .done_ref = done_ref, .active = true };
        return job;
    }

    pub fn enqueue_restore(self: *Registry, plugin: *Plugins.Plugin, box: Regions.Box, key: []const u8, done_ref: i32) ?*Job {
        assert(box.x1 >= box.x0 and box.y1 >= box.y0 and box.z1 >= box.z0);
        if (!key_is_safe(key) or !box_in_world(box) or !box_inside_owner_claim(plugin, box)) return null;
        const volume = box.volume();
        if (volume > max_template_cells) return null;
        var path_buf: [128]u8 = undefined;
        const path = template_path(plugin, key, &path_buf) orelse return null;
        const template = read_template(plugin.owner.data_dir, path, plugin.owner.alloc, volume) orelse return null;
        const job = self.slot() orelse {
            plugin.owner.alloc.free(template);
            return null;
        };
        job.* = .{ .plugin = plugin, .box = box, .block = .air, .template = template, .done_ref = done_ref, .active = true };
        return job;
    }

    pub fn capture(self: *Registry, plugin: *Plugins.Plugin, box: Regions.Box, key: []const u8) bool {
        _ = self;
        if (!key_is_safe(key) or !box_in_world(box)) return false;
        const volume = box.volume();
        if (volume > max_template_cells) return false;
        var path_buf: [128]u8 = undefined;
        const path = template_path(plugin, key, &path_buf) orelse return false;

        const cells = plugin.owner.alloc.alloc(u8, volume) catch return false;
        defer plugin.owner.alloc.free(cells);

        world.lock_world_shared();
        var index: u32 = 0;
        while (index < volume) : (index += 1) {
            const cell = cell_at(box, index);
            cells[index] = @intFromEnum(world.data.get_block(cell[0], cell[1], cell[2]));
        }
        world.unlock_world_shared();

        plugin.owner.data_dir.writeFile(Server.io, .{ .sub_path = path, .data = cells }) catch |err| {
            log.warn("Plugin '{s}' could not persist template '{s}': {}", .{ plugin.manifest.name(), key, err });
            return false;
        };
        return true;
    }

    /// Record a dirty-arena marker referencing a captured template. Must be
    /// called before gameplay may destructively modify the claim.
    pub fn mark_dirty(self: *Registry, plugin: *Plugins.Plugin, box: Regions.Box, key: []const u8) bool {
        _ = self;
        if (!key_is_safe(key) or !box_in_world(box)) return false;

        var template_buf: [64]u8 = undefined;
        var plugin_uuid: [36]u8 = undefined;
        var world_uuid: [36]u8 = undefined;
        const template_name = std.fmt.bufPrint(&template_buf, "{s}.{s}.bin", .{
            plugin.uuid_text(&plugin_uuid), key,
        }) catch return false;

        var probe_buf: [128]u8 = undefined;
        const template_path_text = plugin_data_path(&probe_buf, "{s}", .{template_name}) orelse return false;
        const file = plugin.owner.data_dir.openFile(Server.io, template_path_text, .{}) catch return false;
        defer file.close(Server.io);

        const stat = file.stat(Server.io) catch return false;
        if (stat.size != box.volume()) return false;

        const record = DirtyRecord{
            .template = template_name,
            .x0 = box.x0,
            .y0 = box.y0,
            .z0 = box.z0,
            .x1 = box.x1,
            .y1 = box.y1,
            .z1 = box.z1,
            .uuid = format_world_uuid(&world_uuid),
            .length = world.data.dims.length,
            .height = world.data.dims.height,
            .depth = world.data.dims.depth,
        };
        var body: [512]u8 = undefined;
        var writer = std.Io.Writer.fixed(&body);
        std.json.Stringify.value(record, .{}, &writer) catch return false;

        var dirty_buf: [128]u8 = undefined;
        const dirty_path = plugin_data_path(&dirty_buf, "{s}.dirty.json", .{template_name}) orelse return false;
        plugin.owner.data_dir.writeFile(Server.io, .{ .sub_path = dirty_path, .data = writer.buffered() }) catch |err| {
            log.warn("Plugin '{s}' could not mark the arena dirty: {}", .{ plugin.manifest.name(), err });
            return false;
        };
        return true;
    }

    /// Clear the dirty marker only after the restored world state is durably
    /// saved, so a crash cannot preserve a half-destroyed arena.
    pub fn clear_dirty(self: *Registry, plugin: *Plugins.Plugin, key: []const u8) bool {
        _ = self;
        if (!key_is_safe(key)) return false;
        var dirty_buf: [128]u8 = undefined;
        var plugin_uuid: [36]u8 = undefined;
        const dirty_path = plugin_data_path(&dirty_buf, "{s}.{s}.dirty.json", .{
            plugin.uuid_text(&plugin_uuid), key,
        }) orelse return false;
        world.save();
        world.wait_for_save();
        plugin.owner.data_dir.deleteFile(Server.io, dirty_path) catch return false;
        return true;
    }

    /// Process one bounded batch per active job, then report completion.
    pub fn tick(self: *Registry, owner: *Plugins) void {
        for (self.jobs[0..self.count]) |*job| {
            if (!job.active) continue;
            const volume = job.box.volume();
            var processed: u32 = 0;
            world.lock_world();
            bypass_cells = true;
            while (job.cursor < volume and processed < cells_per_tick) : (job.cursor += 1) {
                const target: blocks.Block = if (job.template) |cells|
                    @enumFromInt(cells[job.cursor])
                else
                    job.block;
                const cell = cell_at(job.box, job.cursor);
                if (world.get_block(cell[0], cell[1], cell[2]) != target) {
                    _ = world.set_block(Server.block_change_sink, cell[0], cell[1], cell[2], target);
                }
                processed += 1;
            }
            bypass_cells = false;
            world.unlock_world();
            assert(job.cursor <= volume);

            if (job.cursor < volume) continue;
            job.active = false;
            if (job.template) |cells| owner.alloc.free(cells);
            job.template = null;
            fire_done(owner, job.plugin, job.done_ref, true);
        }
    }

    /// Host cleanup on plugin failure or shutdown: pending work is dropped
    /// without callbacks because the owning VM may already be gone.
    pub fn cancel_owner(self: *Registry, owner: *Plugins, plugin: *Plugins.Plugin) void {
        for (self.jobs[0..self.count]) |*job| {
            if (!job.active or job.plugin != plugin) continue;
            job.active = false;
            if (job.template) |cells| owner.alloc.free(cells);
            job.template = null;
        }
    }
};

fn fire_done(owner: *Plugins, plugin: *Plugins.Plugin, done_ref: i32, ok: bool) void {
    const runtime = plugin.runtime orelse return;
    runtime.deadline_ms = Client.now_ms() + Plugins.callback_budget_ms;
    runtime.push_function(done_ref);
    runtime.state.pushBoolean(ok);
    if (!runtime.protect_call(1, 0)) {
        owner.script_failed(plugin, runtime.last_error());
    }
}

fn format_world_uuid(buf: *[36]u8) []const u8 {
    return (Manifest.Uuid{ .bytes = world.data.uuid }).format(buf);
}

fn read_template(dir: std.Io.Dir, path: []const u8, alloc: std.mem.Allocator, expected: usize) ?[]u8 {
    const file = dir.openFile(Server.io, path, .{}) catch return null;
    defer file.close(Server.io);

    const stat = file.stat(Server.io) catch return null;
    if (stat.size != expected) return null;
    const buf = alloc.alloc(u8, expected) catch return null;
    const len = file.readPositionalAll(Server.io, buf, 0) catch {
        alloc.free(buf);
        return null;
    };
    if (len != expected) {
        alloc.free(buf);
        return null;
    }
    return buf;
}

/// Host-owned startup recovery: restore every dirty arena template before
/// plugins start, durably save, and only then clear the dirty record. Failed
/// recovery keeps the record so the next startup retries.
pub fn recover(alloc: std.mem.Allocator, data_dir: std.Io.Dir) void {
    if (!world.active) return;
    var dir = data_dir.openDir(Server.io, "plugin-data", .{ .iterate = true }) catch return;
    defer dir.close(Server.io);

    var it = dir.iterate();
    while (it.next(Server.io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".dirty.json")) continue;
        recover_one(alloc, data_dir, entry.name);
    }
}

fn recover_one(alloc: std.mem.Allocator, data_dir: std.Io.Dir, record_name: []const u8) void {
    var record_buf: [128]u8 = undefined;
    const record_path = plugin_data_path(&record_buf, "{s}", .{record_name}) orelse return;
    const source = data_dir.readFileAlloc(Server.io, record_path, alloc, .limited(4096)) catch return;
    defer alloc.free(source);

    const parsed = std.json.parseFromSlice(DirtyRecord, alloc, source, .{}) catch {
        log.err("Dirty arena record '{s}' is unreadable; it is kept for the next startup", .{record_name});
        return;
    };
    defer parsed.deinit();

    const record = parsed.value;

    const dims = world.data.dims;
    var world_uuid: [36]u8 = undefined;
    const identity_ok = record.length == dims.length and record.height == dims.height and record.depth == dims.depth and
        std.mem.eql(u8, record.uuid, format_world_uuid(&world_uuid));
    if (!identity_ok) {
        log.err("Dirty arena record '{s}' belongs to a different world; it is kept and the arena stays protected", .{record_name});
        return;
    }
    if (std.mem.indexOfAny(u8, record.template, "/\\") != null or !std.mem.endsWith(u8, record.template, ".bin")) {
        log.err("Dirty arena record '{s}' names an invalid template; it is kept", .{record_name});
        return;
    }
    const box = Regions.Box{
        .x0 = @intCast(record.x0),
        .y0 = @intCast(record.y0),
        .z0 = @intCast(record.z0),
        .x1 = @intCast(record.x1),
        .y1 = @intCast(record.y1),
        .z1 = @intCast(record.z1),
    };
    assert(box.x1 >= box.x0 and box.y1 >= box.y0 and box.z1 >= box.z0);
    if (!box_in_world(box)) {
        log.err("Dirty arena record '{s}' is outside the world bounds; it is kept", .{record_name});
        return;
    }
    const volume = box.volume();
    var template_buf: [128]u8 = undefined;
    const template_path_text = plugin_data_path(&template_buf, "{s}", .{record.template}) orelse return;
    const cells = read_template(data_dir, template_path_text, alloc, volume) orelse {
        log.err("Dirty arena template for '{s}' is missing or mismatched; the record is kept", .{record_name});
        return;
    };
    defer alloc.free(cells);

    log.info("Recovering dirty arena from '{s}'", .{record.template});
    world.lock_world();
    var index: u32 = 0;
    while (index < volume) : (index += 1) {
        const cell = cell_at(box, index);
        world.data.apply_block(cell[0], cell[1], cell[2], @enumFromInt(cells[index]));
    }
    world.unlock_world();
    world.save();
    world.wait_for_save();
    data_dir.deleteFile(Server.io, record_path) catch |err| {
        log.warn("Recovered arena but could not clear '{s}': {}", .{ record_name, err });
    };
}
