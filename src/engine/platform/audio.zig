const std = @import("std");
const AudioAPI = @import("audio_api.zig");

pub var api: AudioAPI = undefined;

/// Initializes the audio subsystem.
pub fn init() !void {
    api = try AudioAPI.make_api();
    try api.init();
}

/// Deinitializes the audio subsystem and frees all associated resources.
pub fn deinit() void {
    api.deinit();
}
