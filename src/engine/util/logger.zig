const std = @import("std");
const builtin = @import("builtin");

var log_buffer: [4096]u8 = @splat(0);
var file_log: std.fs.File = undefined;
var file_writer: std.fs.File.Writer = undefined;
var writer: *std.io.Writer = undefined;

pub fn init() !void {
    file_log = try std.fs.cwd().createFile("spark.log", .{ .truncate = true });
    file_writer = file_log.writer(&log_buffer);
    writer = &file_writer.interface;
}

pub fn deinit() void {
    writer.flush() catch {};
    file_log.close();
}

pub fn spark_log_fn(
    comptime level: std.log.Level,
    comptime scope: @Type(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    const scope_prefix = "(" ++ switch (scope) {
        .engine, .game, std.log.default_log_scope => @tagName(scope),
        else => if (@intFromEnum(level) <= @intFromEnum(std.log.Level.err))
            @tagName(scope)
        else
            return,
    } ++ ") ";

    const prefix = scope_prefix ++ "[" ++ comptime level.asText() ++ "]: ";

    writer.print(prefix ++ format ++ "\n", args) catch {};
    if (builtin.mode == .Debug) {
        std.debug.print(prefix ++ format ++ "\n", args);
    }
}
