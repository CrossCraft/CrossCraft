const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

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

    const mod = b.addModule("Spark", .{
        .root_source_file = b.path("src/engine/root.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "glfw", .module = zglfw.module("glfw") },
            .{ .name = "gl", .module = gl_bindings },
            .{ .name = "zmath", .module = zmath.module("root") },
        },
    });
    mod.linkLibrary(glfw.artifact("glfw"));

    const exe = b.addExecutable(.{
        .name = "CrossCraft-Classic",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/game/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "Spark", .module = mod },
            },
        }),
    });

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const engine_tests = b.addTest(.{
        .name = "engine_tests",
        .root_module = mod,
    });

    const run_tests_step = b.step("test", "Run tests");
    const run_tests_cmd = b.addRunArtifact(engine_tests);
    run_tests_step.dependOn(&run_tests_cmd.step);
    run_tests_cmd.step.dependOn(b.getInstallStep());
}
