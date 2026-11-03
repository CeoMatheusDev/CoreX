const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const core = b.dependency("core", .{ .target = target, .optimize = optimize });
    const mod = b.addModule("corex_scene", .{
        .root_source_file = b.path("root.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod.addImport("corex_core", core.module("corex_core"));
    const tests = b.addTest(.{ .root_module = mod });
    const check = b.step("check", "Compile the Scene library and tests without running them");
    check.dependOn(&tests.step);
    b.step("test", "Test entities, sparse sets, world, systems and scene lifecycle").dependOn(&b.addRunArtifact(tests).step);
}
