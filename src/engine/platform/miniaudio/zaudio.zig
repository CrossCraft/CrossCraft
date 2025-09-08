const zm = @import("zmath");
const zaudio = @import("zaudio");
const Util = @import("../../util/util.zig");
const AudioAPI = @import("../audio_api.zig");

const Self = @This();

const Sound = struct {
    audio: *zaudio.Sound,
};

var clips = Util.CircularBuffer(Sound, 256).init();

engine: *zaudio.Engine,

fn init(ctx: *anyopaque) anyerror!void {
    const self = Util.ctx_to_self(Self, ctx);

    zaudio.init(Util.allocator());
    self.engine = try zaudio.Engine.create(null);
}

fn deinit(ctx: *anyopaque) void {
    const self = Util.ctx_to_self(Self, ctx);

    self.engine.destroy();
    zaudio.deinit();
    Util.allocator().destroy(self);
}

fn set_listener_position(ctx: *anyopaque, pos: zm.Vec) void {
    const self = Util.ctx_to_self(Self, ctx);

    self.engine.setListenerPosition(0, [_]f32{ pos[0], pos[1], pos[2] });
}

fn set_listener_direction(ctx: *anyopaque, dir: zm.Vec) void {
    const self = Util.ctx_to_self(Self, ctx);

    self.engine.setListenerDirection(0, [_]f32{ dir[0], dir[1], dir[2] });
}

fn load_clip(ctx: *anyopaque, path: [:0]const u8) anyerror!u32 {
    const self = Util.ctx_to_self(Self, ctx);

    const sound = try self.engine.createSoundFromFile(path, .{ .flags = .{ .stream = true } });
    const handle = clips.add_element(.{ .audio = sound }) orelse return error.OutOfHandles;
    return @intCast(handle);
}

fn unload_clip(ctx: *anyopaque, handle: u32) void {
    _ = ctx;

    const sound = clips.get_element(handle);
    if (sound) |s| {
        s.audio.destroy();
        _ = clips.remove_element(handle);
    }
}

fn play_clip(ctx: *anyopaque, handle: u32) void {
    _ = ctx;

    const sound = clips.get_element(handle);
    if (sound) |s| {
        s.audio.start() catch {};
    }
}

fn stop_clip(ctx: *anyopaque, handle: u32) void {
    _ = ctx;

    const sound = clips.get_element(handle);
    if (sound) |s| {
        s.audio.stop() catch {};
    }
}

fn set_clip_position(ctx: *anyopaque, handle: u32, pos: zm.Vec) void {
    _ = ctx;

    const sound = clips.get_element(handle);
    if (sound) |s| {
        s.audio.setPosition([_]f32{ pos[0], pos[1], pos[2] });
    }
}

pub fn audio_api(self: *Self) AudioAPI {
    return .{
        .ptr = self,
        .tab = &.{
            .init = init,
            .deinit = deinit,
            .set_listener_position = set_listener_position,
            .set_listener_direction = set_listener_direction,
            .load_clip = load_clip,
            .unload_clip = unload_clip,
            .play_clip = play_clip,
            .stop_clip = stop_clip,
            .set_clip_position = set_clip_position,
        },
    };
}
