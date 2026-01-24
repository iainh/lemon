const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const objc_dep = b.dependency("objc", .{
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "lemon",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "objc", .module = objc_dep.module("objc") },
            },
        }),
    });

    if (target.result.os.tag == .macos) {
        exe.linkFramework("Foundation");
        exe.linkFramework("Virtualization");
    }

    b.installArtifact(exe);
    b.installFile("assets/lemon-icon-1024.icon/Assets/lemon-icon-1024.png", "assets/lemon-icon-1024.icon/Assets/lemon-icon-1024.png");

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run lemon");
    run_step.dependOn(&run_cmd.step);

    const exe_unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "objc", .module = objc_dep.module("objc") },
            },
        }),
    });

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);

    const ziglint_dep = b.dependency("ziglint", .{
        .target = target,
        .optimize = optimize,
    });
    const ziglint_cmd = b.addRunArtifact(ziglint_dep.artifact("ziglint"));
    ziglint_cmd.addArg("src/");
    const lint_step = b.step("lint", "Run ziglint");
    lint_step.dependOn(&ziglint_cmd.step);
}
