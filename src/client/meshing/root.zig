//! Chunk meshing is its own module so it builds ReleaseFast in every client mode.
pub const face = @import("face.zig");
pub const mesher = @import("mesher.zig");

test {
    _ = face;
    _ = mesher;
}
