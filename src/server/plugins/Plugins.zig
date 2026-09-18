//! Plugin lifecycle: discovery, dependency resolution, capability-granted
//! bindings, timers, persistence, stable spawn, and failure containment.
//! Script execution happens only on the ordered host context (tick thread).
const std = @import("std");
const core = @import("core");
const Server = core.Server;
const Client = core.Server.Client;
const world = core.World;
const luaz = @import("luaz");
const Manifest = @import("Manifest.zig");
const RuntimeMod = @import("Runtime.zig");
const HostMod = @import("Host.zig");
const Regions = @import("Regions.zig");
const Sessions = @import("Sessions.zig");
const Arena = @import("Arena.zig");
const Commands = @import("../Commands.zig");

const log = std.log.scoped(.plugins);
const assert = std.debug.assert;

pub const max_plugins = 16;
pub const max_timers = 32;
pub const max_handlers = 4;
pub const max_commands = 16;
pub const callback_budget_ms: i64 = 100;
pub const max_host_ops_per_tick: u32 = 256;
pub const max_store_bytes: usize = 64 * 1024;
pub const max_message_bytes: usize = 512;
const chat_payload_max: usize = 58;

const Timer = struct {
    func_ref: i32,
    interval_ms: u32,
    next_due_ms: i64,
    repeats: bool,
    canceled: bool = false,
};

const CommandBinding = struct {
    plugin: *Plugin,
    func_ref: i32,
};

pub const Plugin = struct {
    owner: *Plugins,
    manifest: Manifest.Manifest,
    dir_buf: [64]u8 = @splat(0),
    dir_len: u8 = 0,
    package_dir: std.Io.Dir = undefined,
    package_open: bool = false,
    runtime: ?*RuntimeMod.Runtime = null,
    active: bool = false,
    timers: [max_timers]Timer = undefined,
    timer_count: usize = 0,
    join_refs: [max_handlers]i32 = @splat(0),
    join_count: usize = 0,
    leave_refs: [max_handlers]i32 = @splat(0),
    leave_count: usize = 0,
    block_refs: [max_handlers]i32 = @splat(0),
    block_count: usize = 0,
    command_bindings: [max_commands]CommandBinding = undefined,
    command_count: usize = 0,
    move_refs: [max_handlers]i32 = @splat(0),
    move_count: usize = 0,
    violation_refs: [max_handlers]i32 = @splat(0),
    violation_count: usize = 0,
    store_ref: i32 = 0,
    ops_this_tick: u32 = 0,
    disabled: bool = false,

    pub fn dir_name(self: *const Plugin) []const u8 {
        return self.dir_buf[0..self.dir_len];
    }

    pub fn uuid_text(self: *const Plugin, buf: *[36]u8) []const u8 {
        return self.manifest.uuid.format(buf);
    }

    fn has_capability(self: *const Plugin, capability: Manifest.Capability) bool {
        return self.manifest.has_capability(capability);
    }

    fn take_op_budget(self: *Plugin) bool {
        self.ops_this_tick += 1;
        return self.ops_this_tick <= max_host_ops_per_tick;
    }
};

pub const Plugins = @This();

alloc: std.mem.Allocator,
data_dir: std.Io.Dir,
host: *HostMod.Host,
items: [max_plugins]*Plugin = undefined,
count: usize = 0,
spawn: SpawnState = .{},
regions: Regions.Registry = .{},
sessions: Sessions.Registry = .{},
jobs: Arena.Registry = .{},
traces: [Server.MaxPlayers]MoveTrace = @splat(.{}),
edit_handle: ?Server.PlayerHandle = null,
shutting_down: bool = false,

/// Movement-policy evidence: unsupported hovering and implausible ascent
/// reported as violations, never as an authoritative isFlying flag.
pub const MoveViolation = enum { hover, ascend };

pub const MoveTrace = struct {
    serial: u32 = 0,
    last_ms: i64 = 0,
    last_x: u16 = 0,
    last_y: u16 = 0,
    last_z: u16 = 0,
    hover_ms: i32 = 0,
    ascent_ms: i32 = 0,
    ascent_dy: i32 = 0,
};

pub const hover_evidence_ms: i32 = 5000;
pub const ascent_window_ms: i32 = 1500;
pub const ascent_evidence_blocks: i32 = 5;
const sample_gap_ms: i64 = 2000;

pub fn movement_policy_sample(
    trace: *MoveTrace,
    now: i64,
    serial: u32,
    x: u16,
    y: u16,
    z: u16,
    supported: bool,
) ?MoveViolation {
    if (trace.serial != serial) {
        trace.* = .{ .serial = serial, .last_ms = now, .last_x = x, .last_y = y, .last_z = z };
        return null;
    }
    const dt = now - trace.last_ms;
    trace.last_ms = now;
    const dy = @as(i32, y) - @as(i32, trace.last_y);
    const moved = x != trace.last_x or z != trace.last_z;
    trace.last_x = x;
    trace.last_y = y;
    trace.last_z = z;
    if (dt <= 0 or dt > sample_gap_ms) {
        trace.hover_ms = 0;
        trace.ascent_ms = 0;
        trace.ascent_dy = 0;
        return null;
    }

    var violation: ?MoveViolation = null;
    if (!supported and dy == 0 and !moved) {
        trace.hover_ms += @intCast(dt);
        if (trace.hover_ms >= hover_evidence_ms) {
            trace.hover_ms = 0;
            violation = .hover;
        }
    } else {
        trace.hover_ms = 0;
    }
    if (!supported and dy > 0) {
        trace.ascent_ms += @intCast(dt);
        trace.ascent_dy += dy;
        if (trace.ascent_dy >= ascent_evidence_blocks and trace.ascent_ms <= ascent_window_ms) {
            trace.ascent_ms = 0;
            trace.ascent_dy = 0;
            violation = .ascend;
        } else if (trace.ascent_ms > ascent_window_ms) {
            trace.ascent_ms = 0;
            trace.ascent_dy = 0;
        }
    } else {
        trace.ascent_ms = 0;
        trace.ascent_dy = 0;
    }
    return violation;
}

/// The mutation guard runs under the world lock on the ordered context; it
/// consults only native region/session state, never scripts.
var guard_manager: ?*Plugins = null;

fn mutation_allowed(x: u16, y: u16, z: u16) bool {
    const manager = guard_manager orelse return true;
    if (Arena.bypass_cells) return true;
    const region = manager.regions.find(x, y, z) orelse return true;
    if (manager.edit_handle) |handle| {
        return manager.sessions.plugin_contains(region.owner, handle);
    }
    return !region.frozen;
}

const SpawnState = struct {
    x: u16 = 0,
    y: u16 = 0,
    z: u16 = 0,
    yaw: u8 = 0,
    pitch: u8 = 0,
    valid: bool = false,
};

const SpawnFile = struct {
    uuid: [16]u8 = @splat(0),
    length: u32 = 0,
    height: u32 = 0,
    depth: u32 = 0,
    x: u32 = 0,
    y: u32 = 0,
    z: u32 = 0,
    yaw: u8 = 0,
    pitch: u8 = 0,
};

const spawn_file_name = "spawn.json";
const plugin_data_dir_name = "plugin-data";
const empty_spawn = SpawnFile{};

// The shipped plugin packages. They materialize into `plugins/<dir>/` on
// first boot so every fresh server starts with them; an existing plugins
// directory stays operator-managed and is never modified.
const ShippedFile = struct { name: []const u8, contents: []const u8 };
const ShippedPackage = struct { dir: []const u8, files: []const ShippedFile };
const shipped_packages = [_]ShippedPackage{
    .{ .dir = "essentials", .files = &.{
        .{ .name = "manifest.json", .contents = @embedFile("essentials/manifest.json") },
        .{ .name = "essentials.luau", .contents = @embedFile("essentials/essentials.luau") },
        .{ .name = "config.json", .contents = @embedFile("essentials/config.json") },
    } },
    .{ .dir = "spleef", .files = &.{
        .{ .name = "manifest.json", .contents = @embedFile("spleef/manifest.json") },
        .{ .name = "spleef.luau", .contents = @embedFile("spleef/spleef.luau") },
        .{ .name = "config.json", .contents = @embedFile("spleef/config.json") },
    } },
};

/// Factory state: a server without a plugins directory ships with the
/// bundled packages. Operators opt out by keeping a plugins directory (even
/// empty) present.
fn prepare_plugins_dir(self: *Plugins) void {
    const exists = if (self.data_dir.openDir(Server.io, "plugins", .{})) |_| true else |err| switch (err) {
        error.FileNotFound => false,
        else => true,
    };
    if (exists) return;

    for (shipped_packages) |package| {
        var dir_buf: [64]u8 = undefined;
        const dir_path = std.fmt.bufPrint(&dir_buf, "plugins/{s}", .{package.dir}) catch continue;
        self.data_dir.createDirPath(Server.io, dir_path) catch |err| {
            log.warn("Could not create '{s}': {}", .{ dir_path, err });
            continue;
        };
        for (package.files) |file| {
            var path_buf: [96]u8 = undefined;
            const path = std.fmt.bufPrint(&path_buf, "plugins/{s}/{s}", .{ package.dir, file.name }) catch continue;
            self.data_dir.writeFile(Server.io, .{ .sub_path = path, .data = file.contents }) catch |err| {
                log.warn("Could not write '{s}': {}", .{ path, err });
            };
        }
    }
    log.info("Installed the shipped plugin packages", .{});
}

pub fn init(alloc: std.mem.Allocator, data_dir: std.Io.Dir, host: *HostMod.Host) !*Plugins {
    const self = try alloc.create(Plugins);
    self.* = .{ .alloc = alloc, .data_dir = data_dir, .host = host };
    host.plugins = self;
    guard_manager = self;
    core.World.WorldSimulation.mutation_guard = &mutation_allowed;
    errdefer {
        core.World.WorldSimulation.mutation_guard = null;
        guard_manager = null;
        host.plugins = null;
        alloc.destroy(self);
    }

    data_dir.createDirPath(Server.io, plugin_data_dir_name) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => log.warn("Could not create '{s}': {}", .{ plugin_data_dir_name, err }),
    };

    var manifests: [max_plugins]Manifest.Manifest = undefined;
    var dirs: [max_plugins][64]u8 = undefined;
    var lens: [max_plugins]u8 = undefined;
    var discovered: usize = 0;

    var scratch: [4096]u8 = undefined;
    self.prepare_plugins_dir();
    var plugins_dir = data_dir.openDir(Server.io, "plugins", .{ .iterate = true }) catch {
        log.info("No plugins directory; running vanilla", .{});
        self.init_spawn();
        return self;
    };
    defer plugins_dir.close(Server.io);

    var it = plugins_dir.iterate();
    while (it.next(Server.io) catch null) |entry| {
        if (entry.kind != .directory) continue;
        if (discovered == max_plugins) break;
        const manifest = Manifest.load_from(data_dir, entry.name, alloc, &scratch) orelse continue;
        var duplicate = false;
        for (manifests[0..discovered]) |other| {
            if (other.uuid.eql(manifest.uuid)) duplicate = true;
        }
        if (duplicate) {
            log.warn("Plugin '{s}' duplicates an installed UUID; both are disabled", .{entry.name});
            continue;
        }
        manifests[discovered] = manifest;
        const dir_len = @min(entry.name.len, dirs[0].len);
        @memcpy(dirs[discovered][0..dir_len], entry.name[0..dir_len]);
        lens[discovered] = @intCast(dir_len);
        discovered += 1;
    }

    sort_discovered(manifests[0..discovered], dirs[0..discovered], lens[0..discovered]);

    for (0..discovered) |i| {
        const plugin = try self.alloc.create(Plugin);
        assert(lens[i] > 0);
        plugin.* = .{ .owner = self, .manifest = manifests[i], .dir_len = lens[i] };
        plugin.dir_buf = dirs[i];
        self.items[self.count] = plugin;
        self.count += 1;
    }

    // Recover dirty arenas before any plugin starts so games never admit
    // players onto an unrestored arena, even when their plugin is missing.
    Arena.recover(alloc, data_dir);
    self.resolve_and_start();
    self.init_spawn();
    return self;
}

fn sort_discovered(manifests: []Manifest.Manifest, dirs: [][64]u8, lens: []u8) void {
    const n = manifests.len;
    if (n < 2) return;
    var order: [max_plugins]usize = undefined;
    for (0..n) |i| order[i] = i;
    var swap_count: usize = 1;
    while (swap_count > 0) {
        swap_count = 0;
        for (1..n) |i| {
            if (std.mem.order(u8, &manifests[order[i]].uuid.bytes, &manifests[order[i - 1]].uuid.bytes) != .lt) continue;
            std.mem.swap(usize, &order[i], &order[i - 1]);
            swap_count += 1;
        }
    }
    var sorted_m: [max_plugins]Manifest.Manifest = undefined;
    var sorted_d: [max_plugins][64]u8 = undefined;
    var sorted_l: [max_plugins]u8 = undefined;
    for (0..n) |i| {
        sorted_m[i] = manifests[order[i]];
        sorted_d[i] = dirs[order[i]];
        sorted_l[i] = lens[order[i]];
    }
    @memcpy(manifests, sorted_m[0..n]);
    @memcpy(dirs, sorted_d[0..n]);
    @memcpy(lens, sorted_l[0..n]);
}

/// Topological startup with deterministic order. A plugin starts once every
/// required dependency is active; cycles and missing, incompatible, or failed
/// required dependencies disable the affected plugin and its dependents.
fn resolve_and_start(self: *Plugins) void {
    var progressed = true;
    var pending = self.count;
    while (pending > 0 and progressed) {
        progressed = false;
        pending = 0;
        for (self.items[0..self.count]) |plugin| {
            if (plugin.active or plugin.package_open or plugin.disabled) continue;
            var ready = true;
            var blocked = false;
            for (plugin.manifest.dependencies()) |dep| {
                const dependency = self.find(dep.uuid) orelse {
                    if (dep.optional) {
                        log.info("Plugin '{s}': optional dependency is not installed", .{plugin.manifest.name()});
                        continue;
                    }
                    self.disable(plugin, "required dependency is not installed");
                    blocked = true;
                    break;
                };
                if (dependency.active) {
                    if (!dep.version.matches(dependency.manifest.version)) {
                        if (!dep.optional) {
                            self.disable(plugin, "required dependency is incompatible");
                            blocked = true;
                            break;
                        }
                        log.info("Plugin '{s}': optional dependency is incompatible", .{plugin.manifest.name()});
                    }
                    continue;
                }
                if (dependency.package_open) {
                    if (!dep.optional) {
                        self.disable(plugin, "required dependency failed during startup");
                        blocked = true;
                        break;
                    }
                    continue;
                }
                if (!dep.optional) ready = false;
            }
            if (blocked) {
                progressed = true;
                continue;
            }
            if (ready) {
                self.start(plugin);
                progressed = true;
            } else {
                pending += 1;
            }
        }
    }
    for (self.items[0..self.count]) |plugin| {
        if (!plugin.active and !plugin.package_open and !plugin.disabled) {
            self.disable(plugin, "dependency cycle detected");
        }
    }
}

fn find(self: *Plugins, uuid: Manifest.Uuid) ?*Plugin {
    assert(self.count <= max_plugins);
    for (self.items[0..self.count]) |plugin| {
        if (plugin.manifest.uuid.eql(uuid)) return plugin;
    }
    return null;
}

fn start(self: *Plugins, plugin: *Plugin) void {
    var path_buf: [128]u8 = undefined;
    const package_path = std.fmt.bufPrint(&path_buf, "plugins/{s}", .{plugin.dir_name()}) catch return;
    plugin.package_dir = self.data_dir.openDir(Server.io, package_path, .{}) catch {
        self.disable(plugin, "package directory is unreadable");
        return;
    };
    plugin.package_open = true;

    const runtime = RuntimeMod.Runtime.init(self.alloc, plugin.package_dir) catch {
        self.disable(plugin, "could not create the sandboxed VM");
        return;
    };
    plugin.runtime = runtime;

    self.install_bindings(plugin);
    plugin.store_ref = self.load_store(plugin);

    const entry_path = plugin.manifest.entrypoint();
    const source = read_file(plugin.package_dir, entry_path, self.alloc, RuntimeMod.max_source_bytes) orelse {
        self.disable(plugin, "entrypoint is missing or too large");
        return;
    };
    defer self.alloc.free(source);

    if (!runtime.run_entrypoint(entry_path, source)) {
        self.disable(plugin, runtime.last_error());
        return;
    }

    plugin.active = true;
    log.info("Started plugin '{s}' {d}.{d}.{d}", .{
        plugin.manifest.name(),
        plugin.manifest.version.major,
        plugin.manifest.version.minor,
        plugin.manifest.version.patch,
    });
}

pub fn deinit(self: *Plugins) void {
    // Reverse start order; host cleanup revokes registrations, ends sessions,
    // and cancels work without relying on script cleanup succeeding. Players
    // are on their way out during shutdown, so no return teleports run.
    const alloc = self.alloc;
    const count = self.count;
    const items = self.items;
    self.shutting_down = true;
    for (items[0..count]) |plugin| {
        self.sessions.end_for_owner(plugin, .{}, false);
        self.regions.release_owner(plugin);
        self.jobs.cancel_owner(self, plugin);
    }
    core.World.WorldSimulation.mutation_guard = null;
    guard_manager = null;
    self.* = undefined;

    var i = count;
    while (i > 0) {
        i -= 1;
        const plugin = items[i];
        Commands.unregister_owner(plugin);
        if (plugin.runtime) |runtime| runtime.deinit(alloc);
        if (plugin.package_open) plugin.package_dir.close(Server.io);
        alloc.destroy(plugin);
    }
    alloc.destroy(self);
}

fn disable(self: *Plugins, plugin: *Plugin, reason: []const u8) void {
    assert(!plugin.disabled or plugin.active);
    plugin.disabled = true;
    var uuid_buf: [36]u8 = undefined;
    log.warn("Disabling plugin '{s}' ({s}): {s}", .{
        plugin.manifest.name(), plugin.uuid_text(&uuid_buf), reason,
    });
    // Host-owned cleanup: end sessions (returning members), drop claims and
    // jobs, and revoke registrations before the VM goes away.
    self.sessions.end_for_owner(plugin, self.return_spot(), !self.shutting_down);
    self.regions.release_owner(plugin);
    self.jobs.cancel_owner(self, plugin);
    Commands.unregister_owner(plugin);
    plugin.timer_count = 0;
    plugin.join_count = 0;
    plugin.leave_count = 0;
    plugin.block_count = 0;
    plugin.move_count = 0;
    plugin.violation_count = 0;
    plugin.command_count = 0;
    plugin.active = false;
    if (plugin.runtime) |runtime| {
        runtime.deinit(self.alloc);
        plugin.runtime = null;
    }
    if (plugin.package_open) {
        plugin.package_dir.close(Server.io);
        plugin.package_open = false;
    }
    for (self.items[0..self.count]) |other| {
        if (!other.active) continue;
        for (other.manifest.dependencies()) |dep| {
            if (dep.optional or !dep.uuid.eql(plugin.manifest.uuid)) continue;
            self.disable(other, "required dependency was disabled");
            break;
        }
    }
}

pub fn script_failed(self: *Plugins, plugin: *Plugin, message: []const u8) void {
    var uuid_buf: [36]u8 = undefined;
    log.err("Plugin '{s}' ({s}) script error: {s}", .{
        plugin.manifest.name(), plugin.uuid_text(&uuid_buf), message,
    });
    self.disable(plugin, "script error");
}

// ------------------------------------------------------------------ tick

pub fn tick(self: *Plugins) void {
    assert(self.host.deadline_ms > 0);
    const now = Client.now_ms();
    for (self.items[0..self.count]) |plugin| {
        plugin.ops_this_tick = 0;
    }
    for (self.items[0..self.count]) |plugin| {
        if (!plugin.active) continue;
        var index: usize = 0;
        while (index < plugin.timer_count) : (index += 1) {
            if (Client.now_ms() >= self.host.deadline_ms) return;
            const timer = &plugin.timers[index];
            if (timer.canceled or now < timer.next_due_ms) continue;
            if (timer.repeats) {
                timer.next_due_ms = now + timer.interval_ms;
            } else {
                timer.canceled = true;
            }
            const runtime = plugin.runtime orelse continue;
            runtime.deadline_ms = now + callback_budget_ms;
            runtime.push_function(timer.func_ref);
            if (!runtime.protect_call(0, 0)) {
                script_failed(self, plugin, runtime.last_error());
                break;
            }
        }
        var write: usize = 0;
        for (0..plugin.timer_count) |read| {
            if (plugin.timers[read].canceled) continue;
            if (write != read) plugin.timers[write] = plugin.timers[read];
            write += 1;
        }
        plugin.timer_count = write;
    }
    self.jobs.tick(self);
}

// -------------------------------------------------------- event dispatch

fn snapshot_client(client: *Server.Client) Server.PlayerInfo {
    Server.lock_roster_shared();
    defer Server.unlock_roster_shared();

    return client_info_locked(client, .{ .id = @intCast(client.id), .generation = client.generation });
}

fn client_info_locked(client: *Server.Client, handle: Server.PlayerHandle) Server.PlayerInfo {
    const pose = client.pose.load();
    var info = Server.PlayerInfo{
        .handle = handle,
        .name_len = client.name_len,
        .x = pose.x,
        .y = pose.y,
        .z = pose.z,
        .yaw = pose.yaw,
        .pitch = pose.pitch,
        .op = client.is_op.load(.acquire),
        .authenticated = client.authenticated.load(.acquire),
    };
    @memcpy(info.name_buf[0..client.name_len], client.name[0..client.name_len]);
    return info;
}

fn resolve_info(handle: Server.PlayerHandle) ?Server.PlayerInfo {
    Server.lock_roster_shared();
    defer Server.unlock_roster_shared();

    const client = &(Server.players.items[handle.id] orelse return null);
    if (client.generation != handle.generation or !client.initialized) return null;
    return client_info_locked(client, handle);
}

pub fn dispatch_join(self: *Plugins, handle: Server.PlayerHandle, name: []const u8) void {
    _ = name;
    const info = resolve_info(handle) orelse return;
    for (self.items[0..self.count]) |plugin| {
        assert(plugin.join_count <= max_handlers);
        if (!plugin.active or plugin.join_count == 0) continue;
        const runtime = plugin.runtime orelse continue;
        for (plugin.join_refs[0..plugin.join_count]) |ref| {
            runtime.deadline_ms = Client.now_ms() + callback_budget_ms;
            runtime.push_function(ref);
            push_player_info(runtime, info);
            if (!runtime.protect_call(1, 0)) {
                script_failed(self, plugin, runtime.last_error());
                return;
            }
        }
    }
}

pub fn dispatch_leave(self: *Plugins, handle: Server.PlayerHandle, name: []const u8) void {
    // Host-owned membership cleanup runs before script notifications so a
    // disconnect never leaves stale session membership behind.
    self.sessions.purge_player(handle);

    var info = Server.PlayerInfo{ .handle = handle };
    const len = @min(name.len, info.name_buf.len);
    @memcpy(info.name_buf[0..len], name[0..len]);
    info.name_len = @intCast(len);

    for (self.items[0..self.count]) |plugin| {
        assert(plugin.leave_count <= max_handlers);
        if (!plugin.active or plugin.leave_count == 0) continue;
        const runtime = plugin.runtime orelse continue;
        for (plugin.leave_refs[0..plugin.leave_count]) |ref| {
            runtime.deadline_ms = Client.now_ms() + callback_budget_ms;
            runtime.push_function(ref);
            push_player_info(runtime, info);
            if (!runtime.protect_call(1, 0)) {
                script_failed(self, plugin, runtime.last_error());
                return;
            }
        }
    }
}

/// Collect decisions for a block attempt before mutation. Decision callbacks
/// cannot yield; a denial wins over a consume result. Claims are enforced
/// natively first: a player outside the owning plugin's session never reaches
/// any handler, and Op status does not bypass that rule.
pub fn decide_block_attempt(self: *Plugins, client: *Server.Client, attempt: *HostMod.BlockAttempt) HostMod.Decision {
    attempt.player = snapshot_client(client);
    if (self.entry_denied(attempt.player.handle, attempt.x, attempt.y, attempt.z)) return .deny;
    var decision: HostMod.Decision = .allow;

    for (self.items[0..self.count]) |plugin| {
        assert(plugin.block_count <= max_handlers);
        if (!plugin.active or plugin.block_count == 0) continue;
        const runtime = plugin.runtime orelse continue;
        for (plugin.block_refs[0..plugin.block_count]) |ref| {
            runtime.deadline_ms = Client.now_ms() + callback_budget_ms;
            runtime.push_function(ref);
            push_player_info(runtime, attempt.player);
            push_attempt(runtime, attempt);
            if (!runtime.protect_call(2, 1)) {
                script_failed(self, plugin, runtime.last_error());
                continue;
            }
            decision = combine(decision, classify_decision(runtime));
        }
    }
    return decision;
}

fn entry_denied(self: *Plugins, handle: Server.PlayerHandle, x: u16, y: u16, z: u16) bool {
    const region = self.regions.find(x, y, z) orelse return false;
    return !self.sessions.plugin_contains(region.owner, handle);
}

fn classify_decision(runtime: *RuntimeMod.Runtime) HostMod.Decision {
    const state = runtime.state;
    defer state.pop(1);

    if (state.getType(-1) == .string) {
        const text = state.toString(-1) orelse return .allow;
        if (std.mem.eql(u8, text, "deny")) return .deny;
        if (std.mem.eql(u8, text, "consume")) return .consume;
    }
    return .allow;
}

fn combine(current: HostMod.Decision, proposed: HostMod.Decision) HostMod.Decision {
    return switch (current) {
        .deny => .deny,
        .consume => if (proposed == .deny) .deny else .consume,
        .allow => proposed,
    };
}

/// Authorize a committed player edit for the mutation guard. The attempt has
/// already passed the decision path; the guard revalidates every affected
/// cell (gravity landing cells, released stacks) against claim ownership.
pub fn begin_edit(self: *Plugins, handle: Server.PlayerHandle) void {
    self.edit_handle = handle;
}

pub fn end_edit(self: *Plugins) void {
    self.edit_handle = null;
}

fn feet_blocks(pose: Client.PlayerPose) [3]u16 {
    return .{
        pose.x / 32,
        if (pose.y >= 51) (pose.y - 51) / 32 else 0,
        pose.z / 32,
    };
}

fn has_support(feet: [3]u16) bool {
    world.lock_world_shared();
    defer world.unlock_world_shared();

    const dims = world.data.dims;
    if (feet[1] == 0) return true;
    assert(feet[1] >= 1);
    const below = world.get_block(feet[0], feet[1] - 1, feet[2]);
    const at = world.get_block(feet[0], feet[1], feet[2]);
    if (below.is_solid() or at.is_solid() or below.is_fluid() or at.is_fluid()) return true;
    if (feet[1] + 1 < dims.height and world.get_block(feet[0], feet[1] + 1, feet[2]).is_fluid()) return true;
    return false;
}

/// Evaluate an accepted position report: movement-policy evidence plus
/// accepted-movement events (feet block changes and claim crossings).
pub fn dispatch_position(
    self: *Plugins,
    handle: Server.PlayerHandle,
    teleport_serial: u32,
    before_pose: Client.PlayerPose,
    after_pose: Client.PlayerPose,
) void {
    assert(handle.id < Server.MaxPlayers);
    const before = feet_blocks(before_pose);
    const after = feet_blocks(after_pose);
    assert(after[1] <= (65535 - 51) / 32);
    const supported = has_support(after);
    const violation = movement_policy_sample(
        &self.traces[handle.id],
        Client.now_ms(),
        teleport_serial,
        after[0],
        after[1],
        after[2],
        supported,
    );
    const crossed = before[1] != after[1] or
        self.regions.find(before[0], before[1], before[2]) != self.regions.find(after[0], after[1], after[2]);
    if (violation == null and !crossed) return;
    const info = resolve_info(handle) orelse return;

    if (violation) |kind| {
        for (self.items[0..self.count]) |plugin| {
            assert(plugin.violation_count <= max_handlers);
            if (!plugin.active or plugin.violation_count == 0) continue;
            const runtime = plugin.runtime orelse continue;
            for (plugin.violation_refs[0..plugin.violation_count]) |ref| {
                runtime.deadline_ms = Client.now_ms() + callback_budget_ms;
                runtime.push_function(ref);
                push_player_info(runtime, info);
                runtime.state.pushLString(@tagName(kind));
                if (!runtime.protect_call(2, 0)) {
                    script_failed(self, plugin, runtime.last_error());
                    return;
                }
            }
        }
    }
    if (crossed) {
        for (self.items[0..self.count]) |plugin| {
            assert(plugin.move_count <= max_handlers);
            if (!plugin.active or plugin.move_count == 0) continue;
            const runtime = plugin.runtime orelse continue;
            for (plugin.move_refs[0..plugin.move_count]) |ref| {
                runtime.deadline_ms = Client.now_ms() + callback_budget_ms;
                runtime.push_function(ref);
                push_player_info(runtime, info);
                runtime.state.pushInteger(after[0]);
                runtime.state.pushInteger(after[1]);
                runtime.state.pushInteger(after[2]);
                if (!runtime.protect_call(4, 0)) {
                    script_failed(self, plugin, runtime.last_error());
                    return;
                }
            }
        }
    }
}

// ------------------------------------------------------- Lua value helpers

fn set_int_field(state: luaz.State, name: [:0]const u8, value: anytype) void {
    state.pushInteger(@intCast(value));
    state.setField(-2, name);
}

fn set_string_field(state: luaz.State, name: [:0]const u8, value: []const u8) void {
    state.pushLString(value);
    state.setField(-2, name);
}

fn push_player_info(runtime: *RuntimeMod.Runtime, info: Server.PlayerInfo) void {
    const state = runtime.state;
    state.createTable(0, 9);
    set_int_field(state, "id", info.handle.id);
    set_int_field(state, "gen", info.handle.generation);
    state.pushLString(info.name());
    state.setField(-2, "name");
    set_int_field(state, "x", @as(u32, info.x) / 32);
    set_int_field(state, "y", if (info.y >= 51) @as(u32, info.y - 51) / 32 else 0);
    set_int_field(state, "z", @as(u32, info.z) / 32);
    set_int_field(state, "yaw", info.yaw);
    set_int_field(state, "pitch", info.pitch);
    state.pushBoolean(info.op);
    state.setField(-2, "op");
}

fn push_attempt(runtime: *RuntimeMod.Runtime, attempt: *const HostMod.BlockAttempt) void {
    const state = runtime.state;
    state.createTable(0, 6);
    set_int_field(state, "x", attempt.x);
    set_int_field(state, "y", attempt.y);
    set_int_field(state, "z", attempt.z);
    set_string_field(state, "mode", @tagName(attempt.mode));
    set_string_field(state, "block", @tagName(attempt.block));
    set_string_field(state, "old", @tagName(attempt.old_block));
}

fn resolve_player_arg(runtime: *RuntimeMod.Runtime, index: i32) ?Server.PlayerHandle {
    const state = runtime.state;
    assert(index > 0);
    if (state.getType(index) != .table) return null;
    _ = state.getField(index, "id");
    defer state.pop(1);

    const id = state.toIntegerX(-1) orelse return null;
    _ = state.getField(index, "gen");
    defer state.pop(1);

    const generation = state.toIntegerX(-1) orelse return null;
    if (id < 0 or id >= Server.MaxPlayers) return null;
    return .{ .id = @intCast(id), .generation = @intCast(generation) };
}

fn plugin_from(L: ?*luaz.c.lua_State) *Plugin {
    const state = luaz.State{ .lua = L.? };
    return @ptrCast(@alignCast(state.toLightUserdata(luaz.State.upvalueIndex(1)).?));
}

fn require_capability(plugin: *Plugin, capability: Manifest.Capability) bool {
    if (plugin.has_capability(capability)) return true;
    log.warn("Plugin '{s}' attempted an operation without the {s} capability", .{
        plugin.manifest.name(), @tagName(capability),
    });
    return false;
}

// ------------------------------------------------------------------ spawn

fn init_spawn(self: *Plugins) void {
    if (!world.active) return;
    const dims = world.data.dims;
    const record = self.load_spawn_record();

    const identity_matches = std.mem.eql(u8, &record.uuid, &world.data.uuid) and
        record.length == dims.length and record.height == dims.height and record.depth == dims.depth;
    if (identity_matches) {
        const x: u16 = @intCast(@min(record.x, @as(u32, dims.length - 1)));
        const y: u16 = @intCast(@min(record.y, @as(u32, dims.height - 2)));
        const z: u16 = @intCast(@min(record.z, @as(u32, dims.depth - 1)));
        world.lock_world_shared();
        const safe = Server.safe_destination(x, y, z);
        world.unlock_world_shared();
        if (safe) {
            self.spawn = .{ .valid = true, .x = x, .y = y, .z = z, .yaw = record.yaw, .pitch = record.pitch };
            return;
        }
        log.warn("Persisted spawn is no longer safe; recomputing it", .{});
    }

    world.lock_world_shared();
    const found = world.find_spawn();
    world.unlock_world_shared();
    const x: u16 = found[0] / 32;
    const y: u16 = if (found[1] >= 51) (found[1] - 51) / 32 else 0;
    const z: u16 = found[2] / 32;
    self.spawn = .{ .valid = true, .x = x, .y = y, .z = z };
    self.persist_spawn(x, y, z, 0, 0);
}

fn load_spawn_record(self: *Plugins) SpawnFile {
    const file = self.data_dir.openFile(Server.io, spawn_file_name, .{}) catch return empty_spawn;
    defer file.close(Server.io);

    var buf: [512]u8 = undefined;
    const len = file.readPositionalAll(Server.io, &buf, 0) catch return empty_spawn;
    const parsed = std.json.parseFromSlice(SpawnFile, self.alloc, buf[0..len], .{}) catch return empty_spawn;
    defer parsed.deinit();

    return parsed.value;
}

fn set_spawn(self: *Plugins, x: u16, y: u16, z: u16) bool {
    world.lock_world_shared();
    const safe = Server.safe_destination(x, y, z);
    world.unlock_world_shared();
    if (!safe) return false;
    self.spawn = .{ .valid = true, .x = x, .y = y, .z = z };
    self.persist_spawn(x, y, z, 0, 0);
    log.info("Stable spawn set to ({d}, {d}, {d})", .{ x, y, z });
    return true;
}

fn return_spot(self: *Plugins) Sessions.ReturnSpot {
    return .{
        .x = self.spawn.x,
        .y = self.spawn.y,
        .z = self.spawn.z,
        .yaw = self.spawn.yaw,
        .pitch = self.spawn.pitch,
        .valid = self.spawn.valid,
    };
}

fn persist_spawn(self: *Plugins, x: u16, y: u16, z: u16, yaw: u8, pitch: u8) void {
    const dims = world.data.dims;
    const record = SpawnFile{
        .uuid = world.data.uuid,
        .length = dims.length,
        .height = dims.height,
        .depth = dims.depth,
        .x = x,
        .y = y,
        .z = z,
        .yaw = yaw,
        .pitch = pitch,
    };
    var body: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&body);
    std.json.Stringify.value(record, .{}, &writer) catch return;

    const file = self.data_dir.createFile(Server.io, spawn_file_name, .{}) catch |err| {
        log.warn("Could not persist spawn: {}", .{err});
        return;
    };
    defer file.close(Server.io);

    file.writePositionalAll(Server.io, writer.buffered(), 0) catch |err| {
        log.warn("Could not persist spawn: {}", .{err});
    };
}

// -------------------------------------------------------------- storage

fn store_path(self: *Plugins, plugin: *Plugin, buf: *[96]u8) ?[]const u8 {
    var uuid_buf: [36]u8 = undefined;
    const uuid = plugin.uuid_text(&uuid_buf);
    _ = self;
    return std.fmt.bufPrint(buf, "{s}/{s}.json", .{ plugin_data_dir_name, uuid }) catch null;
}

fn load_store(self: *Plugins, plugin: *Plugin) i32 {
    const runtime = plugin.runtime orelse return 0;
    const state = runtime.state;
    state.createTable(0, 8);
    const table_index = state.getTop();
    defer state.pop(1);

    var path_buf: [96]u8 = undefined;
    const path = self.store_path(plugin, &path_buf) orelse return state.ref(table_index);
    const source = read_file(self.data_dir, path, self.alloc, max_store_bytes) orelse
        return state.ref(table_index);
    defer self.alloc.free(source);

    const parsed = std.json.parseFromSlice(std.json.Value, self.alloc, source, .{}) catch {
        log.warn("Plugin '{s}' storage is corrupt; starting empty", .{plugin.manifest.name()});
        return state.ref(table_index);
    };
    defer parsed.deinit();

    if (parsed.value == .object) {
        var obj_it = parsed.value.object.iterator();
        while (obj_it.next()) |pair| {
            const key = pair.key_ptr.*;
            switch (pair.value_ptr.*) {
                .string => |s| {
                    state.pushLString(key);
                    state.pushLString(s);
                    state.rawSet(table_index);
                },
                .bool => |b| {
                    state.pushLString(key);
                    state.pushBoolean(b);
                    state.rawSet(table_index);
                },
                .integer => |n| {
                    state.pushLString(key);
                    state.pushInteger(@intCast(n));
                    state.rawSet(table_index);
                },
                .float => |f| {
                    state.pushLString(key);
                    state.pushNumber(f);
                    state.rawSet(table_index);
                },
                else => {},
            }
        }
    }
    return state.ref(table_index);
}

fn save_store(self: *Plugins, plugin: *Plugin) void {
    const runtime = plugin.runtime orelse return;
    const state = runtime.state;

    var body: [max_store_bytes]u8 = undefined;
    var writer = std.Io.Writer.fixed(&body);
    writer.writeAll("{") catch return;

    _ = state.getRef(plugin.store_ref);
    state.pushNil();
    var first = true;
    while (state.next(-2)) {
        const key = state.toString(-2);
        if (key) |k| {
            if (!first) writer.writeAll(",") catch break;
            first = false;
            std.json.Stringify.value(k, .{}, &writer) catch break;
            writer.writeAll(":") catch break;
            write_json_value(&writer, state, -1);
        }
        state.pop(1);
    }
    state.pop(1);
    writer.writeAll("}") catch return;

    var path_buf: [96]u8 = undefined;
    const path = self.store_path(plugin, &path_buf) orelse return;
    const file = self.data_dir.createFile(Server.io, path, .{}) catch |err| {
        log.warn("Plugin '{s}' could not persist storage: {}", .{ plugin.manifest.name(), err });
        return;
    };
    defer file.close(Server.io);

    file.writePositionalAll(Server.io, writer.buffered(), 0) catch |err| {
        log.warn("Plugin '{s}' could not persist storage: {}", .{ plugin.manifest.name(), err });
    };
}

fn write_json_value(writer: *std.Io.Writer, state: luaz.State, index: i32) void {
    switch (state.getType(index)) {
        .string => std.json.Stringify.value(state.toString(index) orelse "", .{}, writer) catch {},
        .boolean => writer.writeAll(if (state.toBoolean(index)) "true" else "false") catch {},
        .number => writer.print("{d}", .{state.toNumberX(index) orelse 0}) catch {},
        else => writer.writeAll("null") catch {},
    }
}

// ------------------------------------------------------------- messaging

fn send_split(client: *Server.Client, text: []const u8) bool {
    var line: [64]u8 = undefined;
    var offset: usize = 0;
    var sent_any = false;
    while (offset < text.len) {
        var payload = @min(chat_payload_max, text.len - offset);
        if (offset + payload < text.len) {
            if (std.mem.lastIndexOfScalar(u8, text[offset .. offset + payload], ' ')) |space| {
                if (space > 16) payload = @intCast(space);
            }
        }
        if (offset == 0) {
            @memcpy(line[0..payload], text[0..payload]);
            client.send_message(client.id, line[0..payload]) catch return sent_any;
        } else {
            line[0] = '>';
            line[1] = ' ';
            @memcpy(line[2..][0..payload], text[offset..][0..payload]);
            client.send_message(client.id, line[0 .. payload + 2]) catch return sent_any;
        }
        sent_any = true;
        offset += payload;
        if (offset < text.len and text[offset] == ' ') offset += 1;
    }
    return sent_any;
}

fn message_handle(handle: Server.PlayerHandle, text: []const u8) bool {
    Server.lock_roster_shared();
    defer Server.unlock_roster_shared();

    const client = &(Server.players.items[handle.id] orelse return false);
    if (client.generation != handle.generation or !client.initialized or !client.authenticated.load(.acquire)) return false;
    return send_split(client, text);
}

// -------------------------------------------------------------- bindings

fn install_bindings(self: *Plugins, plugin: *Plugin) void {
    _ = self;
    const runtime = plugin.runtime orelse return;
    const state = runtime.state;
    state.createTable(0, 20);
    bind(plugin, "register_command", api_register_command);
    bind(plugin, "get_players", api_get_players);
    bind(plugin, "find_player", api_find_player);
    bind(plugin, "send_message", api_send_message);
    bind(plugin, "broadcast", api_broadcast);
    bind(plugin, "teleport", api_teleport);
    bind(plugin, "get_spawn", api_get_spawn);
    bind(plugin, "set_spawn", api_set_spawn);
    bind(plugin, "kick", api_kick);
    bind(plugin, "log", api_log);
    bind(plugin, "now", api_now);
    bind(plugin, "set_timeout", api_set_timeout);
    bind(plugin, "set_interval", api_set_interval);
    bind(plugin, "on_player_join", api_on_player_join);
    bind(plugin, "on_player_leave", api_on_player_leave);
    bind(plugin, "on_block_attempt", api_on_block_attempt);
    bind(plugin, "on_player_move", api_on_player_move);
    bind(plugin, "on_movement_violation", api_on_movement_violation);
    bind(plugin, "create_session", api_create_session);
    bind(plugin, "claim", api_claim);
    bind(plugin, "fill", api_fill);
    bind(plugin, "restore", api_restore);
    bind(plugin, "capture", api_capture);
    bind(plugin, "mark_dirty", api_mark_dirty);
    bind(plugin, "clear_dirty", api_clear_dirty);
    bind(plugin, "store_get", api_store_get);
    bind(plugin, "store_set", api_store_set);

    self_push_config(plugin);
    state.setField(-2, "config");
    state.setGlobal("server");
}

fn bind(plugin: *Plugin, name: [:0]const u8, func: luaz.State.CFunction) void {
    const state = plugin.runtime.?.state;
    state.pushLightUserdata(plugin);
    state.pushCClosureK(func, name.ptr, 1, null);
    state.setField(-2, name);
}

fn self_push_config(plugin: *Plugin) void {
    const runtime = plugin.runtime orelse return;
    const state = runtime.state;
    const source = read_file(plugin.package_dir, "config.json", plugin.owner.alloc, 64 * 1024) orelse {
        state.createTable(0, 0);
        return;
    };
    defer plugin.owner.alloc.free(source);

    const parsed = std.json.parseFromSlice(std.json.Value, plugin.owner.alloc, source, .{}) catch {
        log.warn("Plugin '{s}' config.json is invalid; using an empty config", .{plugin.manifest.name()});
        state.createTable(0, 0);
        return;
    };
    defer parsed.deinit();

    push_json_value(runtime, parsed.value);
}

fn push_json_value(runtime: *RuntimeMod.Runtime, value: std.json.Value) void {
    const state = runtime.state;
    switch (value) {
        .null => state.pushNil(),
        .bool => |b| state.pushBoolean(b),
        .integer => |n| state.pushInteger(@intCast(n)),
        .float => |f| state.pushNumber(f),
        .number_string => |s| state.pushLString(s),
        .string => |s| state.pushLString(s),
        .array => |items| {
            state.createTable(@intCast(items.items.len), 0);
            for (items.items, 0..) |item, i| {
                push_json_value(runtime, item);
                state.rawSetI(-2, @intCast(i + 1));
            }
        },
        .object => |obj| {
            state.createTable(0, @intCast(obj.count()));
            var obj_it = obj.iterator();
            while (obj_it.next()) |pair| {
                state.pushLString(pair.key_ptr.*);
                push_json_value(runtime, pair.value_ptr.*);
                state.rawSet(-3);
            }
        },
    }
}

fn read_file(dir: std.Io.Dir, path: []const u8, alloc: std.mem.Allocator, max: usize) ?[]u8 {
    const file = dir.openFile(Server.io, path, .{}) catch return null;
    defer file.close(Server.io);

    const stat = file.stat(Server.io) catch return null;
    if (stat.size == 0 or stat.size > max) return null;
    const buf = alloc.alloc(u8, @intCast(stat.size)) catch return null;
    const len = file.readPositionalAll(Server.io, buf, 0) catch {
        alloc.free(buf);
        return null;
    };
    return buf[0..len];
}

// ------------------------------------------------------ Luau API surface

fn api_register_command(L: ?*luaz.c.lua_State) callconv(.c) c_int {
    const plugin = plugin_from(L);
    const state = plugin.runtime.?.state;
    if (plugin.command_count >= max_commands) {
        state.pushLString("command registration limit reached");
        state.raiseError();
    }
    const def = state.getTop();
    if (state.getType(def) != .table) {
        state.pushLString("register_command expects a table");
        state.raiseError();
    }
    _ = state.getField(def, "name");
    const name = state.toString(-1) orelse "";
    state.pop(1);
    _ = state.getField(def, "usage");
    const usage = state.toString(-1) orelse "";
    state.pop(1);
    _ = state.getField(def, "handler");
    if (!state.isFunction(-1)) {
        state.pop(1);
        state.pushLString("handler must be a function");
        state.raiseError();
    }
    const func_ref = state.ref(-1);
    state.pop(1);

    var aliases: [4][16]u8 = undefined;
    var alias_lens: [4]u8 = @splat(0);
    var alias_count: usize = 0;
    _ = state.getField(def, "aliases");
    if (state.getType(-1) == .table) {
        const n = state.objLen(-1);
        while (alias_count < aliases.len and alias_count < n) {
            _ = state.rawGetI(-1, @intCast(alias_count + 1));
            if (state.toString(-1)) |alias| {
                if (alias.len <= aliases[0].len) {
                    @memcpy(aliases[alias_count][0..alias.len], alias);
                    alias_lens[alias_count] = @intCast(alias.len);
                }
            }
            state.pop(1);
            alias_count += 1;
        }
    }
    state.pop(1);

    var permission: Commands.Permission = .anyone;
    _ = state.getField(def, "permission");
    if (state.toString(-1)) |p| {
        if (std.mem.eql(u8, p, "op")) permission = .op;
    }
    state.pop(1);
    var restriction: Commands.Restriction = .any;
    _ = state.getField(def, "caller");
    if (state.toString(-1)) |r| {
        if (std.mem.eql(u8, r, "player")) restriction = .player_only;
        if (std.mem.eql(u8, r, "console")) restriction = .console_only;
    }
    state.pop(1);

    var alias_slices: [4][]const u8 = undefined;
    for (0..alias_count) |i| alias_slices[i] = aliases[i][0..alias_lens[i]];

    const binding = &plugin.command_bindings[plugin.command_count];
    binding.* = .{ .plugin = plugin, .func_ref = func_ref };
    assert(plugin.command_count < max_commands);
    const registered = Commands.register(.{
        .name = name,
        .aliases = alias_slices[0..alias_count],
        .usage = usage,
        .permission = permission,
        .restriction = restriction,
        .script = .{ .ctx = binding, .call = call_command_shim },
    }, plugin);
    if (registered) plugin.command_count += 1;
    state.pushBoolean(registered);
    return 1;
}

fn call_command_shim(ctx: *anyopaque, caller: Commands.Caller, args: []const []const u8) void {
    const binding: *CommandBinding = @ptrCast(@alignCast(ctx));
    const plugin = binding.plugin;
    const runtime = plugin.runtime orelse return;
    const state = runtime.state;

    runtime.deadline_ms = Client.now_ms() + callback_budget_ms;
    runtime.push_function(binding.func_ref);
    switch (caller) {
        .console => state.pushNil(),
        .player => |client| push_player_info(runtime, snapshot_client(client)),
    }
    state.createTable(@intCast(args.len), 0);
    for (args, 0..) |arg, i| {
        state.pushLString(arg);
        state.rawSetI(-2, @intCast(i + 1));
    }
    if (!runtime.protect_call(2, 0)) {
        plugin.owner.script_failed(plugin, runtime.last_error());
    }
}

fn api_get_players(L: ?*luaz.c.lua_State) callconv(.c) c_int {
    const plugin = plugin_from(L);
    if (!require_capability(plugin, .@"player.lookup")) {
        plugin.runtime.?.state.pushNil();
        return 1;
    }
    if (!plugin.take_op_budget()) return 0;
    const runtime = plugin.runtime.?;
    var infos: [Server.MaxPlayers]Server.PlayerInfo = undefined;
    const count = Server.snapshot_players(&infos);
    runtime.state.createTable(@intCast(count), 0);
    for (infos[0..count], 0..) |info, i| {
        push_player_info(runtime, info);
        runtime.state.rawSetI(-2, @intCast(i + 1));
    }
    return 1;
}

fn api_find_player(L: ?*luaz.c.lua_State) callconv(.c) c_int {
    const plugin = plugin_from(L);
    const runtime = plugin.runtime.?;
    if (!require_capability(plugin, .@"player.lookup")) {
        runtime.state.pushNil();
        return 1;
    }
    if (!plugin.take_op_budget()) return 0;
    const name = runtime.state.checkString(1);
    var info: Server.PlayerInfo = undefined;
    if (Server.snapshot_player_by_name(name, &info)) {
        push_player_info(runtime, info);
    } else {
        runtime.state.pushNil();
    }
    return 1;
}

fn api_send_message(L: ?*luaz.c.lua_State) callconv(.c) c_int {
    const plugin = plugin_from(L);
    const runtime = plugin.runtime.?;
    if (!require_capability(plugin, .@"player.message")) {
        runtime.state.pushBoolean(false);
        return 1;
    }
    if (!plugin.take_op_budget()) return 0;
    const handle = resolve_player_arg(runtime, 1) orelse {
        runtime.state.pushBoolean(false);
        return 1;
    };
    const text = runtime.state.checkString(2);
    const sent = message_handle(handle, text[0..@min(text.len, max_message_bytes)]);
    runtime.state.pushBoolean(sent);
    return 1;
}

fn api_broadcast(L: ?*luaz.c.lua_State) callconv(.c) c_int {
    const plugin = plugin_from(L);
    const runtime = plugin.runtime.?;
    if (!require_capability(plugin, .@"player.message")) return 0;
    if (!plugin.take_op_budget()) return 0;
    const text = runtime.state.checkString(1);
    const bounded = text[0..@min(text.len, max_message_bytes)];

    var offset: usize = 0;
    while (offset < bounded.len) {
        var payload = @min(chat_payload_max, bounded.len - offset);
        if (offset + payload < bounded.len) {
            if (std.mem.lastIndexOfScalar(u8, bounded[offset .. offset + payload], ' ')) |space| {
                if (space > 16) payload = @intCast(space);
            }
        }
        var msg: core.protocol.Message = @splat(' ');
        @memcpy(msg[0..payload], bounded[offset..][0..payload]);
        Server.broadcast_chat_message(-1, &msg);
        offset += payload;
        if (offset < bounded.len and bounded[offset] == ' ') offset += 1;
    }
    return 0;
}

fn api_teleport(L: ?*luaz.c.lua_State) callconv(.c) c_int {
    const plugin = plugin_from(L);
    const runtime = plugin.runtime.?;
    if (!require_capability(plugin, .@"player.teleport")) {
        runtime.state.pushBoolean(false);
        return 1;
    }
    if (!plugin.take_op_budget()) return 0;
    const handle = resolve_player_arg(runtime, 1) orelse {
        runtime.state.pushBoolean(false);
        return 1;
    };
    // Voluntary travel into an active, locked session's members is denied
    // here so every caller of this host action obeys match rules.
    if (plugin.owner.sessions.travel_locked_for(handle)) {
        runtime.state.pushBoolean(false);
        return 1;
    }
    const x = clamp_block(runtime.state.checkInteger(2));
    const y = clamp_block(runtime.state.checkInteger(3));
    const z = clamp_block(runtime.state.checkInteger(4));
    var yaw: u8 = 0;
    var pitch: u8 = 0;
    if (runtime.state.getTop() >= 6) {
        yaw = @bitCast(@as(i8, @truncate(runtime.state.checkInteger(5))));
        pitch = @bitCast(@as(i8, @truncate(runtime.state.checkInteger(6))));
    }
    Server.teleport_handle_block(handle, x, y, z, yaw, pitch) catch {
        runtime.state.pushBoolean(false);
        return 1;
    };
    runtime.state.pushBoolean(true);
    return 1;
}

fn clamp_block(value: luaz.State.Integer) u16 {
    if (value < 0) return 0;
    if (value > 65535) return 65535;
    return @intCast(value);
}

fn api_get_spawn(L: ?*luaz.c.lua_State) callconv(.c) c_int {
    const plugin = plugin_from(L);
    if (!require_capability(plugin, .@"player.teleport")) return 0;
    const runtime = plugin.runtime.?;
    const spawn = plugin.owner.spawn;
    runtime.state.pushInteger(spawn.x);
    runtime.state.pushInteger(spawn.y);
    runtime.state.pushInteger(spawn.z);
    return 3;
}

fn api_set_spawn(L: ?*luaz.c.lua_State) callconv(.c) c_int {
    const plugin = plugin_from(L);
    const runtime = plugin.runtime.?;
    if (!require_capability(plugin, .@"player.spawn")) {
        runtime.state.pushBoolean(false);
        return 1;
    }
    if (!plugin.take_op_budget()) return 0;
    const x = clamp_block(runtime.state.checkInteger(1));
    const y = clamp_block(runtime.state.checkInteger(2));
    const z = clamp_block(runtime.state.checkInteger(3));
    runtime.state.pushBoolean(plugin.owner.set_spawn(x, y, z));
    return 1;
}

fn api_kick(L: ?*luaz.c.lua_State) callconv(.c) c_int {
    const plugin = plugin_from(L);
    const runtime = plugin.runtime.?;
    if (!require_capability(plugin, .@"player.kick")) {
        runtime.state.pushBoolean(false);
        return 1;
    }
    if (!plugin.take_op_budget()) return 0;
    const handle = resolve_player_arg(runtime, 1) orelse {
        runtime.state.pushBoolean(false);
        return 1;
    };
    var reason_buf: [64]u8 = undefined;
    var reason: []const u8 = "Kicked";
    if (runtime.state.getTop() >= 2) {
        if (runtime.state.toString(2)) |text| {
            const len = @min(text.len, reason_buf.len);
            @memcpy(reason_buf[0..len], text[0..len]);
            reason = reason_buf[0..len];
        }
    }
    runtime.state.pushBoolean(Server.disconnect_handle(handle, reason));
    return 1;
}

fn api_log(L: ?*luaz.c.lua_State) callconv(.c) c_int {
    const plugin = plugin_from(L);
    const state = plugin.runtime.?.state;
    const text = state.checkString(1);
    log.info("[{s}] {s}", .{ plugin.manifest.name(), text[0..@min(text.len, 256)] });
    return 0;
}

fn api_now(L: ?*luaz.c.lua_State) callconv(.c) c_int {
    _ = plugin_from(L);
    const state = luaz.State{ .lua = L.? };
    state.pushInteger(@intCast(Client.now_ms()));
    return 1;
}

fn api_set_timeout(L: ?*luaz.c.lua_State) callconv(.c) c_int {
    return add_timer(L, false);
}

fn api_set_interval(L: ?*luaz.c.lua_State) callconv(.c) c_int {
    return add_timer(L, true);
}

fn add_timer(L: ?*luaz.c.lua_State, repeats: bool) c_int {
    const plugin = plugin_from(L);
    const state = luaz.State{ .lua = L.? };
    if (plugin.timer_count >= max_timers) {
        state.pushLString("timer limit reached");
        state.raiseError();
    }
    if (!state.isFunction(1)) {
        state.pushLString("set_timeout/set_interval expect a function");
        state.raiseError();
    }
    var delay = state.checkInteger(2);
    if (delay < 1) delay = 1;
    if (delay > 3_600_000) delay = 3_600_000;

    const func_ref = state.ref(1);
    state.pop(2);
    const index = plugin.timer_count;
    assert(index < max_timers);
    plugin.timers[index] = .{
        .func_ref = func_ref,
        .interval_ms = @intCast(delay),
        .next_due_ms = Client.now_ms() + delay,
        .repeats = repeats,
    };
    plugin.timer_count += 1;

    state.createTable(0, 1);
    state.pushLightUserdata(plugin);
    state.pushInteger(@intCast(index));
    state.pushCClosureK(api_timer_cancel, "cancel", 2, null);
    state.setField(-2, "cancel");
    return 1;
}

fn api_timer_cancel(L: ?*luaz.c.lua_State) callconv(.c) c_int {
    const state = luaz.State{ .lua = L.? };
    const plugin: *Plugin = @ptrCast(@alignCast(state.toLightUserdata(luaz.State.upvalueIndex(1)).?));
    const index = state.toIntegerX(luaz.State.upvalueIndex(2)) orelse return 0;
    if (index >= 0 and index < max_timers) plugin.timers[@intCast(index)].canceled = true;
    return 0;
}

fn api_on_player_join(L: ?*luaz.c.lua_State) callconv(.c) c_int {
    return add_handler(L, .join);
}

fn api_on_player_leave(L: ?*luaz.c.lua_State) callconv(.c) c_int {
    return add_handler(L, .leave);
}

fn api_on_block_attempt(L: ?*luaz.c.lua_State) callconv(.c) c_int {
    return add_handler(L, .block);
}

fn api_on_player_move(L: ?*luaz.c.lua_State) callconv(.c) c_int {
    return add_handler(L, .move);
}

fn api_on_movement_violation(L: ?*luaz.c.lua_State) callconv(.c) c_int {
    return add_handler(L, .violation);
}

const HandlerKind = enum { join, leave, block, move, violation };

fn add_handler(L: ?*luaz.c.lua_State, kind: HandlerKind) c_int {
    const plugin = plugin_from(L);
    const state = luaz.State{ .lua = L.? };
    if (!state.isFunction(1)) {
        state.pushLString("event registration expects a function");
        state.raiseError();
    }
    const refs: *[max_handlers]i32 = switch (kind) {
        .join => &plugin.join_refs,
        .leave => &plugin.leave_refs,
        .block => &plugin.block_refs,
        .move => &plugin.move_refs,
        .violation => &plugin.violation_refs,
    };
    const count = switch (kind) {
        .join => &plugin.join_count,
        .leave => &plugin.leave_count,
        .block => &plugin.block_count,
        .move => &plugin.move_count,
        .violation => &plugin.violation_count,
    };
    if (count.* >= max_handlers) {
        state.pushLString("event handler limit reached");
        state.raiseError();
    }
    assert(count.* < max_handlers);
    refs[count.*] = state.ref(1);
    state.pop(1);
    count.* += 1;
    return 0;
}

fn api_store_get(L: ?*luaz.c.lua_State) callconv(.c) c_int {
    const plugin = plugin_from(L);
    const state = luaz.State{ .lua = L.? };
    const key = state.checkString(1);
    _ = plugin.runtime.?.state.getRef(plugin.store_ref);
    state.pushLString(key);
    _ = state.getTable(-2);
    state.remove(-2);
    return 1;
}

fn api_store_set(L: ?*luaz.c.lua_State) callconv(.c) c_int {
    const plugin = plugin_from(L);
    const runtime = plugin.runtime.?;
    const state = luaz.State{ .lua = L.? };
    if (!plugin.take_op_budget()) return 0;
    const key = state.checkString(1);
    if (key.len == 0 or key.len > 64) {
        state.pushLString("store keys must be 1-64 characters");
        state.raiseError();
    }
    switch (state.getType(2)) {
        .string, .boolean, .number => {},
        else => {
            state.pushLString("store values must be strings, numbers, or booleans");
            state.raiseError();
        },
    }
    _ = runtime.state.getRef(plugin.store_ref);
    state.pushLString(key);
    state.pushValue(2);
    state.rawSet(-3);
    state.pop(1);
    plugin.owner.save_store(plugin);
    return 0;
}

// ------------------------------------------------------------ sessions

fn session_from(L: ?*luaz.c.lua_State) ?*Sessions.Session {
    const state = luaz.State{ .lua = L.? };
    const session: *Sessions.Session = @ptrCast(@alignCast(state.toLightUserdata(luaz.State.upvalueIndex(1)).?));
    const generation = state.toIntegerX(luaz.State.upvalueIndex(2)) orelse return null;
    if (!session.active or session.generation != generation) return null;
    return session;
}

fn bind_session_method(runtime: *RuntimeMod.Runtime, session: *Sessions.Session, name: [:0]const u8, func: luaz.State.CFunction) void {
    const state = runtime.state;
    state.pushLightUserdata(session);
    state.pushInteger(@intCast(session.generation));
    state.pushCClosureK(func, name.ptr, 2, null);
    state.setField(-2, name);
}

fn push_session_object(runtime: *RuntimeMod.Runtime, session: *Sessions.Session) void {
    const state = runtime.state;
    state.createTable(0, 8);
    bind_session_method(runtime, session, "admit", api_session_admit);
    bind_session_method(runtime, session, "remove", api_session_remove);
    bind_session_method(runtime, session, "contains", api_session_contains);
    bind_session_method(runtime, session, "members", api_session_members);
    bind_session_method(runtime, session, "announce", api_session_announce);
    bind_session_method(runtime, session, "travel", api_session_travel);
    bind_session_method(runtime, session, "lock_travel", api_session_lock_travel);
    bind_session_method(runtime, session, "finish", api_session_finish);
}

fn api_create_session(L: ?*luaz.c.lua_State) callconv(.c) c_int {
    const plugin = plugin_from(L);
    const runtime = plugin.runtime.?;
    const state = runtime.state;
    if (!require_capability(plugin, .@"session.host")) {
        state.pushNil();
        return 1;
    }
    if (!plugin.take_op_budget()) return 0;
    var capacity: usize = Sessions.max_members;
    if (state.getTop() >= 1 and state.getType(1) == .table) {
        _ = state.getField(1, "capacity");
        defer state.pop(1);

        if (state.toIntegerX(-1)) |n| capacity = @intCast(@max(n, 1));
    }
    const session = plugin.owner.sessions.create(plugin, capacity) orelse {
        state.pushNil();
        return 1;
    };
    push_session_object(runtime, session);
    return 1;
}

fn api_session_admit(L: ?*luaz.c.lua_State) callconv(.c) c_int {
    const state = luaz.State{ .lua = L.? };
    const session = session_from(L) orelse {
        state.pushBoolean(false);
        return 1;
    };
    const plugin = session.owner;
    const runtime = plugin.runtime.?;
    if (!require_capability(plugin, .@"session.host")) {
        state.pushBoolean(false);
        return 1;
    }
    if (!plugin.take_op_budget()) return 0;
    const handle = resolve_player_arg(runtime, 1) orelse {
        state.pushBoolean(false);
        return 1;
    };
    // Only gameplay-ready players join sessions, and membership is exclusive
    // server-wide so one player can never sit in two minigames.
    const info = resolve_info(handle) orelse {
        state.pushBoolean(false);
        return 1;
    };
    if (!info.authenticated) {
        state.pushBoolean(false);
        return 1;
    }
    var role: []const u8 = "participant";
    if (state.getTop() >= 2) {
        if (state.toString(2)) |text| role = text[0..@min(text.len, 12)];
    }
    const spot: Sessions.ReturnSpot = .{
        .x = info.x,
        .y = info.y,
        .z = info.z,
        .yaw = info.yaw,
        .pitch = info.pitch,
        .valid = true,
    };
    state.pushBoolean(plugin.owner.sessions.admit(session, handle, spot, role));
    return 1;
}

fn api_session_remove(L: ?*luaz.c.lua_State) callconv(.c) c_int {
    const state = luaz.State{ .lua = L.? };
    const session = session_from(L) orelse {
        state.pushBoolean(false);
        return 1;
    };
    const plugin = session.owner;
    if (!require_capability(plugin, .@"session.host")) {
        state.pushBoolean(false);
        return 1;
    }
    if (!plugin.take_op_budget()) return 0;
    const runtime = plugin.runtime.?;
    const handle = resolve_player_arg(runtime, 1) orelse {
        state.pushBoolean(false);
        return 1;
    };
    state.pushBoolean(session.remove(handle));
    return 1;
}

fn api_session_contains(L: ?*luaz.c.lua_State) callconv(.c) c_int {
    const state = luaz.State{ .lua = L.? };
    const session = session_from(L) orelse {
        state.pushBoolean(false);
        return 1;
    };
    const plugin = session.owner;
    if (!require_capability(plugin, .@"session.host")) {
        state.pushBoolean(false);
        return 1;
    }
    const runtime = plugin.runtime.?;
    const handle = resolve_player_arg(runtime, 1) orelse {
        state.pushBoolean(false);
        return 1;
    };
    state.pushBoolean(session.contains(handle));
    return 1;
}

fn api_session_members(L: ?*luaz.c.lua_State) callconv(.c) c_int {
    const state = luaz.State{ .lua = L.? };
    const session = session_from(L) orelse {
        state.createTable(0, 0);
        return 1;
    };
    const plugin = session.owner;
    if (!require_capability(plugin, .@"session.host")) {
        state.createTable(0, 0);
        return 1;
    }
    const runtime = plugin.runtime.?;
    if (!plugin.take_op_budget()) return 0;
    state.createTable(@intCast(session.member_count), 0);
    var count: i32 = 0;
    for (session.members[0..session.member_count]) |*member| {
        const info = resolve_info(member.handle) orelse continue;
        push_player_info(runtime, info);
        state.pushLString(member.role());
        state.setField(-2, "role");
        count += 1;
        state.rawSetI(-2, count);
    }
    return 1;
}

fn api_session_announce(L: ?*luaz.c.lua_State) callconv(.c) c_int {
    const state = luaz.State{ .lua = L.? };
    const session = session_from(L) orelse return 0;
    const plugin = session.owner;
    if (!require_capability(plugin, .@"session.host")) return 0;
    if (!plugin.take_op_budget()) return 0;
    const text = state.checkString(1);
    const bounded = text[0..@min(text.len, max_message_bytes)];
    for (session.members[0..session.member_count]) |*member| {
        _ = message_handle(member.handle, bounded);
    }
    return 0;
}

fn api_session_travel(L: ?*luaz.c.lua_State) callconv(.c) c_int {
    const state = luaz.State{ .lua = L.? };
    const session = session_from(L) orelse {
        state.pushBoolean(false);
        return 1;
    };
    const plugin = session.owner;
    const runtime = plugin.runtime.?;
    if (!require_capability(plugin, .@"session.host")) {
        state.pushBoolean(false);
        return 1;
    }
    if (!plugin.take_op_budget()) return 0;
    const handle = resolve_player_arg(runtime, 1) orelse {
        state.pushBoolean(false);
        return 1;
    };
    // Session-authorized travel covers only this session's own members.
    if (session.find_member(handle) == null) {
        state.pushBoolean(false);
        return 1;
    }
    const x = clamp_block(runtime.state.checkInteger(2));
    const y = clamp_block(runtime.state.checkInteger(3));
    const z = clamp_block(runtime.state.checkInteger(4));
    var yaw: u8 = 0;
    var pitch: u8 = 0;
    if (runtime.state.getTop() >= 6) {
        yaw = @bitCast(@as(i8, @truncate(runtime.state.checkInteger(5))));
        pitch = @bitCast(@as(i8, @truncate(runtime.state.checkInteger(6))));
    }
    Server.teleport_handle_block(handle, x, y, z, yaw, pitch) catch {
        state.pushBoolean(false);
        return 1;
    };
    state.pushBoolean(true);
    return 1;
}

fn api_session_lock_travel(L: ?*luaz.c.lua_State) callconv(.c) c_int {
    const state = luaz.State{ .lua = L.? };
    const session = session_from(L) orelse return 0;
    const plugin = session.owner;
    if (!require_capability(plugin, .@"session.host")) return 0;
    session.travel_locked = state.optBoolean(1, true);
    return 0;
}

fn api_session_finish(L: ?*luaz.c.lua_State) callconv(.c) c_int {
    const state = luaz.State{ .lua = L.? };
    const session = session_from(L) orelse {
        state.pushBoolean(false);
        return 1;
    };
    const plugin = session.owner;
    if (!require_capability(plugin, .@"session.host")) {
        state.pushBoolean(false);
        return 1;
    }
    session.end(plugin.owner.return_spot(), true);
    state.pushBoolean(true);
    return 1;
}

// -------------------------------------------------------------- regions

fn region_from(L: ?*luaz.c.lua_State) ?*Regions.Region {
    const state = luaz.State{ .lua = L.? };
    const region: *Regions.Region = @ptrCast(@alignCast(state.toLightUserdata(luaz.State.upvalueIndex(1)).?));
    const generation = state.toIntegerX(luaz.State.upvalueIndex(2)) orelse return null;
    if (!region.active or region.generation != generation) return null;
    return region;
}

fn read_box(state: luaz.State, index: i32) ?Regions.Box {
    if (state.getType(index) != .table) return null;
    var raw: [6]i64 = undefined;
    const names = [_][:0]const u8{ "x0", "y0", "z0", "x1", "y1", "z1" };
    for (names, 0..) |name, i| {
        _ = state.getField(index, name);
        defer state.pop(1);

        const value = state.toIntegerX(-1) orelse return null;
        if (value < 0 or value > 65535) return null;
        raw[i] = value;
    }
    return .{
        .x0 = @intCast(@min(raw[0], raw[3])),
        .y0 = @intCast(@min(raw[1], raw[4])),
        .z0 = @intCast(@min(raw[2], raw[5])),
        .x1 = @intCast(@max(raw[0], raw[3])),
        .y1 = @intCast(@max(raw[1], raw[4])),
        .z1 = @intCast(@max(raw[2], raw[5])),
    };
}

fn push_region_object(runtime: *RuntimeMod.Runtime, region: *Regions.Region) void {
    const state = runtime.state;
    state.createTable(0, 2);
    state.pushLightUserdata(region);
    state.pushInteger(@intCast(region.generation));
    state.pushCClosureK(api_region_release, "release", 2, null);
    state.setField(-2, "release");
    state.pushLightUserdata(region);
    state.pushInteger(@intCast(region.generation));
    state.pushCClosureK(api_region_contains, "contains", 2, null);
    state.setField(-2, "contains");
}

fn api_claim(L: ?*luaz.c.lua_State) callconv(.c) c_int {
    const plugin = plugin_from(L);
    const runtime = plugin.runtime.?;
    const state = runtime.state;
    if (!require_capability(plugin, .@"world.edit")) {
        state.pushNil();
        return 1;
    }
    if (!plugin.take_op_budget()) return 0;
    const box = read_box(state, 1) orelse {
        state.pushNil();
        return 1;
    };
    if (!world.active or !box_in_world_bounds(box)) {
        state.pushNil();
        return 1;
    }
    var frozen = true;
    if (state.getTop() >= 2 and state.getType(2) == .table) {
        _ = state.getField(2, "frozen");
        defer state.pop(1);

        if (!state.isNil(-1)) frozen = state.toBoolean(-1);
    }
    const region = plugin.owner.regions.claim(plugin, box, frozen) orelse {
        state.pushNil();
        return 1;
    };
    push_region_object(runtime, region);
    return 1;
}

fn box_in_world_bounds(box: Regions.Box) bool {
    const dims = world.data.dims;
    return box.x1 < dims.length and box.y1 < dims.height and box.z1 < dims.depth;
}

fn api_region_release(L: ?*luaz.c.lua_State) callconv(.c) c_int {
    const region = region_from(L) orelse return 0;
    Regions.Region.release(region);
    return 0;
}

fn api_region_contains(L: ?*luaz.c.lua_State) callconv(.c) c_int {
    const state = luaz.State{ .lua = L.? };
    const region = region_from(L) orelse {
        state.pushBoolean(false);
        return 1;
    };
    const plugin = region.owner;
    const runtime = plugin.runtime.?;
    const handle = resolve_player_arg(runtime, 1) orelse {
        state.pushBoolean(false);
        return 1;
    };
    const info = resolve_info(handle) orelse {
        state.pushBoolean(false);
        return 1;
    };
    state.pushBoolean(region.box.contains(info.x, info.y, info.z));
    return 1;
}

// ----------------------------------------------------------- arena jobs

fn api_fill(L: ?*luaz.c.lua_State) callconv(.c) c_int {
    const plugin = plugin_from(L);
    const runtime = plugin.runtime.?;
    const state = runtime.state;
    if (!require_capability(plugin, .@"world.edit")) {
        state.pushBoolean(false);
        return 1;
    }
    if (!plugin.take_op_budget()) return 0;
    const box = read_box(state, 1) orelse {
        state.pushLString("fill expects a box table with x0..z1");
        state.raiseError();
    };
    const block_name = state.checkString(2);
    const block: core.blocks.Block = blk: {
        inline for (@typeInfo(core.blocks.Block).@"enum".fields) |field| {
            if (std.mem.eql(u8, field.name, block_name)) break :blk @enumFromInt(field.value);
        }
        state.pushLString("unknown block name");
        state.raiseError();
    };
    if (!state.isFunction(3)) {
        state.pushLString("fill expects a completion callback");
        state.raiseError();
    }
    const done_ref = state.ref(3);
    if (plugin.owner.jobs.enqueue_fill(plugin, box, block, done_ref) == null) {
        state.unref(done_ref);
        state.pushLString("fill rejected: the box must lie inside one of your claims within the world bounds");
        state.raiseError();
    }
    state.pushBoolean(true);
    return 1;
}

fn api_restore(L: ?*luaz.c.lua_State) callconv(.c) c_int {
    const plugin = plugin_from(L);
    const runtime = plugin.runtime.?;
    const state = runtime.state;
    if (!require_capability(plugin, .@"world.edit")) {
        state.pushBoolean(false);
        return 1;
    }
    if (!plugin.take_op_budget()) return 0;
    const box = read_box(state, 1) orelse {
        state.pushLString("restore expects a box table with x0..z1");
        state.raiseError();
    };
    const key = state.checkString(2);
    if (!state.isFunction(3)) {
        state.pushLString("restore expects a completion callback");
        state.raiseError();
    }
    const done_ref = state.ref(3);
    if (plugin.owner.jobs.enqueue_restore(plugin, box, key, done_ref) == null) {
        state.unref(done_ref);
        state.pushLString("restore rejected: no matching captured template inside your claims");
        state.raiseError();
    }
    state.pushBoolean(true);
    return 1;
}

fn api_capture(L: ?*luaz.c.lua_State) callconv(.c) c_int {
    const plugin = plugin_from(L);
    const runtime = plugin.runtime.?;
    if (!require_capability(plugin, .@"world.edit")) {
        runtime.state.pushBoolean(false);
        return 1;
    }
    if (!plugin.take_op_budget()) return 0;
    const box = read_box(runtime.state, 1) orelse {
        runtime.state.pushBoolean(false);
        return 1;
    };
    const key = runtime.state.checkString(2);
    runtime.state.pushBoolean(plugin.owner.jobs.capture(plugin, box, key));
    return 1;
}

fn api_mark_dirty(L: ?*luaz.c.lua_State) callconv(.c) c_int {
    const plugin = plugin_from(L);
    const runtime = plugin.runtime.?;
    if (!require_capability(plugin, .@"world.edit")) {
        runtime.state.pushBoolean(false);
        return 1;
    }
    if (!plugin.take_op_budget()) return 0;
    const box = read_box(runtime.state, 1) orelse {
        runtime.state.pushBoolean(false);
        return 1;
    };
    const key = runtime.state.checkString(2);
    runtime.state.pushBoolean(plugin.owner.jobs.mark_dirty(plugin, box, key));
    return 1;
}

fn api_clear_dirty(L: ?*luaz.c.lua_State) callconv(.c) c_int {
    const plugin = plugin_from(L);
    const runtime = plugin.runtime.?;
    if (!require_capability(plugin, .@"world.edit")) {
        runtime.state.pushBoolean(false);
        return 1;
    }
    if (!plugin.take_op_budget()) return 0;
    const key = runtime.state.checkString(1);
    runtime.state.pushBoolean(plugin.owner.jobs.clear_dirty(plugin, key));
    return 1;
}
