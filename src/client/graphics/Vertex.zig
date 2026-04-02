const ae = @import("aether");
const Rendering = ae.Rendering;

pub const Vertex = extern struct {
    uv: [2]i16,
    color: u32,
    pos: [3]i16,

    pub const Attributes = Rendering.Pipeline.attributes_from_struct(@This(), &[_]Rendering.Pipeline.AttributeSpec{
        .{ .field = "pos", .location = 0, .usage = .position },
        .{ .field = "color", .location = 1, .usage = .color },
        .{ .field = "uv", .location = 2, .usage = .uv },
    });
    pub const Layout = Rendering.Pipeline.layout_from_struct(@This(), &Attributes);
};
