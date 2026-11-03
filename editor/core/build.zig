const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const core = b.dependency("core", .{ .target = target, .optimize = optimize });
    const scene = b.dependency("scene", .{ .target = target, .optimize = optimize });
    const mod = b.createModule(.{
        .root_source_file = b.path("root.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod.addImport("corex_core", core.module("corex_core"));
    mod.addImport("corex_scene", scene.module("corex_scene"));
    const tests = b.addTest(.{ .root_module = mod });
    const check = b.step("check", "Compile the Editor Core library and tests without running them");
    check.dependOn(&tests.step);
    b.step("test", "Test Editor lifecycle, registry and ECS contract").dependOn(&b.addRunArtifact(tests).step);
}
