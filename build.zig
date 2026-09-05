const std = @import("std");
const Aether = @import("engine");
const Capabilities = @import("src/capabilities.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const web_host = b.option([]const u8, "web-host", "serve-web: bind host (default: 127.0.0.1)") orelse "127.0.0.1";
    const web_port = b.option(u16, "web-port", "serve-web: bind port (default: 8080)") orelse 8080;

    const lint_dep = b.dependency("lint", .{
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
    });
    const lint_roots: []const []const u8 = &.{
        ".",
        "src/unit.zig",
        "src/client/web_main.zig",
    };

    const run_lint = b.addRunArtifact(lint_dep.artifact("lint"));
    run_lint.setCwd(b.path("."));
    if (b.graph.environ_map.get("CI") != null) {
        run_lint.addArg("--check-only");
    }
    // Include roots that Zig imports cannot reach in dead-file analysis.
    run_lint.addArgs(lint_roots);

    const lint_step = b.step("lint", "Lint the codebase with tiger_lint");
    lint_step.dependOn(&run_lint.step);
    b.getInstallStep().dependOn(lint_step);

    const run_lint_metrics = b.addRunArtifact(lint_dep.artifact("lint"));
    run_lint_metrics.setCwd(b.path("."));
    run_lint_metrics.addArgs(&.{ "--check-only", "--metrics" });
    run_lint_metrics.addArgs(lint_roots);

    const lint_metrics_step = b.step(
        "lint-metrics",
        "Lint the codebase and print AST metrics as JSON",
    );
    lint_metrics_step.dependOn(&run_lint_metrics.step);

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
    const policy = Capabilities.build_policy(config, target.result);
    const capabilities = b.addModule("capabilities", .{
        .root_source_file = b.path("src/capabilities.zig"),
        .optimize = optimize,
    });

    const zbc = b.dependency("ZeeBuffer", .{});

    var zbc_compile = b.addRunArtifact(zbc.artifact("zbc"));
    zbc_compile.addFileArg(b.path("protocol.zb"));
    const protocol_path = zbc_compile.addOutputFileArg("protocol.zig");

    const protocol = b.addModule("protocol", .{
        .root_source_file = protocol_path,
        .optimize = optimize,
    });

    const worldgen = b.addModule("worldgen", .{
        .root_source_file = b.path("src/core/worldgen/root.zig"),
        .optimize = .ReleaseFast,
        .imports = &.{.{ .name = "capabilities", .module = capabilities }},
    });

    const core = b.addModule("core", .{
        .root_source_file = b.path("src/core/root.zig"),
        .optimize = optimize,
        .imports = &.{
            .{ .name = "protocol", .module = protocol },
            .{ .name = "worldgen", .module = worldgen },
            .{ .name = "capabilities", .module = capabilities },
        },
    });

    const console_client_dir = policy.client_dir;

    // CI can skip packing when the LFS-backed resources are unavailable.
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
    const archival_save_path = b.path("saves/origins.cw");

    const should_embed = policy.embed_default_pack and pack_zip_path != null and !(overrides.use_cwd orelse false);

    const install_pack: ?*std.Build.Step = if (pack_zip_path) |pack_zip| blk: {
        // macOS packaging installs the pack inside the signed app bundle.
        if (policy.bundle_resources or should_embed) break :blk null;
        const path = if (console_client_dir) |dir| b.fmt("bin/{s}/pack.zip", .{dir}) else "bin/pack.zip";
        break :blk &b.addInstallFile(pack_zip, path).step;
    } else null;

    const ae_dep = b.dependency("engine", .{
        .target = target,
        .optimize = optimize,
        .@"nintendo-switch" = overrides.nintendo_switch orelse false,
        .@"mesh-indexing" = overrides.mesh_indexing,
    });

    const client_name = "CrossCraft-Classic";

    const client_exe = Aether.modules.add_game(ae_dep.builder, b, .{
        .name = client_name,
        .root_source_file = b.path("src/client/main.zig"),
        .target = target,
        .optimize = optimize,
        .overrides = overrides,
    });
    if (policy.use_llvm_linker) {
        client_exe.use_llvm = true;
        client_exe.use_lld = true;
    }
    const client_root = Aether.modules.user_root_module(client_exe);
    client_root.addImport("core", core);
    client_root.addImport("capabilities", capabilities);
    if (client_root.import_table.get("pspsdk")) |sdk| capabilities.addImport("pspsdk", sdk);
    client_root.addImport("protocol", protocol);

    if (should_embed) {
        client_root.addAnonymousImport("default_pack", .{
            .root_source_file = pack_zip_path.?,
        });
    }

    const build_options = b.addOptions();
    build_options.addOption(bool, "embed_pack", should_embed);
    client_root.addImport("build_options", build_options.createModule());

    const mac_resources: []const Aether.packaging.Resource = if (policy.bundle_resources) blk: {
        if (pack_zip_path) |pack_zip| {
            break :blk &.{
                .{ .path = pack_zip, .name = "pack.zip" },
                .{ .path = archival_save_path, .name = "saves/origins.cw" },
            };
        }
        break :blk &.{.{ .path = archival_save_path, .name = "saves/origins.cw" }};
    } else &.{};
    const packaged = Aether.packaging.export_artifact_with_outputs(ae_dep.builder, b, client_exe, config, .{
        .title = "CrossCraft Classic",
        .output_dir = console_client_dir,
        .bundle_id = "com.iridescentrose.crosscraft-classic",
        .resources = mac_resources,
        .nintendo_3ds_description = policy.description,
        .nintendo_3ds_publisher = policy.publisher,
        .switch_author = policy.author,
        .switch_version = policy.version,
        .icon_png = if (policy.icon_png) |path| b.path(path) else null,
        .windows_icon = if (policy.windows_icon) |path| b.path(path) else null,
        .icon0 = if (policy.icon0) |path| b.path(path) else null,
        .pic1 = if (policy.pic1) |path| b.path(path) else null,
        .nintendo_3ds_icon = if (policy.nintendo_3ds_icon) |path| b.path(path) else null,
        .switch_icon = if (policy.switch_icon) |path| b.path(path) else null,
    });

    if (policy.standalone_server) {
        const server_overrides: Aether.config.Config.Overrides = .{
            .use_cwd = true,
        };
        const server_exe = Aether.modules.add_headless(ae_dep.builder, b, .{
            .name = "CrossCraft-Classic-Server",
            .root_source_file = b.path("src/server/main.zig"),
            .target = target,
            .optimize = optimize,
            .overrides = server_overrides,
        });
        const server_root = Aether.modules.user_root_module(server_exe);
        server_root.addImport("core", core);
        server_root.addImport("capabilities", capabilities);

        const build_server_step = b.step("server", "Build the server");
        build_server_step.dependOn(lint_step);
        build_server_step.dependOn(&b.addInstallArtifact(server_exe, .{}).step);

        const run_server_step = b.step("run-server", "Run the server");
        const run_server_cmd = b.addRunArtifact(server_exe);
        // Keep server data under zig-out/bin instead of the source tree.
        run_server_cmd.setCwd(.{ .cwd_relative = b.getInstallPath(.bin, "") });
        run_server_cmd.step.dependOn(build_server_step);
        run_server_step.dependOn(&run_server_cmd.step);

        if (b.args) |args| {
            run_server_cmd.addArgs(args);
        }
    } else {
        const unsupported_server = b.addFail("Standalone server builds are supported only on PC targets (Linux, macOS, Windows).");

        const build_server_step = b.step("server", "Build the server");
        build_server_step.dependOn(lint_step);
        build_server_step.dependOn(&unsupported_server.step);

        const run_server_step = b.step("run-server", "Run the server");
        run_server_step.dependOn(&unsupported_server.step);
    }

    const build_game_step = b.step("game", "Build the game");
    build_game_step.dependOn(lint_step);
    // Bundled targets install through the packaging pipeline.
    if (policy.install_raw_executable) {
        build_game_step.dependOn(&b.addInstallArtifact(client_exe, .{}).step);
    }
    if (install_pack) |ip| build_game_step.dependOn(ip);
    if (policy.install_package) {
        build_game_step.dependOn(b.getInstallStep());
    }

    const run_client_step = b.step("run-game", "Run the app");
    if (policy.launch == .network_3ds) {
        const threedsx = packaged.nintendo_3dsx orelse unreachable;
        const link_cmd = Aether.packaging.add_link3dsx(b, threedsx, .{
            .address = b.option([]const u8, "3dslink-address", "3DS: target IP for 3dslink push (default: broadcast auto-discover)"),
            .retries = b.option(u32, "3dslink-retries", "3DS: broadcast-discovery retry count (default: Zitrus default)"),
        });
        link_cmd.step.dependOn(build_game_step);
        run_client_step.dependOn(&link_cmd.step);

        const link_step = b.step("3dslink", "Push the 3dsx to a networked 3DS via 3dslink");
        link_step.dependOn(&link_cmd.step);
    } else if (policy.launch == .network_switch) {
        const nro_path = b.getInstallPath(
            .bin,
            b.fmt("{s}/{s}.nro", .{ console_client_dir.?, client_name }),
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
        // macOS resolves resources relative to the installed app bundle.
        const run_client_cmd = if (policy.launch == .app_bundle)
            b.addSystemCommand(&.{b.getInstallPath(
                .bin,
                b.fmt("{s}.app/Contents/MacOS/{s}", .{ client_name, client_name }),
            )})
        else
            b.addRunArtifact(client_exe);
        // Keep data and the loose resource pack together under -Duse-cwd.
        run_client_cmd.setCwd(.{ .cwd_relative = b.getInstallPath(.bin, "") });
        run_client_cmd.step.dependOn(build_game_step);
        run_client_step.dependOn(&run_client_cmd.step);

        if (b.args) |args| {
            run_client_cmd.addArgs(args);
        }
    }

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(lint_step);

    const test_filters = b.option([]const []const u8, "test-filter", "Skip tests that do not match any filter") orelse &.{};
    const capability_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/capabilities.zig"),
            .target = b.graph.host,
            .optimize = optimize,
        }),
        .filters = test_filters,
    });
    const run_capability_tests = b.addRunArtifact(capability_tests);
    test_step.dependOn(&run_capability_tests.step);
    b.step("test-capabilities", "Verify target capability policy").dependOn(&run_capability_tests.step);

    const unit_tests = b.addTest(.{
        .root_module = unit_tests_root: {
            const root = b.createModule(.{
                .root_source_file = b.path("src/unit.zig"),
                .target = target,
                .optimize = optimize,
            });
            root.addImport("aether", client_root.import_table.get("aether").?);
            root.addImport("protocol", protocol);
            root.addImport("capabilities", capabilities);
            root.addImport("core", core);
            break :unit_tests_root root;
        },
        .filters = test_filters,
    });
    // Same glibc .sframe workaround as the desktop client executable: the
    // system linker cannot consume GCC 16's R_X86_64_PC64 relocations.
    if (policy.use_llvm_linker) {
        unit_tests.use_llvm = true;
        unit_tests.use_lld = true;
    }
    const run_unit_tests = b.addRunArtifact(unit_tests);
    test_step.dependOn(&run_unit_tests.step);
    b.step("test-hosts", "Run client and server host tests").dependOn(&run_unit_tests.step);

    const core_tests = b.addTest(.{
        .root_module = core_tests_root: {
            const root = b.createModule(.{
                .root_source_file = b.path("src/core/unit.zig"),
                .target = target,
                .optimize = optimize,
            });
            root.addImport("protocol", protocol);
            root.addImport("capabilities", capabilities);
            root.addImport("worldgen", worldgen);
            break :core_tests_root root;
        },
        .filters = test_filters,
    });
    if (policy.use_llvm_linker) {
        core_tests.use_llvm = true;
        core_tests.use_lld = true;
    }
    const run_core_tests = b.addRunArtifact(core_tests);
    test_step.dependOn(&run_core_tests.step);
    b.step("test-core", "Run core tests").dependOn(&run_core_tests.step);

    const worldgen_tests = b.addTest(.{
        .name = "worldgen_tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/core/worldgen/root.zig"),
            .imports = &.{.{ .name = "capabilities", .module = capabilities }},
            .target = target,
            .optimize = .ReleaseFast,
        }),
        .filters = test_filters,
    });
    const run_worldgen_tests = b.addRunArtifact(worldgen_tests);
    test_step.dependOn(&run_worldgen_tests.step);
    b.step("test-worldgen", "Run world generation unit tests").dependOn(&run_worldgen_tests.step);

    const savetool_step = b.step("savetool", "Build the save conversion tool");
    const savetool_exe = b.addExecutable(.{
        .name = "savetool",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/savetool.zig"),
            .target = b.graph.host,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "core", .module = core },
            },
        }),
    });
    savetool_step.dependOn(&b.addInstallArtifact(savetool_exe, .{}).step);

    const worldgen_test_step = b.step("worldgen-test", "Verify worldgen output against 100 oracle-captured golden hashes");
    const worldgen_test_exe = b.addExecutable(.{
        .name = "worldgen_test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/worldgen_test.zig"),
            .target = b.graph.host,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "worldgen", .module = worldgen },
            },
        }),
    });
    worldgen_test_step.dependOn(&b.addRunArtifact(worldgen_test_exe).step);

    const web_target = Aether.config.web_target(b);
    const web_overrides: Aether.config.Config.Overrides = .{
        .gfx = .webgl,
        .use_cwd = true,
    };
    const web_exe = Aether.modules.add_game(ae_dep.builder, b, .{
        .name = "CrossCraft-Classic",
        .root_source_file = b.path("src/client/web_main.zig"),
        .target = web_target,
        .optimize = optimize,
        .overrides = web_overrides,
    });
    const web_root = Aether.modules.user_root_module(web_exe);
    web_root.addImport("core", core);
    web_root.addImport("capabilities", capabilities);
    web_root.addImport("protocol", protocol);

    const web_build_options = b.addOptions();
    web_build_options.addOption(bool, "embed_pack", false);
    web_root.addImport("build_options", web_build_options.createModule());

    const web_resource_files: []const Aether.packaging.Resource = if (pack_zip_path) |pack_zip|
        &.{.{ .path = pack_zip, .name = "pack.zip" }}
    else
        &.{};
    const web_install = Aether.packaging.add_web_bundle(ae_dep.builder, b, web_exe, .{
        .web_resource_files = web_resource_files,
        .web_resource_manifest = if (pack_zip_path != null) "pack.zip\n" else "",
        .web_app_module = b.path("web/crosscraft.js"),
    });

    const web_step = b.step("web", "Build the browser-playable WASM site in zig-out/web");
    web_step.dependOn(&web_install.step);

    const serve_web_cmd = Aether.packaging.add_serve_web_step(
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
