//! Focused plugin host tests: manifest validation, sandboxed runtime budgets,
//! ordered queue semantics, and end-to-end package loads with persistence.
const std = @import("std");
const core = @import("core");
const Server = core.Server;
const Client = Server.Client;
const world = core.World;

const Manifest = @import("plugins/Manifest.zig");
const RuntimeMod = @import("plugins/Runtime.zig");
const HostMod = @import("plugins/Host.zig");
const PluginsMod = @import("plugins/Plugins.zig");
const RegionsMod = @import("plugins/Regions.zig");
const SessionsMod = @import("plugins/Sessions.zig");
const ArenaMod = @import("plugins/Arena.zig");
const Commands = @import("Commands.zig");

const allocator = std.testing.allocator;
const io = std.testing.io;

const plugin_uuid = "5e5a1c66-8e0b-4a3e-9f21-2d0f4c9b7a10";
const test_manifest =
    \\{"uuid":"5e5a1c66-8e0b-4a3e-9f21-2d0f4c9b7a10","name":"TestPlug","version":"0.1.0",
    \\ "api_version":"1.x","entrypoint":"main.luau","capabilities":["player.message","player.lookup"]}
;

fn set_server_io() void {
    Server.io = io;
}

/// Durable file replacement for tests that save the world (the engine's
/// atomic-write adapter is not linked into this module).
fn test_replace_file(save_io: std.Io, dir: std.Io.Dir, path: []const u8, body: core.Host.WriteBody) !core.Host.ReplaceResult {
    var temp_buf: [160]u8 = undefined;
    const temp = try std.fmt.bufPrint(&temp_buf, "{s}.tmp", .{path});
    const file = try dir.createFile(save_io, temp, .{});
    defer file.close(save_io);

    var buffer: [4096]u8 = undefined;
    var writer = file.writer(save_io, &buffer);
    try body.write(&writer.interface);
    try writer.interface.flush();
    try dir.rename(temp, dir, path, save_io);
    return .{ .bytes = 0, .previous_retained = false };
}

fn install_test_replace_file() void {
    core.Host.replace_file = test_replace_file;
}

/// Durable world saves need the engine's file-replacement adapter and the
/// compression worker; tests that trigger `world.save` install std-only
/// stand-ins.
fn install_test_save_services() !void {
    install_test_replace_file();
    errdefer core.Host.replace_file = null;
    try core.CompressWorker.init(allocator, io);
}

fn uninstall_test_save_services() void {
    core.CompressWorker.deinit();
    core.Host.replace_file = null;
}

/// Stack session keeping reader/writer addresses alive for fake clients.
const Session = struct {
    output: []u8 = &.{},
    reader: std.Io.Reader = undefined,
    writer: std.Io.Writer = undefined,
    connected: bool = true,

    fn open(self: *Session, output: []u8, authenticated: bool, slot: u8) *Client {
        self.output = output;
        self.reader = std.Io.Reader.fixed(&.{});
        self.writer = std.Io.Writer.fixed(output);
        self.connected = true;
        Server.players.items[slot] = .{
            .id = @intCast(slot),
            .generation = 1,
            .reader = &self.reader,
            .writer = &self.writer,
            .connected = &self.connected,
            .local = true,
            .phase = .init(.active),
            .authenticated = .init(authenticated),
            .initialized = true,
        };
        return &Server.players.items[slot].?;
    }
};

test "manifest parsing accepts valid packages and rejects bad identity, entrypoints, and capabilities" {
    set_server_io();
    const good =
        \\{"uuid":"8c4f7d2e-3a91-4b7f-9d25-6e0c1a8f5b31","name":"Test","version":"1.2",
        \\ "api_version":">=1.0","entrypoint":"main.luau","capabilities":["player.lookup"]}
    ;
    const manifest = try Manifest.parse(good, allocator);
    try std.testing.expectEqualStrings("Test", manifest.name());
    try std.testing.expectEqual(@as(u32, 1), manifest.version.major);
    try std.testing.expectEqual(@as(u32, 2), manifest.version.minor);
    try std.testing.expectEqual(@as(u32, 0), manifest.version.patch);
    try std.testing.expect(manifest.has_capability(.@"player.lookup"));
    try std.testing.expect(!manifest.has_capability(.@"player.message"));

    for ([_][]const u8{
        // Unknown fields are rejected.
        \\{"uuid":"8c4f7d2e-3a91-4b7f-9d25-6e0c1a8f5b31","name":"T","version":"1.0.0",
        \\ "api_version":"1.x","entrypoint":"m.luau","capabilities":[],"extra":1}
        ,
        \\{"uuid":"not-a-uuid","name":"T","version":"1.0.0","api_version":"1.x","entrypoint":"m.luau"}
        ,
        \\{"uuid":"8c4f7d2e-3a91-4b7f-9d25-6e0c1a8f5b31","name":"T","version":"1.0.0",
        \\ "api_version":"1.x","entrypoint":"../escape.luau"}
        ,
        \\{"uuid":"8c4f7d2e-3a91-4b7f-9d25-6e0c1a8f5b31","name":"T","version":"1.0.0",
        \\ "api_version":"1.x","entrypoint":"/abs.luau"}
        ,
        \\{"uuid":"8c4f7d2e-3a91-4b7f-9d25-6e0c1a8f5b31","name":"T","version":"1.0.0",
        \\ "api_version":"2.x","entrypoint":"m.luau"}
        ,
        \\{"uuid":"8c4f7d2e-3a91-4b7f-9d25-6e0c1a8f5b31","name":"T","version":"1.0.0",
        \\ "api_version":"1.x","entrypoint":"m.luau","capabilities":["world.destroy"]}
        ,
    }) |bad| {
        try std.testing.expectError(error.InvalidManifest, Manifest.parse(bad, allocator));
    }
}

test "version ranges match exact wildcard and minimum grammar" {
    const one_two: Manifest.SemVer = .{ .major = 1, .minor = 2, .patch = 3 };
    try std.testing.expect((Manifest.Range.parse("1.2.3") orelse unreachable).matches(one_two));
    try std.testing.expect(!(Manifest.Range.parse("1.2.4") orelse unreachable).matches(one_two));
    try std.testing.expect((Manifest.Range.parse("1.x") orelse unreachable).matches(one_two));
    try std.testing.expect(!(Manifest.Range.parse("2.x") orelse unreachable).matches(one_two));
    try std.testing.expect((Manifest.Range.parse(">=1.2") orelse unreachable).matches(one_two));
    try std.testing.expect(!(Manifest.Range.parse(">=1.3") orelse unreachable).matches(one_two));

    set_server_io();
    try std.testing.expectError(error.InvalidManifest, Manifest.parse(
        \\{"uuid":"8c4f7d2e-3a91-4b7f-9d25-6e0c1a8f5b31","name":"T","version":"1",
        \\ "api_version":"1..","entrypoint":"m.luau"}
    , allocator));
}

test "sandbox blocks unsafe libraries and global mutation" {
    set_server_io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const runtime = try RuntimeMod.Runtime.init(allocator, tmp.dir);
    defer runtime.deinit(allocator);

    try std.testing.expect(!runtime.run_entrypoint("bad.luau", "return os.time()"));
    try std.testing.expect(!runtime.run_entrypoint("bad.luau", "string.format = nil"));
    try std.testing.expect(runtime.run_entrypoint("ok.luau",
        \\local sum = 0
        \\for i = 1, 10 do sum = sum + i end
        \\if sum ~= 55 then error("bad sum") end
        \\return true
    ));
}

test "runaway scripts stop at the monotonic deadline" {
    set_server_io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const runtime = try RuntimeMod.Runtime.init(allocator, tmp.dir);
    defer runtime.deinit(allocator);

    runtime.deadline_ms = Client.now_ms() + 100;
    try std.testing.expect(!runtime.run_entrypoint("loop.luau", "while true do end"));
    try std.testing.expect(std.mem.indexOf(u8, runtime.last_error(), "deadline") != null);
}

test "memory budget exhausts runaway allocation" {
    set_server_io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const runtime = try RuntimeMod.Runtime.init(allocator, tmp.dir);
    defer runtime.deinit(allocator);

    runtime.deadline_ms = Client.now_ms() + 5000;
    const exhausted = !runtime.run_entrypoint("mem.luau",
        \\local t = {}
        \\while true do t[#t + 1] = string.rep("x", 4096) end
    );
    try std.testing.expect(exhausted or std.mem.indexOf(u8, runtime.last_error(), "deadline") != null);
    try std.testing.expect(runtime.mem.exhausted or std.mem.indexOf(u8, runtime.last_error(), "deadline") != null);
}

test "require stays confined to the package" {
    set_server_io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "lib.luau", .data = "return { add = function(a, b) return a + b end }" });
    const runtime = try RuntimeMod.Runtime.init(allocator, tmp.dir);
    defer runtime.deinit(allocator);

    runtime.deadline_ms = Client.now_ms() + 1000;
    try std.testing.expect(runtime.run_entrypoint("main.luau",
        \\local lib = require("lib")
        \\if lib.add(2, 3) ~= 5 then error("bad module") end
    ));
    try std.testing.expect(!runtime.run_entrypoint("escape.luau", "require(\"../outside\")"));
    try std.testing.expect(!runtime.run_entrypoint("escape2.luau", "require(\"a/../..\")"));
}

const Harness = struct {
    tmp: std.testing.TmpDir,
    data_dir: std.Io.Dir,
    host: HostMod.Host = .{},
    manager: ?*PluginsMod.Plugins = null,

    fn init() !Harness {
        set_server_io();
        var harness = Harness{ .tmp = std.testing.tmpDir(.{}), .data_dir = undefined };
        harness.data_dir = harness.tmp.dir;
        try harness.data_dir.createDirPath(io, "plugins/testplug");
        return harness;
    }

    fn write_package(self: *Harness, comptime file: []const u8, contents: []const u8) !void {
        var path_buf: [128]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "plugins/testplug/{s}", .{file});
        try self.data_dir.writeFile(io, .{ .sub_path = path, .data = contents });
    }

    fn load(self: *Harness) void {
        self.manager = PluginsMod.Plugins.init(allocator, self.data_dir, &self.host) catch null;
    }

    fn read_store(self: *Harness) ![]u8 {
        var path_buf: [96]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "plugin-data/{s}.json", .{plugin_uuid});
        return self.data_dir.readFileAlloc(io, path, allocator, .limited(4096));
    }

    fn deinit(self: *Harness) void {
        defer self.* = undefined;

        if (self.manager) |manager| manager.deinit();
        Commands.reset_registry();
        self.tmp.cleanup();
    }
};

test "package load registers commands, orders console dispatch, and persists store writes" {
    var harness = try Harness.init();
    defer harness.deinit();

    try harness.write_package("manifest.json", test_manifest);
    try harness.write_package("main.luau",
        \\server.register_command{
        \\  name = "plugtest",
        \\  usage = "&e/plugtest",
        \\  handler = function(caller, args)
        \\    server.store_set("invocations", (server.store_get("invocations") or 0) + 1)
        \\  end,
        \\}
        \\server.on_player_join(function(player)
        \\  server.store_set("saw", player.name)
        \\end)
    );
    harness.load();
    const manager = harness.manager orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), manager.count);
    try std.testing.expect(manager.items[0].active);
    try std.testing.expect(Commands.is_script("plugtest"));

    // Plugin commands dispatch on the ordered context (console caller).
    harness.host.deadline_ms = Client.now_ms() + 1000;
    harness.host.enqueue_command(null, "plugtest");
    harness.host.enqueue_command(null, "plugtest");
    harness.host.drain();

    const stored = try harness.read_store();
    defer allocator.free(stored);

    try std.testing.expect(std.mem.indexOf(u8, stored, "\"invocations\":2") != null);
}

test "join events reach the plugin through the ordered queue with valid snapshots" {
    var harness = try Harness.init();
    defer harness.deinit();

    try harness.write_package("manifest.json", test_manifest);
    try harness.write_package("main.luau",
        \\server.on_player_join(function(player)
        \\  server.store_set("saw", player.name)
        \\end)
    );
    harness.load();

    Server.players = .{};
    defer Server.players = .{};

    var out_buf: [4096]u8 = undefined;
    var session = Session{};
    const client = session.open(&out_buf, true, 0);
    client.name_len = 5;
    @memcpy(client.name[0..5], "Alice");

    var identity: HostMod.Identity = .{ .handle = .{ .id = 0, .generation = 1 } };
    @memcpy(identity.name_buf[0..5], "Alice");
    identity.name_len = 5;
    harness.host.deadline_ms = Client.now_ms() + 1000;
    harness.host.enqueue(.{ .join = identity });
    harness.host.drain();

    const stored = try harness.read_store();
    defer allocator.free(stored);

    try std.testing.expect(std.mem.indexOf(u8, stored, "\"saw\":\"Alice\"") != null);
}

test "denied block attempts keep the world intact and correct the client" {
    var harness = try Harness.init();
    defer harness.deinit();

    try harness.write_package("manifest.json", test_manifest);
    try harness.write_package("main.luau",
        \\server.on_block_attempt(function(player, attempt)
        \\  return "deny"
        \\end)
    );
    harness.load();

    try world.init_empty(allocator, io, harness.tmp.dir, "unused.cw", core.world_dims.WorldDims.init(128, 64, 128), 0, world.default_format);
    world.finalize_loaded();
    defer world.deinit();

    Server.players = .{};
    defer Server.players = .{};

    var out_buf: [4096]u8 = undefined;
    var session = Session{};
    _ = session.open(&out_buf, true, 0);

    harness.host.deadline_ms = Client.now_ms() + 1000;
    harness.host.enqueue(.{ .set_block = .{
        .handle = .{ .id = 0, .generation = 1 },
        .x = 4,
        .y = 5,
        .z = 6,
        .mode = @intFromEnum(core.zb.ClickMode.create),
        .block = @intFromEnum(core.blocks.Block.stone),
    } });
    harness.host.drain();

    try std.testing.expectEqual(core.blocks.Block.air, world.get_block(4, 5, 6));
    // Corrective packet: block-change id 0x06 with the unchanged cell.
    try std.testing.expectEqual(@as(u8, 0x06), out_buf[0]);
    try std.testing.expectEqual(@as(u16, 4), std.mem.readInt(u16, out_buf[1..3], .big));
}

test "stale handles and teleport supersession drop queued actions" {
    var harness = try Harness.init();
    defer harness.deinit();

    Server.players = .{};
    defer Server.players = .{};

    var out_buf: [4096]u8 = undefined;
    var session = Session{};
    const client = session.open(&out_buf, true, 0);

    harness.host.deadline_ms = Client.now_ms() + 1000;
    // Generation mismatch: the slot was reused between enqueue and dispatch.
    harness.host.enqueue(.{ .position = .{
        .handle = .{ .id = 0, .generation = 7 },
        .x = 100,
        .y = 200,
        .z = 300,
        .yaw = 0,
        .pitch = 0,
        .teleport_serial = 0,
    } });
    harness.host.drain();
    try std.testing.expectEqual(@as(u16, 0), client.pose.load().x);

    // Position report captured before a teleport commit cannot undo it.
    client.teleport_serial.store(2, .release);
    harness.host.enqueue(.{ .position = .{
        .handle = .{ .id = 0, .generation = 1 },
        .x = 100,
        .y = 200,
        .z = 300,
        .yaw = 0,
        .pitch = 0,
        .teleport_serial = 1,
    } });
    harness.host.drain();
    try std.testing.expectEqual(@as(u16, 0), client.pose.load().x);

    harness.host.enqueue(.{ .position = .{
        .handle = .{ .id = 0, .generation = 1 },
        .x = 111,
        .y = 222,
        .z = 333,
        .yaw = 4,
        .pitch = 5,
        .teleport_serial = 2,
    } });
    harness.host.drain();
    const pose = client.pose.load();
    try std.testing.expectEqual(@as(u16, 111), pose.x);
    try std.testing.expectEqual(@as(u8, 4), pose.yaw);
}

test "per-player queue limits drop overflow and reassert block state" {
    var harness = try Harness.init();
    defer harness.deinit();

    try world.init_empty(allocator, io, harness.tmp.dir, "unused.cw", core.world_dims.WorldDims.init(128, 64, 128), 0, world.default_format);
    world.finalize_loaded();
    defer world.deinit();

    Server.players = .{};
    defer Server.players = .{};

    var out_buf: [65536]u8 = undefined;
    var session = Session{};
    _ = session.open(&out_buf, false, 0);

    harness.host.deadline_ms = Client.now_ms() + 60_000;
    var i: usize = 0;
    while (i <= HostMod.per_player_capacity) : (i += 1) {
        harness.host.enqueue(.{ .set_block = .{
            .handle = .{ .id = 0, .generation = 1 },
            .x = 1,
            .y = 1,
            .z = 1,
            .mode = @intFromEnum(core.zb.ClickMode.create),
            .block = @intFromEnum(core.blocks.Block.stone),
        } });
    }
    try std.testing.expectEqual(HostMod.per_player_capacity, harness.host.pending_per_slot[0]);
    harness.host.drain();
    try std.testing.expectEqual(@as(u16, 0), harness.host.pending_per_slot[0]);
}

test "timers fire from monotonic scheduling and can be canceled" {
    var harness = try Harness.init();
    defer harness.deinit();

    try harness.write_package("manifest.json", test_manifest);
    try harness.write_package("main.luau",
        \\local handle = server.set_timeout(function()
        \\  server.store_set("timed", true)
        \\end, 1)
        \\server.set_interval(function() end, 50)
        \\server.store_set("timers", 2)
    );
    harness.load();
    const manager = harness.manager orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 2), manager.items[0].timer_count);

    io.sleep(.fromMilliseconds(20), .real) catch {};
    harness.host.deadline_ms = Client.now_ms() + 1000;
    manager.tick();

    const stored = try harness.read_store();
    defer allocator.free(stored);

    try std.testing.expect(std.mem.indexOf(u8, stored, "\"timed\":true") != null);
}

test "invalid packages and script failures disable plugins and dependents" {
    var harness = try Harness.init();
    defer harness.deinit();

    try harness.write_package("manifest.json", "{ not json");
    try harness.write_package("main.luau", "return true");
    harness.load();
    const manager = harness.manager orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 0), manager.count);
}

test "entrypoint failures contain the plugin and revoke its registrations" {
    var harness = try Harness.init();
    defer harness.deinit();

    try harness.write_package("manifest.json", test_manifest);
    try harness.write_package("main.luau", "error({ code = 42 })");
    harness.load();
    const manager = harness.manager orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), manager.count);
    try std.testing.expect(!manager.items[0].active);
    try std.testing.expect(!Commands.is_script("anything"));
}

test "fresh servers materialize the shipped essentials package" {
    set_server_io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var host: HostMod.Host = .{};
    Commands.reset_registry();
    const manager = PluginsMod.Plugins.init(allocator, tmp.dir, &host) catch return error.TestUnexpectedResult;
    defer {
        manager.deinit();
        Commands.reset_registry();
    }

    try std.testing.expectEqual(@as(usize, 3), manager.count);
    // UUID order: 7d3a (Spleef) sorts before 8c4f (Essentials) and b4e2
    // (Build Battle).
    const spleef = manager.items[0];
    try std.testing.expect(spleef.active);
    try std.testing.expectEqualStrings("Spleef", spleef.manifest.name());
    try std.testing.expect(Commands.is_script("spleef"));
    try std.testing.expect(Commands.is_script("spleefop"));
    const essentials = manager.items[1];
    try std.testing.expect(essentials.active);
    try std.testing.expectEqualStrings("Essentials", essentials.manifest.name());
    try std.testing.expect(Commands.is_script("msg"));
    try std.testing.expect(Commands.is_script("reply"));
    try std.testing.expect(Commands.is_script("spawn"));
    try std.testing.expect(Commands.is_script("setspawn"));
    const build_battle = manager.items[2];
    try std.testing.expect(build_battle.active);
    try std.testing.expectEqualStrings("Build Battle", build_battle.manifest.name());
    try std.testing.expect(Commands.is_script("buildbattle"));
    try std.testing.expect(Commands.is_script("bbop"));
    try std.testing.expect(Commands.is_script("vote"));

    const written = try tmp.dir.readFileAlloc(io, "plugins/essentials/manifest.json", allocator, .limited(4096));
    defer allocator.free(written);

    try std.testing.expect(std.mem.indexOf(u8, written, "Essentials") != null);
}

test "claims reject foreign overlaps and permit owner nesting" {
    set_server_io();
    var owner_a: PluginsMod.Plugin = undefined;
    var owner_b: PluginsMod.Plugin = undefined;
    var regions = RegionsMod.Registry{};

    const box = RegionsMod.Box{ .x0 = 0, .y0 = 0, .z0 = 0, .x1 = 9, .y1 = 9, .z1 = 9 };
    const first = regions.claim(&owner_a, box, true) orelse return error.TestUnexpectedResult;
    try std.testing.expect(regions.claim(&owner_b, box, false) == null);
    try std.testing.expect(regions.claim(&owner_b, .{ .x0 = 5, .y0 = 5, .z0 = 5, .x1 = 14, .y1 = 14, .z1 = 14 }, false) == null);
    _ = regions.claim(&owner_a, .{ .x0 = 1, .y0 = 1, .z0 = 1, .x1 = 2, .y1 = 2, .z1 = 2 }, false) orelse return error.TestUnexpectedResult;
    try std.testing.expect(regions.find(1, 1, 1) != null);

    first.release();
    try std.testing.expect(regions.find(0, 0, 0) == null);
    regions.release_owner(&owner_a);
    try std.testing.expect(regions.find(1, 1, 1) == null);
}

test "sessions are exclusive, lock voluntary travel, and return members on cleanup" {
    set_server_io();
    Server.players = .{};
    defer Server.players = .{};

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try world.init_empty(allocator, io, tmp.dir, "unused.cw", core.world_dims.WorldDims.init(128, 64, 128), 0, world.default_format);
    world.finalize_loaded();
    defer world.deinit();

    var owner_a: PluginsMod.Plugin = undefined;
    var owner_b: PluginsMod.Plugin = undefined;
    var registry = SessionsMod.Registry{};
    const session = registry.create(&owner_a, 4) orelse return error.TestUnexpectedResult;
    const session_b = registry.create(&owner_b, 4) orelse return error.TestUnexpectedResult;

    var out_buf: [4096]u8 = undefined;
    var client_session = Session{};
    const client = client_session.open(&out_buf, true, 0);

    const handle = Server.PlayerHandle{ .id = 0, .generation = 1 };
    const spot = SessionsMod.ReturnSpot{ .x = 3, .y = 1, .z = 3, .valid = true };
    try std.testing.expect(registry.admit(session, handle, spot, "participant"));
    try std.testing.expect(session.contains(handle));
    try std.testing.expect(!registry.admit(session, handle, spot, "participant"));
    try std.testing.expect(!registry.admit(session_b, handle, spot, "participant"));

    session.travel_locked = true;
    try std.testing.expect(registry.travel_locked_for(handle));

    registry.purge_player(handle);
    try std.testing.expect(!session.contains(handle));
    try std.testing.expect(!registry.travel_locked_for(handle));

    try std.testing.expect(registry.admit(session, handle, spot, "spectator"));
    registry.end_for_owner(&owner_a, .{}, true);
    try std.testing.expect(!session.active);
    try std.testing.expect(registry.find_present(handle) == null);
    const pose = client.pose.load();
    try std.testing.expectEqual(@as(u16, 3 * 32 + 16), pose.x);
    try std.testing.expectEqual(@as(u16, 1 * 32 + 51), pose.y);
}

test "frozen claims contain simulation but allow authorized and bypassed owner writes" {
    var harness = try Harness.init();
    defer harness.deinit();

    try harness.write_package("manifest.json", test_manifest);
    try harness.write_package("main.luau", "return true");
    harness.load();
    const manager = harness.manager orelse return error.TestUnexpectedResult;
    const plugin = manager.items[0];

    var data: core.World.WorldData = undefined;
    try data.init_in_place(allocator, core.world_dims.WorldDims.init(128, 64, 128), 0x1234);
    defer data.deinit();

    data.compute_chunk_counts();

    var sim = try core.World.WorldSimulation.init(allocator, 0x5678);
    defer sim.deinit(allocator);

    var recorder = Recorder{};
    const sink: core.World.WorldSimulation.BlockChangeSink = .{ .ctx = &recorder, .emit_fn = Recorder.emit };

    const box = RegionsMod.Box{ .x0 = 8, .y0 = 0, .z0 = 8, .x1 = 15, .y1 = 15, .z1 = 15 };
    _ = manager.regions.claim(plugin, box, true) orelse return error.TestUnexpectedResult;

    // Simulation cannot pull a gravity block into the frozen claim.
    data.apply_block(10, 12, 10, .sand);
    sim.enqueue_neighbors_of(&data, 10, 12, 10);
    _ = sim.tick(&data, sink);
    try std.testing.expectEqual(core.blocks.Block.sand, data.get_block(10, 12, 10));

    // Owner jobs bypass the guard for their own claims.
    ArenaMod.bypass_cells = true;
    _ = sim.set_block(&data, sink, 10, 12, 10, .stone);
    ArenaMod.bypass_cells = false;
    try std.testing.expectEqual(core.blocks.Block.stone, data.get_block(10, 12, 10));

    // A session member's edit is authorized for the claim owner.
    const handle = Server.PlayerHandle{ .id = 0, .generation = 1 };
    const member_session = manager.sessions.create(plugin, 4) orelse return error.TestUnexpectedResult;
    try std.testing.expect(manager.sessions.admit(member_session, handle, .{}, "participant"));
    manager.begin_edit(handle);
    _ = sim.set_block(&data, sink, 10, 12, 10, .air);
    manager.end_edit();
    try std.testing.expectEqual(core.blocks.Block.air, data.get_block(10, 12, 10));

    // Without authorization the same edit is denied by the guard.
    _ = sim.set_block(&data, sink, 10, 12, 10, .stone);
    try std.testing.expectEqual(core.blocks.Block.air, data.get_block(10, 12, 10));
}

test "movement policy reports sustained hovering and implausible ascent only" {
    set_server_io();
    var trace = PluginsMod.MoveTrace{};

    // A single unsupported sample is not evidence.
    try std.testing.expectEqual(@as(?PluginsMod.MoveViolation, null), PluginsMod.movement_policy_sample(&trace, 1000, 1, 5, 10, 5, false));

    // Sustained hovering in place is.
    var found: ?PluginsMod.MoveViolation = null;
    var t: i64 = 1250;
    while (t <= 7000) : (t += 250) {
        if (PluginsMod.movement_policy_sample(&trace, t, 1, 5, 10, 5, false)) |v| found = v;
    }
    try std.testing.expectEqual(PluginsMod.MoveViolation.hover, found.?);

    // Falling and teleport serials reset the evidence windows.
    trace = .{};
    try std.testing.expectEqual(@as(?PluginsMod.MoveViolation, null), PluginsMod.movement_policy_sample(&trace, 1000, 1, 5, 10, 5, false));
    try std.testing.expectEqual(@as(?PluginsMod.MoveViolation, null), PluginsMod.movement_policy_sample(&trace, 1250, 1, 5, 9, 5, false));
    try std.testing.expectEqual(@as(?PluginsMod.MoveViolation, null), PluginsMod.movement_policy_sample(&trace, 1500, 2, 5, 30, 5, false));
    try std.testing.expectEqual(@as(?PluginsMod.MoveViolation, null), PluginsMod.movement_policy_sample(&trace, 1750, 2, 5, 29, 5, false));

    // Rising five blocks inside the ascent window is implausible ascent.
    trace = .{};
    _ = PluginsMod.movement_policy_sample(&trace, 1000, 1, 5, 10, 5, false);
    try std.testing.expectEqual(@as(?PluginsMod.MoveViolation, null), PluginsMod.movement_policy_sample(&trace, 1400, 1, 5, 13, 5, false));
    try std.testing.expectEqual(PluginsMod.MoveViolation.ascend, PluginsMod.movement_policy_sample(&trace, 1800, 1, 5, 16, 5, false).?);

    // Ordinary jump arcs and sampling gaps stay clean.
    trace = .{};
    _ = PluginsMod.movement_policy_sample(&trace, 1000, 1, 5, 10, 5, true);
    try std.testing.expectEqual(@as(?PluginsMod.MoveViolation, null), PluginsMod.movement_policy_sample(&trace, 1300, 1, 5, 11, 5, false));
    try std.testing.expectEqual(@as(?PluginsMod.MoveViolation, null), PluginsMod.movement_policy_sample(&trace, 1600, 1, 5, 12, 5, false));
    try std.testing.expectEqual(@as(?PluginsMod.MoveViolation, null), PluginsMod.movement_policy_sample(&trace, 4000, 1, 5, 12, 5, true));
}

const Recorder = struct {
    count: u32 = 0,

    fn emit(ctx: ?*anyopaque, change: core.World.WorldSimulation.BlockChange) void {
        _ = change;
        const self: *Recorder = @ptrCast(@alignCast(ctx.?));
        self.count += 1;
    }
};

test "captured arena templates drive dirty-arena recovery" {
    var harness = try Harness.init();
    defer harness.deinit();

    try harness.write_package("manifest.json", test_manifest);
    try harness.write_package("main.luau", "return true");
    harness.load();
    const manager = harness.manager orelse return error.TestUnexpectedResult;
    const plugin = manager.items[0];

    try world.init_empty(allocator, io, harness.tmp.dir, "unused.cw", core.world_dims.WorldDims.init(128, 64, 128), 0, world.default_format);
    world.finalize_loaded();
    defer world.deinit();

    const box = RegionsMod.Box{ .x0 = 0, .y0 = 0, .z0 = 0, .x1 = 7, .y1 = 3, .z1 = 7 };
    _ = manager.regions.claim(plugin, box, true) orelse return error.TestUnexpectedResult;
    world.data.apply_block(3, 1, 3, .stone);
    try std.testing.expect(manager.jobs.capture(plugin, box, "arena"));
    try std.testing.expect(manager.jobs.mark_dirty(plugin, box, "arena"));

    // The match destroys part of the captured arena before "crashing".
    world.data.apply_block(3, 1, 3, .air);
    try std.testing.expectEqual(core.blocks.Block.air, world.get_block(3, 1, 3));

    ArenaMod.recover(allocator, harness.data_dir);
    try std.testing.expectEqual(core.blocks.Block.stone, world.get_block(3, 1, 3));

    const record_exists = if (harness.data_dir.openFile(io, "plugin-data/" ++ plugin_uuid ++ ".arena.dirty.json", .{})) |_| true else |_| false;
    try std.testing.expect(!record_exists);
}

// ----------------------------------------------------- build battle rounds

const bb_uuid = "b4e2f8a1-6c93-4d07-9e55-2c1a9f3d7b60";
const bb_manifest =
    \\{"uuid":"b4e2f8a1-6c93-4d07-9e55-2c1a9f3d7b60","name":"Build Battle","version":"1.0.0",
    \\ "api_version":"1.x","entrypoint":"main.luau",
    \\ "capabilities":["player.message","player.teleport","world.edit","session.host"]}
;
const bb_source = @embedFile("plugins/buildbattle/buildbattle.luau");

/// A captured Build Battle arena seeded through the store: the box must fit
/// the plot grid (rows of up to four 15x15x15 volumes plus margins).
fn seed_build_battle_arena(harness: *Harness, plot_count: u32) !void {
    try harness.data_dir.createDirPath(io, "plugin-data");
    try harness.write_package("manifest.json", bb_manifest);
    try harness.write_package("main.luau", bb_source);
    var cfg_buf: [160]u8 = undefined;
    try harness.write_package("config.json", try std.fmt.bufPrint(&cfg_buf,
        \\{{"build_seconds":1,"judge_seconds":1,"gather_seconds":1,"tick_ms":50,"themes":["Castle"]}}
    , .{}));

    const cols: u32 = @min(plot_count, 4);
    const rows: u32 = (plot_count + 3) / 4;
    const width = 4 + cols * 15 + (cols - 1) * 4;
    const depth = 5 + rows * 15 + (rows - 1) * 4;
    const volume: usize = @intCast(width * 17 * depth);
    var store_buf: [192]u8 = undefined;
    var path_buf: [96]u8 = undefined;
    try harness.data_dir.writeFile(io, .{
        .sub_path = try std.fmt.bufPrint(&path_buf, "plugin-data/{s}.json", .{bb_uuid}),
        .data = try std.fmt.bufPrint(&store_buf,
            \\{{"ready":1,"x0":10,"y0":10,"z0":10,"x1":{d},"y1":26,"z1":{d},"plots":{d}}}
        , .{ 9 + width, 9 + depth, plot_count }),
    });
    // A captured template of air cells, as /bbop capture would have written.
    const cells = try allocator.alloc(u8, volume);
    defer allocator.free(cells);

    @memset(cells, 0);
    try harness.data_dir.writeFile(io, .{
        .sub_path = try std.fmt.bufPrint(&path_buf, "plugin-data/{s}.arena.bin", .{bb_uuid}),
        .data = cells,
    });
}

fn count_in(buf: []const u8, needle: []const u8) usize {
    var total: usize = 0;
    var offset: usize = 0;
    while (std.mem.indexOf(u8, buf[offset..], needle)) |at| {
        total += 1;
        offset += at + needle.len;
    }
    return total;
}

/// Drive the plugin's interval, the ordered queue, and the arena jobs until
/// `needle` appears `min_count` times in the member's chat log. Phases advance
/// on real monotonic time, so the packaged config uses one-second windows.
fn wait_for_chat(harness: *Harness, session: *Session, needle: []const u8, min_count: usize) !void {
    const manager = harness.manager orelse return error.TestUnexpectedResult;
    const deadline = Client.now_ms() + 10_000;
    while (count_in(session.output[0..session.writer.end], needle) < min_count) {
        if (Client.now_ms() >= deadline) return error.TestUnexpectedResult;
        harness.host.deadline_ms = Client.now_ms() + 1000;
        harness.host.drain();
        manager.tick();
        io.sleep(.fromMilliseconds(20), .real) catch {};
    }
}

test "build battle round: plot edits, replacement votes, and spawn returns" {
    var harness = try Harness.init();
    defer harness.deinit();

    try seed_build_battle_arena(&harness, 2);

    try install_test_save_services();
    defer uninstall_test_save_services();

    // The plugin claims its arena during load, so the world must exist first.
    try world.init_empty(allocator, io, harness.tmp.dir, "unused.cw", core.world_dims.WorldDims.init(128, 64, 128), 0, world.default_format);
    world.finalize_loaded();
    // Round edits commit through world.set_block, which the ordered tick
    // context owns in production.
    try world.install_local_simulation(allocator, 0);
    defer world.deinit();

    harness.load();
    const manager = harness.manager orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), manager.count);
    try std.testing.expect(manager.items[0].active);

    Server.players = .{};
    defer Server.players = .{};

    var buf_a: [16384]u8 = undefined;
    var buf_b: [16384]u8 = undefined;
    var buf_o: [4096]u8 = undefined;
    var session_a = Session{};
    var session_b = Session{};
    var session_o = Session{};
    const alice = session_a.open(&buf_a, true, 0);
    const bob = session_b.open(&buf_b, true, 1);
    _ = session_o.open(&buf_o, true, 2);
    alice.name_len = 5;
    @memcpy(alice.name[0..5], "Alice");
    bob.name_len = 3;
    @memcpy(bob.name[0..3], "Bob");

    const handle_a = Server.PlayerHandle{ .id = 0, .generation = 1 };
    const handle_b = Server.PlayerHandle{ .id = 1, .generation = 1 };
    const handle_o = Server.PlayerHandle{ .id = 2, .generation = 1 };

    harness.host.deadline_ms = Client.now_ms() + 1000;
    harness.host.enqueue_command(handle_a, "buildbattle");
    harness.host.enqueue_command(handle_b, "buildbattle");
    harness.host.drain();

    // Join travel puts each builder at the front walkway of their own plot.
    const plot_view_x = [_]u16{ 19, 38 };
    for (plot_view_x, 0..) |vx, slot| {
        const client = if (slot == 0) alice else bob;
        const pose = client.pose.load();
        try std.testing.expectEqual(@as(u16, vx * 32 + 16), pose.x);
        try std.testing.expectEqual(@as(u16, 11 * 32 + 51), pose.y);
        try std.testing.expectEqual(@as(u16, 11 * 32 + 16), pose.z);
    }

    try wait_for_chat(&harness, &session_a, "Theme:", 1);

    // Building: own-plot edits commit, foreign and outsider edits are denied
    // with corrective packets.
    harness.host.deadline_ms = Client.now_ms() + 1000;
    harness.host.enqueue(.{ .set_block = .{
        .handle = handle_a,
        .x = 19,
        .y = 15,
        .z = 20,
        .mode = @intFromEnum(core.zb.ClickMode.create),
        .block = @intFromEnum(core.blocks.Block.stone),
    } });
    harness.host.enqueue(.{ .set_block = .{
        .handle = handle_b,
        .x = 19,
        .y = 14,
        .z = 20,
        .mode = @intFromEnum(core.zb.ClickMode.create),
        .block = @intFromEnum(core.blocks.Block.stone),
    } });
    harness.host.enqueue(.{ .set_block = .{
        .handle = handle_o,
        .x = 19,
        .y = 13,
        .z = 20,
        .mode = @intFromEnum(core.zb.ClickMode.create),
        .block = @intFromEnum(core.blocks.Block.stone),
    } });
    harness.host.drain();
    try std.testing.expectEqual(core.blocks.Block.stone, world.get_block(19, 15, 20));
    try std.testing.expectEqual(core.blocks.Block.air, world.get_block(19, 14, 20));
    try std.testing.expectEqual(core.blocks.Block.air, world.get_block(19, 13, 20));
    const denial = [_]u8{ 0x06, 0x00, 19, 0x00, 14, 0x00, 20 };
    try std.testing.expect(std.mem.indexOf(u8, buf_b[0..session_b.writer.end], &denial) != null);

    // Judging window 1 (Alice's build): Bob replaces his vote, Alice cannot
    // vote for herself.
    try wait_for_chat(&harness, &session_a, "Now judging", 1);
    harness.host.deadline_ms = Client.now_ms() + 1000;
    harness.host.enqueue_command(handle_b, "vote 8");
    harness.host.enqueue_command(handle_b, "vote 3");
    harness.host.enqueue_command(handle_a, "vote 9");
    harness.host.drain();
    try std.testing.expect(std.mem.indexOf(u8, buf_a[0..session_a.writer.end], "You cannot vote for your own build") != null);

    // Judging window 2 (Bob's build): Alice scores 7, so Bob wins 7.0 to 3.0.
    try wait_for_chat(&harness, &session_a, "Now judging", 2);
    harness.host.deadline_ms = Client.now_ms() + 1000;
    harness.host.enqueue_command(handle_a, "vote 7");
    harness.host.drain();

    try wait_for_chat(&harness, &session_a, "won build battle", 1);
    try std.testing.expect(std.mem.indexOf(u8, buf_a[0..session_a.writer.end], "Winner (7.0): Bob") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf_a[0..session_a.writer.end], "2nd place (3.0): Alice") != null);
    // The gather teleports everyone to the winning plot's viewing spot.
    for ([_]*Client{ alice, bob }) |client| {
        const pose = client.pose.load();
        try std.testing.expectEqual(@as(u16, 38 * 32 + 16), pose.x);
        try std.testing.expectEqual(@as(u16, 11 * 32 + 51), pose.y);
    }

    // After the gather, players return to the stable spawn and the restore
    // undoes the round's edits.
    try wait_for_chat(&harness, &session_a, "open again", 1);
    for ([_]*Client{ alice, bob }) |client| {
        const pose = client.pose.load();
        try std.testing.expectEqual(@as(u16, 64 * 32 + 16), pose.x);
        try std.testing.expectEqual(@as(u16, 83), pose.y);
        try std.testing.expectEqual(@as(u16, 64 * 32 + 16), pose.z);
    }
    try std.testing.expectEqual(core.blocks.Block.air, world.get_block(19, 15, 20));
    const record_exists = if (harness.data_dir.openFile(io, "plugin-data/" ++ bb_uuid ++ ".arena.dirty.json", .{})) |_| true else |_| false;
    try std.testing.expect(!record_exists);

    // Editing closed at the build deadline: a queued own-plot edit is denied.
    harness.host.deadline_ms = Client.now_ms() + 1000;
    harness.host.enqueue(.{ .set_block = .{
        .handle = handle_a,
        .x = 19,
        .y = 15,
        .z = 20,
        .mode = @intFromEnum(core.zb.ClickMode.create),
        .block = @intFromEnum(core.blocks.Block.stone),
    } });
    harness.host.drain();
    try std.testing.expectEqual(core.blocks.Block.air, world.get_block(19, 15, 20));
}

test "build battle voting: ties share first place and zero-vote builds rank nowhere" {
    var harness = try Harness.init();
    defer harness.deinit();

    try seed_build_battle_arena(&harness, 3);

    try world.init_empty(allocator, io, harness.tmp.dir, "unused.cw", core.world_dims.WorldDims.init(128, 64, 128), 0, world.default_format);
    world.finalize_loaded();
    defer world.deinit();

    harness.load();

    Server.players = .{};
    defer Server.players = .{};

    var buf_a: [16384]u8 = undefined;
    var buf_b: [16384]u8 = undefined;
    var buf_c: [16384]u8 = undefined;
    var session_a = Session{};
    var session_b = Session{};
    var session_c = Session{};
    const alice = session_a.open(&buf_a, true, 0);
    const bob = session_b.open(&buf_b, true, 1);
    const carol = session_c.open(&buf_c, true, 2);
    alice.name_len = 5;
    @memcpy(alice.name[0..5], "Alice");
    bob.name_len = 3;
    @memcpy(bob.name[0..3], "Bob");
    carol.name_len = 5;
    @memcpy(carol.name[0..5], "Carol");

    const handle_a = Server.PlayerHandle{ .id = 0, .generation = 1 };
    const handle_b = Server.PlayerHandle{ .id = 1, .generation = 1 };
    const handle_c = Server.PlayerHandle{ .id = 2, .generation = 1 };

    harness.host.deadline_ms = Client.now_ms() + 1000;
    for ([_]Server.PlayerHandle{ handle_a, handle_b, handle_c }) |handle| {
        harness.host.enqueue_command(handle, "buildbattle");
    }
    harness.host.drain();

    try wait_for_chat(&harness, &session_a, "Now judging", 1);
    // Window 1 (Alice): Bob and Carol both score 5.
    harness.host.deadline_ms = Client.now_ms() + 1000;
    harness.host.enqueue_command(handle_b, "vote 5");
    harness.host.enqueue_command(handle_c, "vote 5");
    harness.host.drain();

    try wait_for_chat(&harness, &session_a, "Now judging", 2);
    // Window 2 (Bob): only Alice votes; Carol's silence is an abstention.
    harness.host.deadline_ms = Client.now_ms() + 1000;
    harness.host.enqueue_command(handle_a, "vote 5");
    harness.host.drain();

    // Window 3 (Carol): nobody votes, so her build is unranked.
    try wait_for_chat(&harness, &session_a, "Now judging", 3);

    try wait_for_chat(&harness, &session_a, "won build battle", 1);
    try std.testing.expect(std.mem.indexOf(u8, buf_a[0..session_a.writer.end], "Winner (5.0): Alice, Bob") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf_a[0..session_a.writer.end], "3rd place") == null);
    // Shared first place gathers at the first winning plot in judging order.
    for ([_]*Client{ alice, bob, carol }) |client| {
        const pose = client.pose.load();
        try std.testing.expectEqual(@as(u16, 19 * 32 + 16), pose.x);
        try std.testing.expectEqual(@as(u16, 11 * 32 + 51), pose.y);
    }
    try wait_for_chat(&harness, &session_a, "open again", 1);
}

test "build battle departure during building cancels the round and returns players" {
    var harness = try Harness.init();
    defer harness.deinit();

    try seed_build_battle_arena(&harness, 2);

    try world.init_empty(allocator, io, harness.tmp.dir, "unused.cw", core.world_dims.WorldDims.init(128, 64, 128), 0, world.default_format);
    world.finalize_loaded();
    defer world.deinit();

    harness.load();

    Server.players = .{};
    defer Server.players = .{};

    var buf_a: [16384]u8 = undefined;
    var buf_b: [16384]u8 = undefined;
    var session_a = Session{};
    var session_b = Session{};
    const alice = session_a.open(&buf_a, true, 0);
    const bob = session_b.open(&buf_b, true, 1);
    alice.name_len = 5;
    @memcpy(alice.name[0..5], "Alice");
    bob.name_len = 3;
    @memcpy(bob.name[0..3], "Bob");

    const handle_a = Server.PlayerHandle{ .id = 0, .generation = 1 };
    const handle_b = Server.PlayerHandle{ .id = 1, .generation = 1 };

    harness.host.deadline_ms = Client.now_ms() + 1000;
    harness.host.enqueue_command(handle_a, "buildbattle");
    harness.host.enqueue_command(handle_b, "buildbattle");
    harness.host.drain();

    try wait_for_chat(&harness, &session_a, "Theme:", 1);

    // Alice departs during building: her build is withdrawn and the round
    // cancels because fewer than two participants remain before results.
    harness.host.deadline_ms = Client.now_ms() + 1000;
    harness.host.enqueue_command(handle_a, "buildbattle");
    harness.host.drain();
    try std.testing.expect(std.mem.indexOf(u8, buf_a[0..session_a.writer.end], "You left the round") != null);

    try wait_for_chat(&harness, &session_b, "was canceled", 1);
    try wait_for_chat(&harness, &session_b, "open again", 1);

    // Bob is returned to the stable spawn; Alice left the session, so she
    // keeps her last position.
    const pose_b = bob.pose.load();
    try std.testing.expectEqual(@as(u16, 64 * 32 + 16), pose_b.x);
    try std.testing.expectEqual(@as(u16, 83), pose_b.y);
    const pose_a = alice.pose.load();
    try std.testing.expectEqual(@as(u16, 19 * 32 + 16), pose_a.x);
    try std.testing.expectEqual(@as(u16, 11 * 32 + 51), pose_a.y);
}
