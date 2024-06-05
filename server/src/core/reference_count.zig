const std = @import("std");
const assert = std.debug.assert;

/// A reference-counted object.
/// `T` is the type of the object being reference-counted.
/// `Context` is the type of the context that is passed to the drop callback.
/// `drop_callback` is the function that is called when the reference count reaches zero.
/// The drop callback is passed the context and the data.
/// The drop callback is responsible for freeing the data.
pub fn ReferenceCounted(
    comptime T: type,
    comptime Context: type,
    drop_callback: fn (context: Context, data: *T) void,
) type {
    return struct {
        data: *T,
        context: Context,
        reference_count: usize,
        acquired: bool,

        const Self = @This();

        /// Initializes a reference-counted object.
        /// `data` is the data to be reference-counted.
        /// `context` is the context to be passed to the drop callback.
        pub fn init(data: *T, context: Context) Self {
            return .{
                .data = data,
                .context = context,
                // Start with a reference count of 0.
                // The first reference should then be acquired.
                // This is to ensure that the data is not dropped until the first reference is acquired.
                .reference_count = 0,
            };
        }

        /// Acquires a reference to the data.
        /// Returns a pointer to the data.
        pub fn acquire(self: *const Self) *T {
            self.acquired = true;

            self.reference_count += 1;
            return self.data;
        }

        /// Releases a reference to the data.
        /// If the reference count reaches zero, the drop callback is called.
        pub fn release(self: *Self) void {
            // Assert we have been acquired at least once.
            assert(self.acquired);
            assert(self.reference_count > 0);
            self.reference_count -= 1;
            if (self.reference_count == 0) {
                drop_callback(self.context, self.data);
            }
        }
    };
}

// TODO: Unit Testing
