const std = @import("std");
const Aether = @import("engine");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const web_host = b.option([]const u8, "web-host", "serve-web: bind host (default: 127.0.0.1)") orelse "127.0.0.1";
    const web_port = b.option(u16, "web-port", "serve-web: bind port (default: 8080)") orelse 8080;

    const overrides: Aether.config.Config.Overrides = .{
        .gfx = b.option(Aether.config.Gfx, "gfx", "Graphics backend override (default: auto-detect from target)"),
        .audio = b.option(Aether.config.Audio, "audio", "Audio backend override (default: auto-detect from target)"),
        .psp_display_mode = b.option(Aether.config.PspDisplayMode, "psp-display", "PSP display mode: rgba8888 (32-bit, default) or rgb565 (16-bit)"),
        .psp_mipmaps = b.option(bool, "psp-mipmaps", "PSP: generate mip levels for VRAM-resident textures (default: false)"),
        .nintendo_switch = b.option(bool, "nintendo-switch", "Build for Nintendo Switch (requires -Dtarget=aarch64-freestanding-none and devkitA64/libnx)"),
        .use_cwd = b.option(bool, "use-cwd", "Force resources+data dirs to CWD (debug/CI convenience; default: false)"),
        .flush_logs = b.option(bool, "flush-logs", "Flush aether.log after every log message (debugging hard hangs; default: false)"),
        .mesh_indexing = b.option(bool, "mesh-indexing", "Enable mesh index buffers (default: on except PSP/headless; override works on all backends)"),
    };

    const skip_pack = b.option(bool, "skip-pack", "Skip zipping resources into pack.zip (for CI builds without LFS assets)") orelse false;

    const config = Aether.config.Config.resolve(target, overrides);

    const zbc = b.dependency("ZeeBuffer", .{});

    var zbc_compile = b.addRunArtifact(zbc.artifact("zbc"));
    zbc_compile.addFileArg(b.path("protocol.zb"));
    const protocol_path = zbc_compile.addOutputFileArg("protocol.zig");

    const protocol = b.addModule("protocol", .{
        .root_source_file = protocol_path,
        .optimize = optimize,
    });

    const common = b.addModule("common", .{
        .root_source_file = b.path("src/common/root.zig"),
        .optimize = optimize,
        .imports = &.{
            .{ .name = "protocol", .module = protocol },
        },
    });

    const game = b.addModule("game", .{
        .root_source_file = b.path("src/game/root.zig"),
        .optimize = optimize,
        .imports = &.{
            .{ .name = "protocol", .module = protocol },
            .{ .name = "common", .module = common },
        },
    });

    const psp_client_dir = "CrossCraft-Classic-PSP";
    const nintendo_3ds_client_dir = "CrossCraft-Classic-3DS";
    const nintendo_switch_client_dir = "CrossCraft-Classic-Switch";
    const is_psp = config.platform == .psp;
    const is_macos = config.platform == .macos;
    const is_3ds = config.platform == .nintendo_3ds;
    const is_switch = config.platform == .nintendo_switch;
    const is_windows = config.platform == .windows;
    const is_desktop = switch (config.platform) {
        .windows, .linux => true,
        else => false,
    };
    const is_pc_server = switch (config.platform) {
        .windows, .linux, .macos => true,
        else => false,
    };

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
    //   3DS: install beside the 3dsx; users copy the directory to SDMC.
    //   Switch: install beside the NRO; users copy the directory to SDMC.
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
        if (is_3ds) {
            const nintendo_3ds_install = b.addInstallFile(
                pack_zip,
                "bin/" ++ nintendo_3ds_client_dir ++ "/pack.zip",
            );
            break :blk &nintendo_3ds_install.step;
        }
        if (is_switch) {
            const nintendo_switch_install = b.addInstallFile(
                pack_zip,
                "bin/" ++ nintendo_switch_client_dir ++ "/pack.zip",
            );
            break :blk &nintendo_switch_install.step;
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
        .@"nintendo-switch" = overrides.nintendo_switch orelse false,
        .@"mesh-indexing" = overrides.mesh_indexing,
    });

    // OpenGL builds get a `_GL` suffix so the default (Vulkan on desktop,
    // GE on PSP) keeps shipping under the canonical name while GL variants
    // can sit alongside it in the release bin dir.
    const client_name = switch (config.gfx) {
        .opengl => "CrossCraft-Classic_GL",
        else => "CrossCraft-Classic",
    };

    const client_exe = Aether.modules.addGame(ae_dep.builder, b, .{
        .name = client_name,
        .root_source_file = b.path("src/client/main.zig"),
        .target = target,
        .optimize = optimize,
        .overrides = overrides,
    });
    const client_root = Aether.modules.userRootModule(client_exe);
    client_root.addImport("game", game);
    client_root.addImport("common", common);
    client_root.addImport("protocol", protocol);

    // Embed pack.zip directly in the binary on Linux/Windows release builds.
    // CI and dev builds use -Duse-cwd=true which skips embedding, keeping
    // artifacts small (pack.zip can be 90+ MB).
    if (should_embed) {
        client_root.addAnonymousImport("default_pack", .{
            .root_source_file = pack_zip_path.?,
        });
    }

    const build_options = b.addOptions();
    build_options.addOption(bool, "embed_pack", should_embed);
    client_root.addImport("build_options", build_options.createModule());

    // On macOS we pipe pack.zip through exportArtifact so it lands in
    // Contents/Resources/ inside the .app bundle. On PSP/3DS/desktop the
    // install_pack branch above handles placement.
    const mac_resources: []const Aether.packaging.Resource = if (is_macos and pack_zip_path != null)
        &.{.{ .path = pack_zip_path.?, .name = "pack.zip" }}
    else
        &.{};
    Aether.packaging.exportArtifact(ae_dep.builder, b, client_exe, config, .{
        .title = "CrossCraft Classic",
        .output_dir = if (is_psp) psp_client_dir else if (is_3ds) nintendo_3ds_client_dir else if (is_switch) nintendo_switch_client_dir else null,
        .bundle_id = "com.iridescentrose.crosscraft-classic",
        .resources = mac_resources,
        .nintendo_3ds_description = if (is_3ds) "Clean-room Minecraft Classic" else "",
        .nintendo_3ds_publisher = if (is_3ds) "CrossCraft" else "",
        .switch_author = if (is_switch) "CrossCraft" else "",
        .switch_version = if (is_switch) "0.0.0" else "",
        // Each platform consumes its native icon format: Aether turns the
        // macOS PNG into an .icns, embeds the Windows .ico in the PE resource
        // table, and feeds the console artwork to their package builders.
        .icon_png = if (is_macos) b.path("assets/icon-osx.png") else null,
        .windows_icon = if (is_windows) b.path("assets/icon-win32.ico") else null,
        .icon0 = if (is_psp) b.path("assets/icon-psp.png") else null,
        .pic1 = if (is_psp) b.path("assets/banner-psp-pic1.png") else null,
        .nintendo_3ds_icon = if (is_3ds) b.path("assets/icon-3ds.png") else null,
        .switch_icon = if (is_switch) b.path("assets/icon-switch.jpg") else null,
    });

    if (is_pc_server) {
        const server_overrides: Aether.config.Config.Overrides = .{
            .use_cwd = true,
        };
        const server_exe = Aether.modules.addHeadless(ae_dep.builder, b, .{
            .name = "CrossCraft-Classic-Server",
            .root_source_file = b.path("src/server/main.zig"),
            .target = target,
            .optimize = optimize,
            .overrides = server_overrides,
        });
        const server_root = Aether.modules.userRootModule(server_exe);
        server_root.addImport("game", game);
        server_root.addImport("common", common);

        const build_server_step = b.step("server", "Build the server");
        build_server_step.dependOn(&b.addInstallArtifact(server_exe, .{}).step);

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
    } else {
        const unsupported_server = b.addFail("Standalone server builds are supported only on PC targets (Linux, macOS, Windows).");

        const build_server_step = b.step("server", "Build the server");
        build_server_step.dependOn(&unsupported_server.step);

        const run_server_step = b.step("run-server", "Run the server");
        run_server_step.dependOn(&unsupported_server.step);
    }

    const build_game_step = b.step("game", "Build the game");
    // macOS ships the exe inside CrossCraft-Classic.app (wired by
    // Aether.exportArtifact onto b.getInstallStep()). Installing a flat
    // copy alongside would duplicate the binary and confuse downstream
    // packaging.
    if (!is_macos and !is_3ds and !is_switch) {
        build_game_step.dependOn(&b.addInstallArtifact(client_exe, .{}).step);
    }
    if (install_pack) |ip| build_game_step.dependOn(ip);
    if (is_psp or is_macos or is_3ds or is_switch) {
        // exportArtifact registers pipeline / bundle steps on
        // b.getInstallStep(); wire them into the game step so
        // `zig build game -Dtarget=<platform>` produces the artifact.
        build_game_step.dependOn(b.getInstallStep());
    }

    const run_client_step = b.step("run-game", "Run the app");
    if (is_3ds) {
        const threedsx_path = b.getInstallPath(
            .bin,
            b.fmt("{s}/{s}.3dsx", .{ nintendo_3ds_client_dir, client_name }),
        );
        const link_cmd = Aether.packaging.add3dslink(b, threedsx_path);
        link_cmd.step.dependOn(build_game_step);
        run_client_step.dependOn(&link_cmd.step);

        const link_step = b.step("3dslink", "Push the 3dsx to a networked 3DS via 3dslink");
        link_step.dependOn(&link_cmd.step);
    } else if (is_switch) {
        const nro_path = b.getInstallPath(
            .bin,
            b.fmt("{s}/{s}.nro", .{ nintendo_switch_client_dir, client_name }),
        );
        const nxlink_path = b.option([]const u8, "nxlink-path", "Switch: path to nxlink (default: $DEVKITPRO/tools/bin/nxlink or /opt/devkitpro/tools/bin/nxlink)") orelse blk: {
            const dkp = b.graph.environ_map.get("DEVKITPRO") orelse "/opt/devkitpro";
            break :blk b.pathJoin(&.{ dkp, "tools/bin/nxlink" });
        };
        const link_cmd = b.addSystemCommand(&.{nxlink_path});
        if (b.option([]const u8, "nxlink-address", "Switch: target IP for nxlink push (default: mDNS auto-discover)")) |ip| {
            link_cmd.addArgs(&.{ "-a", ip });
        }
        if (b.option(u32, "nxlink-retries", "Switch: nxlink retry count (default: 10)")) |n| {
            link_cmd.addArgs(&.{ "-r", b.fmt("{d}", .{n}) });
        }
        if (b.option(bool, "nxlink-server", "Switch: pass -s so nxlink stays listening after upload (relays stdout/stderr from nro)") orelse false) {
            link_cmd.addArg("-s");
        }
        link_cmd.addArg(nro_path);
        link_cmd.step.dependOn(build_game_step);
        if (b.args) |args| {
            link_cmd.addArg("--args");
            link_cmd.addArgs(args);
        }
        run_client_step.dependOn(&link_cmd.step);

        const link_step = b.step("nxlink", "Push the nro to a networked Switch via nxlink");
        link_step.dependOn(&link_cmd.step);
    } else {
        // macOS must run the binary from inside the .app bundle: pack.zip
        // is installed into <Bundle>.app/Contents/Resources/ by
        // exportArtifact, and the engine resolves the resources dir from
        // the exe path (only bundle-laid-out exes look in Contents/).
        // Running the raw cache artifact would leave it looking for
        // pack.zip beside the cache binary and fail with FileNotFound.
        const run_client_cmd = if (is_macos)
            b.addSystemCommand(&.{b.getInstallPath(
                .bin,
                b.fmt("{s}.app/Contents/MacOS/{s}", .{ client_name, client_name }),
            )})
        else
            b.addRunArtifact(client_exe);
        // Same cwd reasoning as run-server: under -Duse-cwd=true the binary
        // finds the installed pack.zip here, and any data it writes
        // (options.json, texturepacks/) lands alongside it.
        run_client_cmd.setCwd(.{ .cwd_relative = b.getInstallPath(.bin, "") });
        run_client_cmd.step.dependOn(build_game_step);
        run_client_step.dependOn(&run_client_cmd.step);

        if (b.args) |args| {
            run_client_cmd.addArgs(args);
        }
    }

    const test_step = b.step("test", "Run unit tests");

    const test_filters = b.option([]const []const u8, "test-filter", "Skip tests that do not match any filter") orelse &.{};
    const unit_tests = b.addTest(.{
        .root_module = unit_tests_root: {
            const root = b.createModule(.{
                .root_source_file = b.path("src/unit.zig"),
                .target = target,
                .optimize = optimize,
            });
            root.addImport("aether", client_root.import_table.get("aether").?);
            root.addImport("common", common);
            root.addImport("game", game);
            break :unit_tests_root root;
        },
        .filters = test_filters,
    });
    test_step.dependOn(&b.addRunArtifact(unit_tests).step);

    // Standalone build step for the pack_zip host tool.
    // Usage: zig build pack-tool
    // Produces zig-out/bin/pack_zip (host-native binary).
    const pack_tool_step = b.step("pack-tool", "Build the pack_zip resource packing tool");
    const pack_tool_exe = b.addExecutable(.{
        .name = "pack_zip",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/pack_zip.zig"),
            .target = b.graph.host,
        }),
    });
    pack_tool_step.dependOn(&b.addInstallArtifact(pack_tool_exe, .{}).step);

    // Standalone save conversion/editing tool.
    // Usage: zig build savetool
    // Produces zig-out/bin/savetool (host-native binary).
    const savetool_step = b.step("savetool", "Build the save conversion/editing tool");
    const savetool_exe = b.addExecutable(.{
        .name = "savetool",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/savetool.zig"),
            .target = b.graph.host,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "common", .module = common },
                .{ .name = "game", .module = game },
            },
        }),
    });
    savetool_step.dependOn(&b.addInstallArtifact(savetool_exe, .{}).step);

    const web_target = Aether.config.webTarget(b);
    const web_overrides: Aether.config.Config.Overrides = .{
        .gfx = .webgl,
        .use_cwd = true,
    };
    const web_exe = Aether.modules.addGame(ae_dep.builder, b, .{
        .name = "CrossCraft-Classic",
        .root_source_file = b.path("src/client/web_main.zig"),
        .target = web_target,
        .optimize = optimize,
        .overrides = web_overrides,
    });
    const web_root = Aether.modules.userRootModule(web_exe);
    web_root.addImport("game", game);
    web_root.addImport("common", common);
    web_root.addImport("protocol", protocol);

    const web_build_options = b.addOptions();
    web_build_options.addOption(bool, "embed_pack", false);
    web_root.addImport("build_options", web_build_options.createModule());

    const web_resource_files: []const Aether.packaging.Resource = if (pack_zip_path) |pack_zip|
        &.{.{ .path = pack_zip, .name = "pack.zip" }}
    else
        &.{};
    const web_install = Aether.packaging.addWebBundle(ae_dep.builder, b, web_exe, .{
        .web_resource_files = web_resource_files,
        .web_resource_manifest = if (pack_zip_path != null) "pack.zip\n" else "",
        .web_app_module = b.path("web/crosscraft.js"),
    });

    const web_step = b.step("web", "Build the browser-playable WASM site in zig-out/web");
    web_step.dependOn(&web_install.step);

    const serve_web_cmd = Aether.packaging.addServeWebStep(
        ae_dep.builder,
        b,
        "crosscraft-serve-web",
        web_install,
        web_host,
        web_port,
    );

    const serve_web_step = b.step("serve-web", "Serve zig-out/web with WASM MIME and COOP/COEP headers");
    serve_web_step.dependOn(&serve_web_cmd.step);
}
