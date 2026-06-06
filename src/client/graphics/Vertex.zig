const ae = @import("aether");
const Rendering = ae.Rendering;

pub const Vertex = if (ae.platform == .nintendo_3ds) Vertex3DS else VertexDefault;

const Vertex3DS = extern struct {
    pos: [3]i16,
    uv: [2]i16,
    color: u32 align(2),

    pub const Attributes = Rendering.Pipeline.attributes_from_struct(@This(), &[_]Rendering.Pipeline.AttributeSpec{
        .{ .field = "pos", .location = 0, .usage = .position },
        .{ .field = "color", .location = 1, .usage = .color },
        .{ .field = "uv", .location = 2, .usage = .uv },
    });
    pub const Layout = Rendering.Pipeline.layout_from_struct(@This(), &Attributes);
};

const VertexDefault = extern struct {
    uv: [2]i16,
    color: u32,
    pos: [3]i16,
    _pad: i16 = 0,

    pub const Attributes = Rendering.Pipeline.attributes_from_struct(@This(), &[_]Rendering.Pipeline.AttributeSpec{
        .{ .field = "pos", .location = 0, .usage = .position },
        .{ .field = "color", .location = 1, .usage = .color },
        .{ .field = "uv", .location = 2, .usage = .uv },
    });
    pub const Layout = Rendering.Pipeline.layout_from_struct(@This(), &Attributes);
};

comptime {
    if (@sizeOf(Vertex) != 16 or @alignOf(Vertex) != 4) {
        if (ae.platform != .nintendo_3ds) @compileError("Vertex layout changed unexpectedly");
    }
    if (ae.platform == .nintendo_3ds) {
        if (@sizeOf(Vertex) != 14 or @alignOf(Vertex) != 2) {
            @compileError("3DS Vertex layout must stay tightly packed");
        }
        if (@offsetOf(Vertex, "pos") != 0 or @offsetOf(Vertex, "uv") != 6 or @offsetOf(Vertex, "color") != 10) {
            @compileError("3DS Vertex layout must stay PICA-friendly: pos/uv/color");
        }
    }
}
