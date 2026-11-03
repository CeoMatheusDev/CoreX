const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    if (target.result.os.tag != .windows and target.result.os.tag != .linux) {
        std.log.err("Unsupported application target: {s}; supported: windows, linux", .{@tagName(target.result.os.tag)});
        std.process.exit(1);
    }
    const optimize = b.standardOptimizeOption(.{});
    const shared = b.dependency("shared", .{ .target = target, .optimize = optimize });
    const core = b.dependency("core", .{ .target = target, .optimize = optimize });
    const scene = b.dependency("scene", .{ .target = target, .optimize = optimize });
    const mod = b.createModule(.{ .root_source_file = b.path("src/main.zig"), .target = target, .optimize = optimize });
    mod.addImport("corex_app", shared.module("corex_app"));
    mod.addImport("corex_core", core.module("corex_core"));
    mod.addImport("corex_scene", scene.module("corex_scene"));
    const exe = b.addExecutable(.{ .name = "CoreXRuntime", .root_module = mod });
    b.installArtifact(exe);
    const manifest = shared.namedWriteFiles("corex_distribution").getDirectory().path(b, "distribution.json");
    b.getInstallStep().dependOn(&b.addInstallFile(shared.path("fixtures/presets.zon"), "share/corex/presets.zon").step);
    b.getInstallStep().dependOn(&b.addInstallFile(manifest, "share/corex/distribution.json").step);
    const check = b.step("check", "Compile the bootstrap and tests without executing them");
    check.dependOn(&exe.step);
    const tests = b.addTest(.{ .root_module = mod });
    check.dependOn(&tests.step);
    b.step("test", "Test runtime models (integration tests run separately)").dependOn(&b.addRunArtifact(tests).step);
}
