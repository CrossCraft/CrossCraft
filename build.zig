const std = @import("std");
const Aether = @import("engine");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const overrides: Aether.Config.Overrides = .{
        .gfx = b.option(Aether.Gfx, "gfx", "Graphics backend override (default: auto-detect from target)"),
        .psp_display_mode = b.option(Aether.PspDisplayMode, "psp-display", "PSP display mode: rgba8888 (32-bit, default) or rgb565 (16-bit)"),
        .psp_mipmaps = b.option(bool, "psp-mipmaps", "PSP: generate mip levels for VRAM-resident textures (default: false)"),
        .use_cwd = b.option(bool, "use-cwd", "Force resources+data dirs to CWD (debug/CI convenience; default: false)"),
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
    const is_macos = target.result.os.tag == .macos;
    const is_desktop = !is_psp and !is_macos;

    // Resource packing: ZIP the default resource pack at build time.
    // Skipped via -Dskip-pack on CI where the LFS-backed resources submodule
    // is not fetched, which would otherwise zip up LFS pointer stubs.
    const pack_zip_path: ?std.Build.LazyPath = if (skip_pack) null else blk: {
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
        break :blk pack_cmd.addOutputFileArg("pack.zip");
    };

    // Whether pack.zip is embedded directly in the Linux/Windows binary.
    // True for local release builds; false for -Duse-cwd (CI/dev) and all
    // other platforms.
    const should_embed = is_desktop and pack_zip_path != null and !(overrides.use_cwd orelse false);

    // Packaging strategy per platform:
    //   PSP: install into bin/<psp_client_dir>/ for EBOOT layout.
    //   macOS: routed through Aether.exportArtifact into the .app bundle's
    //     Contents/Resources/ — see below.
    //   Desktop, embedding: pack.zip is baked into the binary; no loose file.
    //   Desktop, -Duse-cwd: install to zig-out/bin/ so run-game (which cd's
    //     into the install dir before exec) and distribution zips both find it.
    const install_pack: ?*std.Build.Step = if (pack_zip_path) |pack_zip| blk: {
        if (is_psp) {
            const psp_install = b.addInstallFile(
                pack_zip,
                "bin/" ++ psp_client_dir ++ "/pack.zip",
            );
            break :blk &psp_install.step;
        }
        if (is_macos) break :blk null; // Aether.exportArtifact installs via opts.resources.
        if (should_embed) break :blk null; // Baked into binary; no separate file needed.

        // -Duse-cwd path: install pack.zip alongside the binary in
        // zig-out/bin/. The run-game step sets cwd to the install dir so
        // the binary finds it there, and distribution zips (zig-out/) get
        // the pack for free.
        const bin_install = b.addInstallFile(pack_zip, "bin/pack.zip");
        break :blk &bin_install.step;
    } else null;

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

    // Embed pack.zip directly in the binary on Linux/Windows release builds.
    // CI and dev builds use -Duse-cwd=true which skips embedding, keeping
    // artifacts small (pack.zip can be 90+ MB).
    if (should_embed) {
        client_exe.root_module.addAnonymousImport("default_pack", .{
            .root_source_file = pack_zip_path.?,
        });
    }

    const build_options = b.addOptions();
    build_options.addOption(bool, "slim", slim);
    build_options.addOption(bool, "embed_pack", should_embed);
    client_exe.root_module.addImport("build_options", build_options.createModule());

    Aether.addShader(ae_dep.builder, b, client_exe, config, "basic", .{
        .slang = b.path("src/client/shaders/basic.slang"),
    });

    // On macOS we pipe pack.zip through exportArtifact so it lands in
    // Contents/Resources/ inside the .app bundle. On PSP/desktop the
    // install_pack branch above handles placement.
    const mac_resources: []const Aether.ExportOptions.Resource = if (is_macos and pack_zip_path != null)
        &.{.{ .path = pack_zip_path.?, .name = "pack.zip" }}
    else
        &.{};

    Aether.exportArtifact(ae_dep.builder, b, client_exe, config, .{
        .title = "CrossCraft Classic",
        .output_dir = psp_client_dir,
        .bundle_id = "com.iridescentrose.crosscraft-classic",
        .resources = mac_resources,
        // Reusing the Vita icon as a placeholder — 128×128 upscales for
        // the larger .icns slots but it's serviceable. Swap in a 1024×1024
        // PNG later if you want sharper Dock/Finder rendering.
        .icon_png = if (is_macos) b.path("assets/vita/icon0.png") else null,
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
    if (is_psp) {
        // exportArtifact wires the PRX -> SFO -> PBP pipeline onto
        // b.getInstallStep(); without this dep `zig build server` produces
        // only the raw ELF and CrossCraft-Server-PSP/EBOOT.PBP never
        // materialises. Mirrors the game step's PSP/macOS handling below.
        build_server_step.dependOn(b.getInstallStep());
    }

    const run_server_step = b.step("run-server", "Run the server");
    const run_server_cmd = b.addRunArtifact(server_exe);
    // Run from zig-out/bin/ so server.zig's cwd-rooted data files
    // (world.dat, server.properties) land in the install dir instead of
    // polluting the source tree.
    run_server_cmd.setCwd(.{ .cwd_relative = b.getInstallPath(.bin, "") });
    run_server_cmd.step.dependOn(build_server_step);
    run_server_step.dependOn(&run_server_cmd.step);

    if (b.args) |args| {
        run_server_cmd.addArgs(args);
    }

    const build_game_step = b.step("game", "Build the game");
    // macOS ships the exe inside CrossCraft-Classic.app (wired by
    // Aether.exportArtifact onto b.getInstallStep()). Installing a flat
    // copy alongside would duplicate the binary and confuse downstream
    // packaging.
    if (!is_macos) {
        build_game_step.dependOn(&b.addInstallArtifact(client_exe, .{}).step);
    }
    if (install_pack) |ip| build_game_step.dependOn(ip);
    if (is_psp or is_macos) {
        // exportArtifact registers pipeline / bundle steps on
        // b.getInstallStep(); wire them into the game step so
        // `zig build game -Dtarget=<platform>` produces the artifact.
        build_game_step.dependOn(b.getInstallStep());
    }

    const run_client_step = b.step("run-game", "Run the app");
    const run_client_cmd = b.addRunArtifact(client_exe);
    // Same cwd reasoning as run-server: under -Duse-cwd=true the binary
    // finds the installed pack.zip here, and any data it writes
    // (options.json, texturepacks/) lands alongside it.
    run_client_cmd.setCwd(.{ .cwd_relative = b.getInstallPath(.bin, "") });
    run_client_cmd.step.dependOn(build_game_step);
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
