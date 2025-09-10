const std = @import("std");
const gl = @import("gl");
const zm = @import("zmath");
const assert = std.debug.assert;
const Util = @import("../../../util/util.zig");

const vert_source = @embedFile("shaders/basic.vert");
const frag_source = @embedFile("shaders/basic.frag");

pub const ShaderState = struct {
    view: zm.Mat,
    proj: zm.Mat,
};

pub var state: ShaderState = .{
    .view = zm.identity(),
    .proj = zm.identity(),
};

var shader_program: gl.uint = 0;
var ubo: gl.uint = 0;
var model_loc: gl.int = -1;

var initialized = false;

/// Compile a shader from source code.
fn compile_shader(source: [*]const [*]const gl.char, shader_type: gl.uint) !gl.uint {
    const shader = gl.CreateShader(shader_type);
    gl.ShaderSource(shader, 1, source, null);

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

pub fn init() !void {
    assert(!initialized);
    initialized = true;

    const vert = try compile_shader(@ptrCast(&vert_source), gl.VERTEX_SHADER);
    const frag = try compile_shader(@ptrCast(&frag_source), gl.FRAGMENT_SHADER);
    shader_program = try link_shader(vert, frag);

    gl.CreateBuffers(1, @ptrCast(&ubo));
    gl.NamedBufferStorage(ubo, @sizeOf(ShaderState), &state, gl.DYNAMIC_STORAGE_BIT);
    gl.BindBufferBase(gl.UNIFORM_BUFFER, 0, ubo);

    model_loc = gl.GetUniformLocation(shader_program, "u_model");

    assert(model_loc != -1);
    assert(ubo != 0);
    assert(shader_program != 0);
    assert(initialized);
}

pub fn update_model(model_mat: *const zm.Mat) void {
    assert(initialized);
    gl.ProgramUniformMatrix4fv(shader_program, model_loc, 1, gl.FALSE, @ptrCast(model_mat));
}

pub fn update_ubo() void {
    gl.NamedBufferSubData(ubo, 0, @sizeOf(ShaderState), &state);
}

pub fn deinit() void {
    assert(initialized);
    initialized = false;

    gl.DeleteProgram(shader_program);
    shader_program = 0;

    assert(!initialized);
}
