const std = @import("std");
const build_identity = @import("build_identity.zig");

fn readSourceFile(b: *std.Build, path: []const u8, limit: usize) []u8 {
    const full_path = b.root.joinString(b.allocator, path) catch @panic("out of memory resolving version input");
    defer b.allocator.free(full_path);
    return std.Io.Dir.cwd().readFileAlloc(b.graph.io, full_path, b.allocator, .limited(limit)) catch |err| {
        std.debug.panic("required versioning input {s} could not be read: {s}", .{ path, @errorName(err) });
    };
}

fn addProductIdentity(b: *std.Build, module: *std.Build.Module) void {
    const identity = build_identity.load(b, "../VERSION");
    const template = readSourceFile(b, "fixtures/distribution.template.json", 16 * 1024);
    const with_engine = std.mem.replaceOwned(u8, b.allocator, template, "@ENGINE_VERSION@", identity.product_string) catch @panic("out of memory generating distribution manifest");
    const manifest = std.mem.replaceOwned(u8, b.allocator, with_engine, "@PROJECT_ENGINE_VERSION@", identity.project_requirement) catch @panic("out of memory generating distribution manifest");
    if (std.mem.indexOf(u8, manifest, "@ENGINE_VERSION@") != null or std.mem.indexOf(u8, manifest, "@PROJECT_ENGINE_VERSION@") != null) @panic("unexpanded version placeholder in distribution manifest");

    const generated = b.addNamedWriteFiles("corex_distribution");
    _ = generated.add("distribution.json", manifest);
    const options = b.addOptions();
    options.addOption([]const u8, "engine_version", identity.product_string);
    options.addOption([]const u8, "project_engine_version", identity.project_requirement);
    options.addOption([]const u8, "distribution_manifest", manifest);
    module.addOptions("build_options", options);
}

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
    addProductIdentity(b, mod);
    mod.addCSourceFiles(.{ .files = &.{ "graphics_abi.c", "platform_ext/process_native.c" }, .flags = &.{ "-std=c23", "-Wall", "-Wextra", "-Werror" } });
    const tests = b.addTest(.{ .root_module = mod });
    b.step("check", "Compile shared tests without execution (cross targets)").dependOn(&tests.step);
    const run = b.addRunArtifact(tests);
    b.step("test", "Test application contracts and bootstrap helpers (no GPU)").dependOn(&run.step);
}
