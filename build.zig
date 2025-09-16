const std = @import("std");

pub const Platform = enum {
    windows,
    linux,
    macos,
    psp,
};

pub const Gfx = enum {
    default,
    opengl,
    vulkan,
};

pub const Audio = enum(u8) {
    default,
};

pub const Input = enum(u8) {
    default,
};

pub const Config = struct {
    platform: Platform,
    gfx: Gfx,
    audio: Audio = Audio.default,
    input: Input = Input.default,

    pub fn resolve(target: std.Build.ResolvedTarget) Config {
        const plat: Platform = switch (target.result.os.tag) {
            .windows => .windows,
            .macos => .macos,
            .linux => .linux,
            else => |t| {
                std.debug.panic("Unsupported OS! {}\n", .{t});
            },
        };

        const gfx: Gfx = switch (target.result.os.tag) {
            .windows => .vulkan,
            .macos => .vulkan,
            .linux => .opengl,
            else => .default,
        };

        return .{
            .platform = plat,
            .gfx = gfx,
        };
    }
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const options = b.addOptions();
    options.addOption(Config, "config", Config.resolve(target));
    const options_module = options.createModule();

    // glfw.zig provides glfw compilation and wrapping
    const glfw = b.dependency("glfw_zig", .{
        .target = target,
        .optimize = optimize,
    });

    // zglfw provides Zig bindings for GLFW
    const zglfw = b.dependency("zglfw", .{
        .target = target,
        .optimize = optimize,
    });

    // zmath provides SIMD optimized mathematics
    const zmath = b.dependency("zmath", .{
        .target = target,
        .optimize = optimize,
    });

    // zigglgen provides Zig bindings for OpenGL
    const gl_bindings = @import("zigglgen").generateBindingsModule(b, .{
        .api = .gl,
        .version = .@"4.5",
        .profile = .core,
        .extensions = &.{},
    });

    // vulkan-zig provides Zig bindings for Vulkan
    const vulkan = b.dependency("vulkan", .{
        .registry = b.dependency("vulkan_headers", .{}).path("registry/vk.xml"),
    }).module("vulkan-zig");

    // zstbi provides image loading capabilities
    const zstbi = b.dependency("zstbi", .{
        .target = target,
        .optimize = optimize,
    });

    // zaudio provides audio capabilities
    const zaudio = b.dependency("zaudio", .{
        .target = target,
        .optimize = optimize,
    });

    const zbc = b.dependency("ZeeBuffer", .{});

    var zbc_compile = b.addRunArtifact(zbc.artifact("zbc"));
    zbc_compile.addFileArg(b.path("protocol.zb"));
    const protocol_path = zbc_compile.addOutputFileArg("protocol.zig");

    const protocol = b.addModule("protocol", .{
        .root_source_file = protocol_path,
        .target = target,
        .optimize = optimize,
    });

    const engine = b.addModule("Spark", .{
        .root_source_file = b.path("src/engine/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "glfw", .module = zglfw.module("glfw") },
            .{ .name = "gl", .module = gl_bindings },
            .{ .name = "zmath", .module = zmath.module("root") },
            .{ .name = "zstbi", .module = zstbi.module("root") },
            .{ .name = "zaudio", .module = zaudio.module("root") },
            .{ .name = "vulkan", .module = vulkan },
            .{ .name = "options", .module = options_module },
            .{ .name = "protocol", .module = protocol },
        },
    });
    engine.linkLibrary(zaudio.artifact("miniaudio"));

    if (target.result.os.tag == .macos) {
        engine.linkSystemLibrary("vulkan", .{});
        engine.linkSystemLibrary("glfw", .{});
    } else {
        engine.linkLibrary(glfw.artifact("glfw"));
    }

    const net = b.addModule("Net", .{
        .root_source_file = b.path("src/net/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const server = b.addModule("Server", .{
        .root_source_file = b.path("src/core/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "net", .module = net },
        },
    });

    const client_exe = b.addExecutable(.{
        .name = "CrossCraft-Classic",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/client/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "Spark", .module = engine },
                .{ .name = "zmath", .module = zmath.module("root") },
                .{ .name = "options", .module = options_module },
            },
        }),
    });

    const vert_cmd = b.addSystemCommand(&.{
        "glslc",
        "--target-env=vulkan1.3",
        "-o",
    });
    const vert_spv = vert_cmd.addOutputFileArg("vert.spv");
    vert_cmd.addFileArg(b.path("src/client/shaders/basic_vk.vert"));
    client_exe.root_module.addAnonymousImport("vertex_shader", .{
        .root_source_file = vert_spv,
    });

    const frag_cmd = b.addSystemCommand(&.{
        "glslc",
        "--target-env=vulkan1.3",
        "-o",
    });
    const frag_spv = frag_cmd.addOutputFileArg("frag.spv");
    frag_cmd.addFileArg(b.path("src/client/shaders/basic_vk.frag"));
    client_exe.root_module.addAnonymousImport("fragment_shader", .{
        .root_source_file = frag_spv,
    });

    const server_exe = b.addExecutable(.{
        .name = "CrossCraft-Server",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/server/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "core", .module = server },
                .{ .name = "net", .module = net },
            },
        }),
    });

    b.installArtifact(client_exe);
    b.installArtifact(server_exe);

    const run_client_step = b.step("run-game", "Run the app");
    const run_client_cmd = b.addRunArtifact(client_exe);
    run_client_step.dependOn(&run_client_cmd.step);
    run_client_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_client_cmd.addArgs(args);
    }

    const run_server_step = b.step("run-server", "Run the server");
    const run_server_cmd = b.addRunArtifact(server_exe);
    run_server_step.dependOn(&run_server_cmd.step);
    run_server_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_server_cmd.addArgs(args);
    }

    const engine_tests = b.addTest(.{
        .name = "engine_tests",
        .root_module = engine,
    });

    const run_tests_step = b.step("test", "Run tests");
    const run_tests_cmd = b.addRunArtifact(engine_tests);
    run_tests_step.dependOn(&run_tests_cmd.step);
    run_tests_cmd.step.dependOn(b.getInstallStep());
}
