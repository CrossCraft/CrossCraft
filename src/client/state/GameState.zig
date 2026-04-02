const std = @import("std");
const ae = @import("aether");
const Core = ae.Core;
const Util = ae.Util;
const State = Core.State;

const Server = @import("game").Server;
const FakeConn = @import("../FakeConn.zig").FakeConn;
const ClientConn = @import("../ClientConn.zig");

fake_conn: FakeConn,
conn: ClientConn,

fn init(ctx: *anyopaque) anyerror!void {
    var self = Util.ctx_to_self(@This(), ctx);
    self.fake_conn.init();

    _ = Server.local_join(
        &self.fake_conn.server_reader,
        &self.fake_conn.server_writer,
        &self.fake_conn.connected,
    ) orelse return error.ServerFull;

    self.conn.init(&self.fake_conn.client_reader, &self.fake_conn.client_writer);
    try self.conn.join("Player");

    // Run first connect manually
    Server.drain_local_packets();
    self.conn.drain_packets();

    Util.report();
}

fn deinit(ctx: *anyopaque) void {
    var self = Util.ctx_to_self(@This(), ctx);
    self.fake_conn.connected = false;
}

fn tick(_: *anyopaque) anyerror!void {
    Server.drain_local_packets();
    Server.tick();
}

fn update(_: *anyopaque, _: f32, _: *const Util.BudgetContext) anyerror!void {}

fn draw(ctx: *anyopaque, _: f32, _: *const Util.BudgetContext) anyerror!void {
    var self = Util.ctx_to_self(@This(), ctx);
    self.conn.drain_packets();
}

pub fn state(self: *@This()) State {
    return .{ .ptr = self, .tab = &.{
        .init = init,
        .deinit = deinit,
        .tick = tick,
        .update = update,
        .draw = draw,
    } };
}
