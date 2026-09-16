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

    try std.testing.expectEqual(@as(usize, 1), manager.count);
    const essentials = manager.items[0];
    try std.testing.expect(essentials.active);
    try std.testing.expectEqualStrings("Essentials", essentials.manifest.name());
    try std.testing.expect(Commands.is_script("msg"));
    try std.testing.expect(Commands.is_script("reply"));
    try std.testing.expect(Commands.is_script("spawn"));
    try std.testing.expect(Commands.is_script("setspawn"));

    const written = try tmp.dir.readFileAlloc(io, "plugins/essentials/manifest.json", allocator, .limited(4096));
    defer allocator.free(written);

    try std.testing.expect(std.mem.indexOf(u8, written, "Essentials") != null);
}
