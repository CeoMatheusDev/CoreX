const std = @import("std");
const build_identity = @import("shared/build_identity.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const identity = build_identity.load(b, "VERSION");
    const identity_options = b.addOptions();
    identity_options.addOption([]const u8, "engine_version", identity.product_string);
    identity_options.addOption([]const u8, "project_engine_version", identity.project_requirement);

    // `check` is deliberately compile-only for cross-target CI. Native
    // project validation gets a separate entry point and never runs a
    // cross-compiled executable.
    const validate = b.step("validate", "Run native tooling and application contract tests (not full CI)");
    if (!target.query.isNative()) {
        validate.dependOn(&b.addFail("validate runs native binaries only; omit -Dtarget and -Dcpu (use check to cross-compile)").step);
    } else {
        const optimize_flag = b.fmt("-Doptimize={s}", .{@tagName(optimize)});
        const commands = [_]struct { dir: []const u8, step: []const u8 }{
            .{ .dir = "tools/zig", .step = "validate" },
            .{ .dir = "core", .step = "test" },
            .{ .dir = "scene", .step = "test" },
            .{ .dir = "shared", .step = "test" },
            .{ .dir = "editor", .step = "test" },
            .{ .dir = "runtime", .step = "test" },
        };
        for (commands) |command| {
            const run = b.addRunFile(.zig_exe);
            run.addArgs(&.{ "build", command.step, optimize_flag, "-j2", "--summary", "all" });
            run.setCwd(b.path(command.dir));
            run.has_side_effects = true;
            validate.dependOn(&run.step);
        }

        const format = b.addRunFile(.zig_exe);
        format.addArgs(&.{
            "fmt",                                   "--check",
            "build.zig",                             "src/legacy_tests.zig",
            "src/zigway_input_tests.zig",            "src/platform/zigway.zig",
            "src/window/zigway.zig",                 "tests/test_zigway.zig",
            "src/jobs/job_system.zig",               "src/events/event.zig",
            "src/ecs/system.zig",                    "src/memory/allocator.zig",
            "src/scripting/lua_allocator.zig",       "src/main.zig",
            "src/graphics/renderer/render.zig",      "tests/events/test_basics.zig",
            "tests/integration/engine_pipeline.zig", "shared",
            "editor",                                "runtime",
            "tools/zig",                             "core",
            "scene",
        });
        format.setCwd(b.path("."));
        format.has_side_effects = true;
        validate.dependOn(&format.step);

        // Compile each private C header alone as C++20 without relying on an
        // external C++ driver or headers from a previous translation unit.
        const generated = b.addWriteFiles();
        const headers = [_]struct { name: []const u8, contents: []const u8 }{
            .{ .name = "graphics_abi_header.cpp", .contents = "#include \"graphics_abi.h\"\n" },
            .{ .name = "process_native_header.cpp", .contents = "#include \"platform_ext/process_native.h\"\n" },
        };
        for (headers) |header| {
            const module = b.createModule(.{ .target = b.graph.host, .optimize = optimize, .link_libc = true });
            module.addIncludePath(b.path("shared"));
            module.addCSourceFile(.{ .file = generated.add(header.name, header.contents), .flags = &.{ "-std=c++20", "-fno-rtti", "-fno-exceptions", "-Wall", "-Wextra", "-Werror" } });
            validate.dependOn(&b.addObject(.{ .name = header.name, .root_module = module }).step);
        }
    }

    const zigway_dep = b.dependency("zigway", .{
        .target = target,
        .optimize = optimize,
    });
    const zyntra_dep = b.dependency("zyntra_ui", .{
        .target = target,
        .optimize = optimize,
    });

    const product_version_module = b.createModule(.{
        .root_source_file = b.path("shared/product_version.zig"),
        .target = target,
        .optimize = optimize,
    });
    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    root_module.addImport("corex_product_version", product_version_module);
    root_module.addImport("zigway", zigway_dep.module("zigway"));
    root_module.addImport("zyntra_ui", zyntra_dep.module("zyntra_ui"));
    root_module.addOptions("build_options", identity_options);

    const exe = b.addExecutable(.{
        .name = "CoreXEngine",
        .root_module = root_module,
    });

    b.installArtifact(exe);

    const test_module = b.createModule(.{
        .root_source_file = b.path("src/legacy_tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_module.addImport("corex_product_version", product_version_module);
    test_module.addImport("zigway", zigway_dep.module("zigway"));
    test_module.addImport("zyntra_ui", zyntra_dep.module("zyntra_ui"));
    test_module.addOptions("build_options", identity_options);

    const unit_tests = b.addTest(.{
        .root_module = test_module,
    });
    const check = b.step("check", "Compile the legacy executable and tests without running them");
    check.dependOn(&exe.step);
    check.dependOn(&unit_tests.step);
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&run_unit_tests.step);

    // Core is a separate package consumed by the Runtime; the root build keeps
    // it compiled for cross targets and tested natively from one command.
    const core_module = b.createModule(.{
        .root_source_file = b.path("core/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const core_tests = b.addTest(.{ .root_module = core_module });
    check.dependOn(&core_tests.step);
    test_step.dependOn(&b.addRunArtifact(core_tests).step);

    const scene_module = b.createModule(.{
        .root_source_file = b.path("scene/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    scene_module.addImport("corex_core", core_module);
    const scene_tests = b.addTest(.{ .root_module = scene_module });
    check.dependOn(&scene_tests.step);
    test_step.dependOn(&b.addRunArtifact(scene_tests).step);

    const corex_platform_module = b.createModule(.{
        .root_source_file = b.path("src/platform/zigway.zig"),
        .target = target,
        .optimize = optimize,
    });
    corex_platform_module.addImport("zigway", zigway_dep.module("zigway"));
    const corex_window_module = b.createModule(.{
        .root_source_file = b.path("src/window/zigway.zig"),
        .target = target,
        .optimize = optimize,
    });
    corex_window_module.addImport("corex_platform", corex_platform_module);
    corex_window_module.addImport("zigway", zigway_dep.module("zigway"));
    const zigway_adapter_test_module = b.createModule(.{
        .root_source_file = b.path("tests/test_zigway.zig"),
        .target = target,
        .optimize = optimize,
    });
    zigway_adapter_test_module.addImport("corex_platform", corex_platform_module);
    zigway_adapter_test_module.addImport("corex_window", corex_window_module);
    zigway_adapter_test_module.addImport("zigway", zigway_dep.module("zigway"));
    const zigway_adapter_tests = b.addTest(.{ .root_module = zigway_adapter_test_module });
    const run_zigway_adapter_tests = b.addRunArtifact(zigway_adapter_tests);
    test_step.dependOn(&run_zigway_adapter_tests.step);
}
