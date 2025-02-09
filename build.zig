const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zbc_dep = b.dependency("zbc", .{});

    const run_zbc = b.addRunArtifact(zbc_dep.artifact("zbc"));
    run_zbc.addFileArg(b.path("protocol.zb"));

    const output_protocol = run_zbc.addOutputFileArg("protocol.zig");

    const protocol_module = b.addModule("protocol", .{
        .root_source_file = output_protocol,
    });

    const exe = b.addExecutable(.{
        .name = "CrossCraft",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("protocol", protocol_module);
    exe.linkLibC();
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
