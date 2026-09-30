//! Legacy particle/rain meshes use 128 packed units per block and a 256x
//! model scale on every target. Selecting the 32768 divisor explicitly keeps
//! that existing convention, including its small desktop SNORM scale bias.
const Rendering = @import("aether").Rendering;

pub const encoding = Rendering.vertex.PositionEncoding.init(128, .psp_ge) catch unreachable;
