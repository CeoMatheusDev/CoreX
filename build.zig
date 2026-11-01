const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zigway_dep = b.dependency("zigway", .{
        .target = target,
        .optimize = optimize,
    });
    const zyntra_dep = b.dependency("zyntra_ui", .{
        .target = target,
        .optimize = optimize,
    });

    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    root_module.addImport("zigway", zigway_dep.module("zigway"));
    root_module.addImport("zyntra_ui", zyntra_dep.module("zyntra_ui"));

    const exe = b.addExecutable(.{
        .name = "CoreXEngine",
        .root_module = root_module,
    });

    b.installArtifact(exe);

    const test_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_module.addImport("zigway", zigway_dep.module("zigway"));
    test_module.addImport("zyntra_ui", zyntra_dep.module("zyntra_ui"));
    const unit_tests = b.addTest(.{
        .root_module = test_module,
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&run_unit_tests.step);
}
