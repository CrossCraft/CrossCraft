const zm = @import("zmath");
const Platform = @import("../platform/platform.zig");
const audio = Platform.audio;
const Self = @This();

pub const Handle = u32;

id: Handle,

pub fn load(path: [:0]const u8) !Self {
    return .{
        .id = try audio.api.tab.load_clip(audio.api.ptr, path),
    };
}

pub fn deinit(self: *Self) void {
    audio.api.tab.unload_clip(audio.api.ptr, self.id);
}

pub fn play(self: *Self) void {
    audio.api.tab.play_clip(audio.api.ptr, self.id);
}

pub fn stop(self: *Self) void {
    audio.api.tab.stop_clip(audio.api.ptr, self.id);
}

pub fn set_position(self: *Self, pos: zm.Vec) void {
    audio.api.tab.set_clip_position(audio.api.ptr, self.id, pos);
}
