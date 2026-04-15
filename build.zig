const std = @import("std");
const Aether = @import("engine");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const overrides: Aether.Config.Overrides = .{
        .gfx = b.option(Aether.Gfx, "gfx", "Graphics backend override (default: auto-detect from target)"),
        .psp_display_mode = b.option(Aether.PspDisplayMode, "psp-display", "PSP display mode: rgba8888 (32-bit, default) or rgb565 (16-bit)"),
        .psp_mipmaps = b.option(bool, "psp-mipmaps", "PSP: generate mip levels for VRAM-resident textures (default: false)"),
    };

    const slim = b.option(bool, "slim", "Slim mode: reduced memory, smaller render distance (for PSP-1000)") orelse false;
    const skip_pack = b.option(bool, "skip-pack", "Skip zipping resources into pack.zip (for CI builds without LFS assets)") orelse false;

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
        .imports = &.{
            .{ .name = "protocol", .module = protocol },
        },
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

    const psp_client_dir = "CrossCraft-Classic-PSP";
    const is_psp = target.result.os.tag == .psp;

    // Resource packing: ZIP the default resource pack at build time.
    // Skipped via -Dskip-pack on CI where the LFS-backed resources submodule
    // is not fetched, which would otherwise zip up LFS pointer stubs.
    const install_pack = if (skip_pack) null else blk: {
        const resources = b.dependency("resources", .{});

        const pack_tool = b.addExecutable(.{
            .name = "pack_zip",
            .root_module = b.createModule(.{
                .root_source_file = b.path("tools/pack_zip.zig"),
                .target = b.graph.host,
            }),
        });

        var pack_cmd = b.addRunArtifact(pack_tool);
        pack_cmd.addDirectoryArg(resources.path("default"));
        const pack_zip = pack_cmd.addOutputFileArg("pack.zip");

        if (is_psp) {
            const psp_install = b.addInstallFile(
                pack_zip,
                "bin/" ++ psp_client_dir ++ "/pack.zip",
            );
            break :blk &psp_install.step;
        }

        // Desktop: drop pack.zip at the project root so the binary finds it
        // regardless of whether it's launched via `zig build run-game`
        // (CWD = project root) or directly from zig-out/bin.
        const update = b.addUpdateSourceFiles();
        update.addCopyFileToSource(pack_zip, "pack.zip");
        break :blk &update.step;
    };

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
    client_exe.root_module.addImport("protocol", protocol);

    const build_options = b.addOptions();
    build_options.addOption(bool, "slim", slim);
    client_exe.root_module.addImport("build_options", build_options.createModule());

    Aether.addShader(ae_dep.builder, b, client_exe, config, "basic", .{
        .slang = b.path("src/client/shaders/basic.slang"),
    });

    Aether.exportArtifact(ae_dep.builder, b, client_exe, config, .{
        .title = "CrossCraft Classic",
        .output_dir = psp_client_dir,
    });

    // The server has no graphics — only use Aether.addGame for PSP
    // (which provides the pspsdk import and linker script). All other
    // targets build a plain executable with no engine dependency.

    const server_exe = if (is_psp)
        Aether.addGame(ae_dep.builder, b, .{
            .name = "CrossCraft-Classic-Server",
            .root_source_file = b.path("src/server/main.zig"),
            .target = target,
            .optimize = optimize,
            .overrides = overrides,
        })
    else
        b.addExecutable(.{
            .name = "CrossCraft-Classic-Server",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/server/main.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });
    server_exe.root_module.addImport("game", game);
    server_exe.root_module.addImport("common", common);

    if (is_psp) {
        Aether.exportArtifact(ae_dep.builder, b, server_exe, config, .{
            .title = "CrossCraft Classic Server",
            .output_dir = "CrossCraft-Server-PSP",
            .icon0 = b.path("assets/psp/ICON0.png"),
            .pic1 = b.path("assets/psp/PIC1.png"),
        });
    }

    const build_server_step = b.step("server", "Build the server");
    build_server_step.dependOn(&b.addInstallArtifact(server_exe, .{}).step);

    const run_server_step = b.step("run-server", "Run the server");
    const run_server_cmd = b.addRunArtifact(server_exe);
    run_server_step.dependOn(&run_server_cmd.step);

    if (b.args) |args| {
        run_server_cmd.addArgs(args);
    }

    const build_game_step = b.step("game", "Build the game");
    build_game_step.dependOn(&b.addInstallArtifact(client_exe, .{}).step);
    if (install_pack) |ip| build_game_step.dependOn(ip);
    if (is_psp) {
        // exportArtifact registers PSP pipeline steps (ELF→PRX→EBOOT.PBP)
        // on b.getInstallStep(); wire them into the game step so that
        // `zig build game -Dtarget=mipsel-psp` produces the EBOOT.
        build_game_step.dependOn(b.getInstallStep());
    }

    const run_client_step = b.step("run-game", "Run the app");
    const run_client_cmd = b.addRunArtifact(client_exe);
    if (install_pack) |ip| run_client_cmd.step.dependOn(ip);
    run_client_step.dependOn(&run_client_cmd.step);

    if (b.args) |args| {
        run_client_cmd.addArgs(args);
    }

    const test_step = b.step("test", "Run unit tests");

    const zip_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/client/util/Zip.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(zip_tests).step);
}
