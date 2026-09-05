const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const cli_kit = b.dependency("zig_cli_kit", .{
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "hello",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addImport("zig-cli-kit", cli_kit.module("zig-cli-kit"));
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    // Forward `zig build run -- <args>` to the executable. Since the
    // 2026-05-26 build-system rework, build scripts can no longer observe
    // `b.args`; this is the replacement.
    run_cmd.addPassthruArgs();

    const run_step = b.step("run", "Run the hello example");
    run_step.dependOn(&run_cmd.step);
}
