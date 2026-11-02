const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const mod = b.addModule("corex_app", .{
        .root_source_file = b.path("root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    mod.addIncludePath(b.path("."));
    mod.addCSourceFiles(.{ .files = &.{ "graphics_abi.c", "platform_ext/process_native.c" }, .flags = &.{ "-std=c23", "-Wall", "-Wextra", "-Werror" } });
    const tests = b.addTest(.{ .root_module = mod });
    b.step("check", "Compile shared tests without execution (cross targets)").dependOn(&tests.step);
    const run = b.addRunArtifact(tests);
    b.step("test", "Test application contracts and bootstrap helpers (no GPU)").dependOn(&run.step);
}
