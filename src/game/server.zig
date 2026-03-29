const std = @import("std");
const consts = @import("common").consts;
const FAB = @import("common").fa_buffer.FirstAvailableBuffer;
pub const Client = @import("client.zig");
const StaticAllocator = @import("common").static_allocator;
const world = @import("world.zig");
const zb = @import("protocol");

const log = std.log.scoped(.server);

var allocator: StaticAllocator = undefined;
pub var io: std.Io = undefined;

pub var server_name: [64]u8 = pad("CrossCraft Server");
pub var server_motd: [64]u8 = pad("Welcome to CrossCraft!");

pub var players: FAB(Client, consts.MAX_PLAYERS) = .init();

fn pad(comptime s: []const u8) [64]u8 {
    var buf: [64]u8 = @splat(' ');
    @memcpy(buf[0..s.len], s);
    return buf;
}

pub fn init(alloc: std.mem.Allocator, seed: u64, _io: std.Io) !void {
    allocator = .init(alloc);
    io = _io;

    load_config();

    // Temporary scratch allocations
    var scratch = std.heap.ArenaAllocator.init(alloc);
    defer scratch.deinit();

    try world.init(allocator.allocator(), scratch.allocator(), io, seed);
    try Client.init_compressor(allocator.allocator());

    allocator.transition_from_init_to_static();
}

fn load_config() void {
    const file = std.Io.Dir.cwd().openFile(io, "server.properties", .{}) catch {
        log.info("No server.properties found, using defaults", .{});
        return;
    };
    defer file.close(io);

    var buf: [512]u8 = undefined;
    const len = file.readPositionalAll(io, &buf, 0) catch {
        log.info("Failed to read server.properties, using defaults", .{});
        return;
    };

    const data = buf[0..len];
    var start: u32 = 0;

    for (0..32) |_| {
        if (start >= data.len) break;

        const end = std.mem.indexOfScalarPos(u8, data, start, '\n') orelse data.len;
        const line = data[start..end];
        start = @intCast(end + 1);

        if (std.mem.indexOfScalar(u8, line, ':')) |sep| {
            const key = line[0..sep];
            const value = line[sep + 1 ..];

            if (std.mem.eql(u8, key, "server-name")) {
                server_name = @splat(' ');
                const vlen = @min(value.len, 64);
                @memcpy(server_name[0..vlen], value[0..vlen]);
            } else if (std.mem.eql(u8, key, "motd")) {
                server_motd = @splat(' ');
                const vlen = @min(value.len, 64);
                @memcpy(server_motd[0..vlen], value[0..vlen]);
            }
        }
    }

    log.info("Loaded server.properties", .{});
}

pub fn deinit() void {
    allocator.transition_from_static_to_deinit();

    Client.deinit_compressor();
    world.deinit();

    allocator.deinit();
}

pub fn client_join(reader: *std.Io.Reader, writer: *std.Io.Writer, connected: *bool) ?*Client {
    var client: Client = undefined;
    client.connected = connected;
    client.reader = reader;
    client.writer = writer;
    client.initialized = false;
    client.name_len = 0;
    client.id = -1;
    client.x = 0;
    client.y = 0;
    client.z = 0;
    client.yaw = 0;
    client.pitch = 0;

    const id = players.add(client);

    if (id) |i| {
        players.items[i].?.id = @intCast(i);
        players.items[i].?.init();
        return &(players.items[i].?);
    } else {
        defer connected.* = false;
        client.send_disconnect("Server is full!") catch return null;
        return null;
    }
}

pub fn broadcast_spawn_player(sender_id: i8, packet: *zb.SpawnPlayer) void {
    for (0..consts.MAX_PLAYERS) |i| {
        if (players.items[i] != null and players.items[i].?.initialized and players.items[i].?.id != sender_id) {
            players.items[i].?.send_spawn(packet) catch continue;
            players.items[i].?.writer.flush() catch continue;
        }
    }
}

pub fn broadcast_despawn_player(id: i8) void {
    for (0..consts.MAX_PLAYERS) |i| {
        if (players.items[i] != null and players.items[i].?.initialized) {
            players.items[i].?.send_despawn(id) catch continue;
            players.items[i].?.writer.flush() catch continue;
        }
    }
}

pub fn broadcast_chat_message(id: i8, message: []u8) void {
    for (0..consts.MAX_PLAYERS) |i| {
        if (players.items[i] != null and players.items[i].?.initialized) {
            players.items[i].?.send_message(id, message) catch continue;
            players.items[i].?.writer.flush() catch continue;
        }
    }
}

pub fn broadcast_block_change(x: u16, y: u16, z: u16, block_type: u8) void {
    for (0..consts.MAX_PLAYERS) |i| {
        if (players.items[i] != null and players.items[i].?.initialized) {
            players.items[i].?.send_block_change(x, y, z, block_type) catch continue;
            players.items[i].?.writer.flush() catch continue;
        }
    }
}

pub fn broadcast_player_positions() void {
    for (0..consts.MAX_PLAYERS) |i| {
        if (players.items[i] == null or !players.items[i].?.initialized)
            continue;

        for (0..consts.MAX_PLAYERS) |j| {
            if (i == j)
                continue;

            if (players.items[j] != null and players.items[j].?.initialized) {
                const p = players.items[j].?;
                players.items[i].?.send_player_position(p.id, p.x, p.y, p.z, p.yaw, p.pitch) catch continue;
                players.items[i].?.writer.flush() catch continue;
            }
        }
    }
}

var tick_counter: u32 = 0;

pub fn tick() void {
    for (0..consts.MAX_PLAYERS) |i| {
        if (players.items[i]) |client| {
            if (!client.connected.*) {
                const id = client.id;
                players.remove(@intCast(id));

                if (!client.initialized) continue;

                const name = client.name;
                const name_len = client.name_len;

                broadcast_despawn_player(id);

                var msg_buf: consts.Message = @splat(' ');
                _ = std.fmt.bufPrint(&msg_buf, "&e{s} left the game", .{name[0..name_len]}) catch unreachable;
                broadcast_chat_message(id, &msg_buf);
            }
        }
    }

    world.tick();

    for (0..world.pending_count) |i| {
        const change = world.pending_changes[i];
        broadcast_block_change(change.x, change.y, change.z, change.block);
    }
    world.pending_count = 0;

    broadcast_player_positions();

    tick_counter += 1;
    if (tick_counter >= 30) {
        tick_counter = 0;
        broadcast_ping();
    }
}

fn broadcast_ping() void {
    for (0..consts.MAX_PLAYERS) |i| {
        if (players.items[i] != null and players.items[i].?.initialized) {
            players.items[i].?.writer.writeByte(0x01) catch continue;
            players.items[i].?.writer.flush() catch continue;
        }
    }
}
