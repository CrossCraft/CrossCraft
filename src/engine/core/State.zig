ptr: *anyopaque,
tab: VTable,

const VTable = struct {
    init: *const fn (ctx: *anyopaque) anyerror!void,
    deinit: *const fn (ctx: *anyopaque) void,

    update: *const fn (ctx: *anyopaque, dt: f32) anyerror!void,
    draw: *const fn (ctx: *anyopaque, dt: f32) anyerror!void,
};

const Self = @This();

pub fn init(self: *const Self) anyerror!void {
    try self.tab.init(self.ptr);
}

pub fn deinit(self: *const Self) void {
    self.tab.deinit(self.ptr);
}

pub fn update(self: *const Self, dt: f32) anyerror!void {
    try self.tab.update(self.ptr, dt);
}

pub fn draw(self: *const Self, dt: f32) anyerror!void {
    try self.tab.draw(self.ptr, dt);
}
