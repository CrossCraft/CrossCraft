const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const engine_dep = b.dependency("engine", .{});
    const engine = engine_dep.module("Aether");

    const zbc = b.dependency("ZeeBuffer", .{});

    var zbc_compile = b.addRunArtifact(zbc.artifact("zbc"));
    zbc_compile.addFileArg(b.path("protocol.zb"));
    const protocol_path = zbc_compile.addOutputFileArg("protocol.zig");

    const protocol = b.addModule("protocol", .{
        .root_source_file = protocol_path,
        .target = target,
        .optimize = optimize,
    });

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
            .{ .name = "protocol", .module = protocol },
        },
    });

    const client_exe = b.addExecutable(.{
        .name = "CrossCraft-Classic",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/client/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "aether", .module = engine },
                .{ .name = "core", .module = server },
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

    if (b.args) |args| {
        run_client_cmd.addArgs(args);
    }

    const run_server_step = b.step("run-server", "Run the server");
    const run_server_cmd = b.addRunArtifact(server_exe);
    run_server_step.dependOn(&run_server_cmd.step);

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
