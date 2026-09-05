//! Host operations injected at the client/server composition point. World and
//! protocol modules remain independent of the engine and native SDKs.
const std = @import("std");

pub const WriteBody = struct {
    context: *const anyopaque,
    write_fn: *const fn (*const anyopaque, *std.Io.Writer) anyerror!void,

    pub fn write(self: WriteBody, writer: *std.Io.Writer) !void {
        try self.write_fn(self.context, writer);
    }
};

pub const ReplaceResult = struct { bytes: u64, previous_retained: bool };
pub var replace_file: ?*const fn (std.Io, std.Io.Dir, []const u8, WriteBody) anyerror!ReplaceResult = null;

pub fn write_replace(io: std.Io, dir: std.Io.Dir, path: []const u8, body: WriteBody) !ReplaceResult {
    const replace = replace_file orelse return error.HostServicesUnavailable;
    return replace(io, dir, path, body);
}
