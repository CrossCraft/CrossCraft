const Clip = @import("../audio/clip.zig");
const Util = @import("../util/util.zig");
const Self = @This();
const zm = @import("zmath");

ptr: *anyopaque,
tab: *const VTable,

pub const VTable = struct {
    // --- API Setup / Lifecycle ---
    init: *const fn (ctx: *anyopaque) anyerror!void,
    deinit: *const fn (ctx: *anyopaque) void,
    set_listener_position: *const fn (ctx: *anyopaque, pos: zm.Vec) void,
    set_listener_direction: *const fn (ctx: *anyopaque, dir: zm.Vec) void,

    // --- Audio Clip (raw) ---
    load_clip: *const fn (ctx: *anyopaque, path: [:0]const u8) anyerror!Clip.Handle,
    unload_clip: *const fn (ctx: *anyopaque, handle: Clip.Handle) void,
    play_clip: *const fn (ctx: *anyopaque, handle: Clip.Handle) void,
    stop_clip: *const fn (ctx: *anyopaque, handle: Clip.Handle) void,
    set_clip_position: *const fn (ctx: *anyopaque, handle: Clip.Handle, pos: zm.Vec) void,
};

pub fn init(self: *const Self) anyerror!void {
    try self.tab.init(self.ptr);
}

pub fn deinit(self: *const Self) void {
    self.tab.deinit(self.ptr);
}

pub fn make_api() !Self {
    const ZAudio = @import("miniaudio/zaudio.zig");
    var audio = try Util.allocator().create(ZAudio);
    return audio.audio_api();
}
