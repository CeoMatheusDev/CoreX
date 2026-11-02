const std = @import("std");

fn fixtureCliTest(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.Optimize, fixture_exe: *std.Build.Step.Compile, shared_module: *std.Build.Module, repository_root: []const u8) *std.Build.Step.Compile {
    const opts = b.addOptions();
    opts.addOptionPath("checker", fixture_exe.getEmittedBin());
    opts.addOption([]const u8, "repository_root", repository_root);
    const module = b.createModule(.{ .root_source_file = b.path("test_fixture_cli.zig"), .target = target, .optimize = optimize });
    module.addOptions("fixture_cli_options", opts);
    module.addImport("corex_app", shared_module);
    return b.addTest(.{ .root_module = module });
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const repository_root = b.option([]const u8, "repository-root", "Repository checked by native validation (relative to tools/zig)") orelse "../..";
    const shared = b.dependency("shared", .{ .target = target, .optimize = optimize });
    const checker = b.createModule(.{ .root_source_file = b.path("check_application_targets.zig"), .target = target, .optimize = optimize });
    checker.addImport("corex_app", shared.module("corex_app"));
    const exe = b.addExecutable(.{ .name = "corex-check-targets", .root_module = checker });
    b.installArtifact(exe);
    const checker_tests = b.addTest(.{ .root_module = checker });
    const fixture_module = b.createModule(.{ .root_source_file = b.path("check_contract_fixtures.zig"), .target = target, .optimize = optimize });
    const fixture_exe = b.addExecutable(.{ .name = "corex-check-fixtures", .root_module = fixture_module });
    b.installArtifact(fixture_exe);
    const fixture_tests = b.addTest(.{ .root_module = fixture_module });
    const fixture_cli_tests = fixtureCliTest(b, target, optimize, fixture_exe, shared.module("corex_app"), repository_root);
    const capture_module = b.createModule(.{ .root_source_file = b.path("ci_capture.zig"), .target = target, .optimize = optimize });
    const capture_exe = b.addExecutable(.{ .name = "corex-ci-capture", .root_module = capture_module });
    b.installArtifact(capture_exe);
    const capture_tests = b.addTest(.{ .root_module = capture_module });
    const extractor_module = b.createModule(.{ .root_source_file = b.path("extract_legacy_deps.zig"), .target = target, .optimize = optimize });
    const extractor_exe = b.addExecutable(.{ .name = "corex-extract-legacy", .root_module = extractor_module });
    b.installArtifact(extractor_exe);
    const extractor_tests = b.addTest(.{ .root_module = extractor_module });
    const install_extractor = b.step("install-extractor", "Install only the pinned legacy archive extractor");
    install_extractor.dependOn(&b.addInstallArtifact(extractor_exe, .{}).step);
    const run_tests = b.step("test", "Run tooling unit tests");
    run_tests.dependOn(&b.addRunArtifact(checker_tests).step);
    run_tests.dependOn(&b.addRunArtifact(fixture_tests).step);
    const run_fixture_cli_tests = b.addRunArtifact(fixture_cli_tests);
    run_fixture_cli_tests.setCwd(b.path("."));
    run_fixture_cli_tests.has_side_effects = true;
    run_tests.dependOn(&run_fixture_cli_tests.step);
    const fixture_cli_step = b.step("test-fixture-cli", "Run black-box tests against a compiled native fixture checker");
    if (target.query.isNative()) {
        fixture_cli_step.dependOn(&run_fixture_cli_tests.step);
    } else {
        fixture_cli_step.dependOn(&b.addFail("test-fixture-cli is native-only; omit -Dtarget and -Dcpu").step);
    }
    run_tests.dependOn(&b.addRunArtifact(capture_tests).step);
    run_tests.dependOn(&b.addRunArtifact(extractor_tests).step);
    // Runtime validation executes host binaries and rejects custom targets.
    // The existing `check` remains compile-only for cross-target builds.
    const host = b.graph.host;
    const host_shared = b.dependency("shared", .{ .target = host, .optimize = optimize });
    const host_checker = b.createModule(.{ .root_source_file = b.path("check_application_targets.zig"), .target = host, .optimize = optimize });
    host_checker.addImport("corex_app", host_shared.module("corex_app"));
    const host_fixtures = b.createModule(.{ .root_source_file = b.path("check_contract_fixtures.zig"), .target = host, .optimize = optimize });
    const host_extractor = b.createModule(.{ .root_source_file = b.path("extract_legacy_deps.zig"), .target = host, .optimize = optimize });
    const host_capture = b.createModule(.{ .root_source_file = b.path("ci_capture.zig"), .target = host, .optimize = optimize });
    const host_fixture_exe = b.addExecutable(.{ .name = "corex-check-fixtures-host", .root_module = host_fixtures });
    const fixture_runner = b.addRunArtifact(host_fixture_exe);
    fixture_runner.setCwd(b.path("."));
    fixture_runner.addArgs(&.{ "--root", repository_root });
    fixture_runner.has_side_effects = true; // reads runtime files; never reuse a stale success
    const fixture_validation = b.step("validate-fixtures", "Check runtime fixtures with a host executable");
    if (target.query.isNative()) {
        fixture_validation.dependOn(&fixture_runner.step);
    } else {
        fixture_validation.dependOn(&b.addFail("validate-fixtures is native-only; omit -Dtarget and -Dcpu").step);
    }
    const targets_runner = b.addRunArtifact(b.addExecutable(.{ .name = "corex-check-targets-host", .root_module = host_checker }));
    targets_runner.setCwd(b.path("."));
    targets_runner.addArgs(&.{ "--root", repository_root, "--zig" });
    targets_runner.addFileArg(.zig_exe);
    targets_runner.has_side_effects = true; // builds must run every time
    const target_validation = b.step("validate-targets", "Verify real unsupported targets with a host executable");
    if (target.query.isNative()) {
        target_validation.dependOn(&targets_runner.step);
    } else {
        target_validation.dependOn(&b.addFail("validate-targets is native-only; omit -Dtarget and -Dcpu").step);
    }
    const validate = b.step("validate", "Run native tooling tests, fixture checks and target policy checks");
    validate.dependOn(fixture_validation);
    validate.dependOn(target_validation);
    if (target.query.isNative()) {
        const cli_tests = fixtureCliTest(b, host, optimize, host_fixture_exe, host_shared.module("corex_app"), repository_root);
        const run_cli = b.addRunArtifact(cli_tests);
        run_cli.setCwd(b.path("."));
        run_cli.has_side_effects = true;
        validate.dependOn(&run_cli.step);
        for ([_]*std.Build.Module{ host_checker, host_fixtures, host_capture, host_extractor }) |module| {
            const run_host_tests = b.addRunArtifact(b.addTest(.{ .root_module = module }));
            run_host_tests.has_side_effects = true;
            validate.dependOn(&run_host_tests.step);
        }
    }
    const check = b.step("check", "Compile tools and tests without execution");
    check.dependOn(&exe.step);
    check.dependOn(&checker_tests.step);
    check.dependOn(&fixture_exe.step);
    check.dependOn(&fixture_tests.step);
    check.dependOn(&fixture_cli_tests.step);
    check.dependOn(&capture_exe.step);
    check.dependOn(&capture_tests.step);
    check.dependOn(&extractor_exe.step);
    check.dependOn(&extractor_tests.step);
}
