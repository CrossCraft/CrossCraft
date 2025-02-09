/// Creates a 'spinning' ringbuffer. This defers from normal FIFO behavior by finding the next possible available spot in an 'incremental' way.
/// There's probably a better name for this
pub fn FIFOBuffer(comptime T: type, comptime U: usize) type {
    return struct {
        items: [U]?T,

        const Self = @This();

        pub fn init() Self {
            var srb: Self = undefined;

            for (0..U) |i| {
                srb.items[i] = null;
            }

            return srb;
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
