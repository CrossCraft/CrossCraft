const std = @import("std");
const Aether = @import("engine");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const overrides: Aether.Config.Overrides = .{
        .gfx = b.option(Aether.Gfx, "gfx", "Graphics backend override (default: auto-detect from target)"),
    };

    const config = Aether.Config.resolve(target, overrides);

    const zbc = b.dependency("ZeeBuffer", .{});

    var zbc_compile = b.addRunArtifact(zbc.artifact("zbc"));
    zbc_compile.addFileArg(b.path("protocol.zb"));
    const protocol_path = zbc_compile.addOutputFileArg("protocol.zig");

    const protocol = b.addModule("protocol", .{
        .root_source_file = protocol_path,
        .target = target,
        .optimize = optimize,
    });

    const common = b.addModule("common", .{
        .root_source_file = b.path("src/common/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const game = b.addModule("game", .{
        .root_source_file = b.path("src/game/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "protocol", .module = protocol },
            .{ .name = "common", .module = common },
        },
    });

    const ae_dep = b.dependency("engine", .{
        .target = target,
        .optimize = optimize,
    });

    const client_exe = Aether.addGame(ae_dep.builder, b, .{
        .name = "CrossCraft-Classic",
        .root_source_file = b.path("src/client/main.zig"),
        .target = target,
        .optimize = optimize,
        .overrides = overrides,
    });
    client_exe.root_module.addImport("game", game);
    client_exe.root_module.addImport("common", common);

    Aether.addShader(ae_dep.builder, b, client_exe, config, "basic", .{
        .slang = b.path("src/client/shaders/basic.slang"),
    });

    Aether.exportArtifact(ae_dep.builder, b, client_exe, config, .{
        .title = "CrossCraft Classic",
        .output_dir = "CrossCraft-Classic-PSP",
    });

    const server_exe = Aether.addGame(ae_dep.builder, b, .{
        .name = "CrossCraft-Classic-Server",
        .root_source_file = b.path("src/server/main.zig"),
        .target = target,
        .optimize = optimize,
        .overrides = overrides,
    });
    server_exe.root_module.addImport("game", game);
    server_exe.root_module.addImport("common", common);

    Aether.exportArtifact(ae_dep.builder, b, server_exe, config, .{
        .title = "CrossCraft Classic Server",
        .output_dir = "CrossCraft-Server-PSP",
    });

    const run_server_step = b.step("run-server", "Run the server");
    const run_server_cmd = b.addRunArtifact(server_exe);
    run_server_step.dependOn(&run_server_cmd.step);

    if (b.args) |args| {
        run_server_cmd.addArgs(args);
    }

    const run_client_step = b.step("run-game", "Run the app");
    const run_client_cmd = b.addRunArtifact(client_exe);
    run_client_step.dependOn(&run_client_cmd.step);

    if (b.args) |args| {
        run_client_cmd.addArgs(args);
    }
}
