const std = @import("std");
const gl = @import("gl");
const zm = @import("zmath");
const assert = std.debug.assert;
const Util = @import("../../../util/util.zig");

pub const ShaderState = struct {
    view: zm.Mat,
    proj: zm.Mat,
};

pub var state: ShaderState = .{
    .view = zm.identity(),
    .proj = zm.identity(),
};

var ubo: gl.uint = 0;
var initialized = false;

pub fn init() !void {
    assert(!initialized);
    initialized = true;

    gl.CreateBuffers(1, @ptrCast(&ubo));
    gl.NamedBufferStorage(ubo, @sizeOf(ShaderState), &state, gl.DYNAMIC_STORAGE_BIT);
    gl.BindBufferBase(gl.UNIFORM_BUFFER, 0, ubo);

    assert(ubo != 0);
    assert(initialized);
}

pub fn update_ubo() void {
    gl.NamedBufferSubData(ubo, 0, @sizeOf(ShaderState), &state);
}

pub fn deinit() void {
    assert(initialized);
    initialized = false;

    gl.DeleteBuffers(1, @ptrCast(&ubo));

    assert(!initialized);
}

pub const Shader = struct {
    shader_program: gl.uint = 0,
    model_loc: gl.int = -1,

    pub fn init(vs: [:0]const u8, fs: [:0]const u8) !Shader {
        var self = Shader{};

        const vert_shader = try compile_shader(vs, gl.VERTEX_SHADER);
        const frag_shader = try compile_shader(fs, gl.FRAGMENT_SHADER);
        self.shader_program = try link_shader(vert_shader, frag_shader);

        self.model_loc = gl.GetUniformLocation(self.shader_program, "u_model");
        assert(self.model_loc != -1);

        return self;
    }

    pub fn bind(self: *const Shader) void {
        gl.UseProgram(self.shader_program);
    }

    pub fn update_model(self: *const Shader, model: *const zm.Mat) void {
        gl.UniformMatrix4fv(self.model_loc, 1, gl.FALSE, @ptrCast(model));
    }

    pub fn deinit(self: *Shader) void {
        gl.DeleteProgram(self.shader_program);
        self.shader_program = 0;
        self.model_loc = -1;
    }
};

/// Compile a shader from source code.
fn compile_shader(source: [:0]const u8, shader_type: gl.uint) !gl.uint {
    const shader = gl.CreateShader(shader_type);

    const pointers = [_][*]const u8{source.ptr};
    gl.ShaderSource(shader, 1, @ptrCast(&pointers), null);

    var success: c_uint = 0;
    gl.CompileShader(shader);
    gl.GetShaderiv(shader, gl.COMPILE_STATUS, @ptrCast(&success));
    if (success == 0) {
        var buf: [512]u8 = @splat(0);
        var len: c_uint = 0;
        gl.GetShaderInfoLog(shader, 512, @ptrCast(&len), &buf);
        Util.engine_logger.err("Shader compilation failed:\n{s}\n", .{buf[0..len]});
        return error.ShaderCompilationFailed;
    }

    return shader;
}

/// Consumes the input shaders and returns a linked program.
/// You cannot use vert or frag shaders after linking!
fn link_shader(vert: gl.uint, frag: gl.uint) !gl.uint {
    const program = gl.CreateProgram();
    gl.AttachShader(program, vert);
    gl.AttachShader(program, frag);
    gl.LinkProgram(program);

    var success: c_uint = 0;
    gl.GetProgramiv(program, gl.LINK_STATUS, @ptrCast(&success));
    if (success == 0) {
        var buf: [512]u8 = @splat(0);
        var len: c_uint = 0;
        gl.GetProgramInfoLog(program, 512, @ptrCast(&len), &buf);
        Util.engine_logger.err("Program linking failed:\n{s}\n", .{buf[0..len]});
        return error.ProgramLinkingFailed;
    }

    gl.DeleteShader(vert);
    gl.DeleteShader(frag);
    gl.UseProgram(program);

    return program;
}
