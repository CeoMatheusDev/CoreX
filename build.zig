const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

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
            "src/zigway_input_tests.zig",            "src/jobs/job_system.zig",
            "src/events/event.zig",                  "src/main.zig",
            "src/graphics/renderer/render.zig",      "tests/events/test_basics.zig",
            "tests/integration/engine_pipeline.zig", "shared",
            "editor",                                "runtime",
            "tools/zig",
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
        .root_source_file = b.path("src/legacy_tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_module.addImport("zigway", zigway_dep.module("zigway"));
    test_module.addImport("zyntra_ui", zyntra_dep.module("zyntra_ui"));
    const unit_tests = b.addTest(.{
        .root_module = test_module,
    });
    const check = b.step("check", "Compile the legacy executable and tests without running them");
    check.dependOn(&exe.step);
    check.dependOn(&unit_tests.step);
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&run_unit_tests.step);
}
