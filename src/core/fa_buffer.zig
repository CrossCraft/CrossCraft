pub fn FirstAvailableBuffer(comptime T: type, comptime U: usize) type {
    return struct {
        items: [U]?T,

        const Self = @This();

        pub fn init() Self {
            return .{
                .items = @splat(null),
            };
        }

        pub fn add(self: *Self, data: T) ?usize {
            for (0..U) |i| {
                if (self.items[i] == null) {
                    self.items[i] = data;
                    return i;
                }
            } else return null;
        }

        pub fn remove(self: *Self, id: usize) void {
            self.items[id].? = undefined;
            self.items[id] = null;
        }
    };
}
