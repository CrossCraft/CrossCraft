const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Build the server
    const server_dependency = b.dependency("server", .{
        .target = target,
        .optimize = optimize,
    });
    const server_step = server_dependency.artifact("server");

    // Install the server
    b.installArtifact(server_step);

    // Run step
    const run_server_cmd = b.addRunArtifact(server_step);
    run_server_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_server_cmd.addArgs(args);
    }

    // Run the server
    const run_step = b.step("server", "Run the server");
    run_step.dependOn(&run_server_cmd.step);
}
