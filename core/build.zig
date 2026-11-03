const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const mod = b.addModule("corex_core", .{
        .root_source_file = b.path("root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const tests = b.addTest(.{ .root_module = mod });
    const check = b.step("check", "Compile the Core library and tests without running them");
    check.dependOn(&tests.step);
    b.step("test", "Test Core lifecycle and subsystem ownership (no GPU, no window)").dependOn(&b.addRunArtifact(tests).step);
}
