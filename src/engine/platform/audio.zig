const std = @import("std");
const AudioAPI = @import("audio_api.zig");

pub var api: AudioAPI = undefined;
pub fn init() !void {
    api = try AudioAPI.make_api();
    try api.init();
}

pub fn deinit() void {
    api.deinit();
}
