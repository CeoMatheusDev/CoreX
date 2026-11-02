const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const shared = b.dependency("shared", .{ .target = target, .optimize = optimize });
    const checker = b.createModule(.{ .root_source_file = b.path("check_application_targets.zig"), .target = target, .optimize = optimize });
    checker.addImport("corex_app", shared.module("corex_app"));
    const exe = b.addExecutable(.{ .name = "corex-check-targets", .root_module = checker });
    b.installArtifact(exe);
    const checker_tests = b.addTest(.{ .root_module = checker });
    const fixture_module = b.createModule(.{ .root_source_file = b.path("check_contract_fixtures.zig"), .target = target, .optimize = optimize });
    const fixture_tests = b.addTest(.{ .root_module = fixture_module });
    const run_tests = b.step("test", "Run tooling unit tests");
    run_tests.dependOn(&b.addRunArtifact(checker_tests).step);
    run_tests.dependOn(&b.addRunArtifact(fixture_tests).step);
    const check = b.step("check", "Compile tools and tests without execution");
    check.dependOn(&exe.step);
    check.dependOn(&checker_tests.step);
    check.dependOn(&fixture_tests.step);
}
