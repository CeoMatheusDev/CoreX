const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    if (target.result.os.tag != .windows and target.result.os.tag != .linux) {
        std.log.err("Unsupported application target: {s}; supported: windows, linux", .{@tagName(target.result.os.tag)});
        std.process.exit(1);
    }
    const optimize = b.standardOptimizeOption(.{});
    const shared = b.dependency("shared", .{ .target = target, .optimize = optimize });
    const repository_root = b.option([]const u8, "repository-root", "Repository containing exemploproject (relative to editor)") orelse "..";
    const preflight_options = b.addOptions();
    preflight_options.addOption([]const u8, "repository_root", repository_root);
    const mod = b.createModule(.{ .root_source_file = b.path("src/main.zig"), .target = target, .optimize = optimize });
    mod.addImport("corex_app", shared.module("corex_app"));
    mod.addOptions("preflight_options", preflight_options);
    const exe = b.addExecutable(.{ .name = "CoreXEditor", .root_module = mod });
    b.installArtifact(exe);
    b.getInstallStep().dependOn(&b.addInstallFile(shared.path("fixtures/presets.zon"), "share/corex/presets.zon").step);
    b.getInstallStep().dependOn(&b.addInstallFile(shared.path("fixtures/distribution.json"), "share/corex/distribution.json").step);
    const opts = b.addOptions();
    opts.addOptionPath("editor", exe.getEmittedBin());
    opts.addOptionPath("presets", shared.path("fixtures/presets.zon"));
    opts.addOptionPath("manifest", shared.path("fixtures/distribution.json"));
    opts.addOption([]const u8, "repository_root", repository_root);
    const launch_mod = b.createModule(.{ .root_source_file = b.path("src/test_project_open.zig"), .target = target, .optimize = optimize });
    launch_mod.addImport("corex_app", shared.module("corex_app"));
    launch_mod.addOptions("project_open_options", opts);
    const launch_tests = b.addTest(.{ .root_module = launch_mod });
    const check = b.step("check", "Compile bootstrap and project-open tests without execution");
    check.dependOn(&exe.step);
    check.dependOn(&launch_tests.step);
    const tests = b.addTest(.{ .root_module = mod });
    check.dependOn(&tests.step);
    const test_step = b.step("test", "Test Editor models and real project-open CLI");
    const run_tests = b.addRunArtifact(tests);
    run_tests.setCwd(b.path("."));
    run_tests.has_side_effects = true; // preflight tests read the example at runtime
    test_step.dependOn(&run_tests.step);
    const run_launch = b.addRunArtifact(launch_tests);
    run_launch.setCwd(b.path("."));
    run_launch.has_side_effects = true; // example read at runtime, no stale success
    test_step.dependOn(&run_launch.step);
}
