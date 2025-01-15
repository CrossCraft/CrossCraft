/// Creates a 'spinning' ringbuffer. This defers from normal FIFO behavior by finding the next possible available spot in an 'incremental' way.
pub fn SpinningRingbuffer(comptime T: type, comptime U: usize) type {
    return struct {
        ring: [U]?T,

        const Self = @This();

        pub fn init() Self {
            var srb: Self = undefined;

            for (0..U) |i| {
                srb.ring[i] = null;
            }

            return srb;
        }

        pub fn add(self: *Self, data: T) ?usize {
            var i: usize = 0;
            while (i < U) : (i += 1) {
                if (self.ring[i] == null) {
                    self.ring[i] = data;
                    return i;
                }
            }

            return null;
        }

        pub fn remove(self: *Self, id: usize) void {
            self.ring[id] = null;
        }
    };
}
