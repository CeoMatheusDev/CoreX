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

fn captureCliTest(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.Optimize, capture_exe: *std.Build.Step.Compile, shared_module: *std.Build.Module) *std.Build.Step.Compile {
    const opts = b.addOptions();
    opts.addOptionPath("capture", capture_exe.getEmittedBin());
    const module = b.createModule(.{ .root_source_file = b.path("test_capture_cli.zig"), .target = target, .optimize = optimize });
    module.addOptions("capture_cli_options", opts);
    module.addImport("corex_app", shared_module);
    return b.addTest(.{ .root_module = module });
}

fn bootstrapCliTest(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.Optimize, probe_exe: *std.Build.Step.Compile, shared_module: *std.Build.Module, repository_root: []const u8) *std.Build.Step.Compile {
    const opts = b.addOptions();
    opts.addOptionPath("probe", probe_exe.getEmittedBin());
    opts.addOption([]const u8, "repository_root", repository_root);
    // The bootstraps are built in their own packages; these paths must point at
    // real, already-built executables. Nothing here rebuilds or downloads them.
    opts.addOption([]const u8, "editor", b.option([]const u8, "editor-bin", "Prebuilt CoreXEditor used by test-bootstrap-cli") orelse b.fmt("{s}/editor/zig-out/bin/CoreXEditor", .{repository_root}));
    opts.addOption([]const u8, "runtime", b.option([]const u8, "runtime-bin", "Prebuilt CoreXRuntime used by test-bootstrap-cli") orelse b.fmt("{s}/runtime/zig-out/bin/CoreXRuntime", .{repository_root}));
    const module = b.createModule(.{ .root_source_file = b.path("test_bootstrap_cli.zig"), .target = target, .optimize = optimize });
    module.addOptions("bootstrap_cli_options", opts);
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
    const capture_cli_tests = captureCliTest(b, target, optimize, capture_exe, shared.module("corex_app"));
    const extractor_module = b.createModule(.{ .root_source_file = b.path("extract_legacy_deps.zig"), .target = target, .optimize = optimize });
    const extractor_exe = b.addExecutable(.{ .name = "corex-extract-legacy", .root_module = extractor_module });
    b.installArtifact(extractor_exe);
    const extractor_tests = b.addTest(.{ .root_module = extractor_module });
    const versioning_module = b.createModule(.{ .root_source_file = b.path("versioning.zig"), .target = target, .optimize = optimize });
    versioning_module.addImport("corex_app", shared.module("corex_app"));
    const versioning_exe = b.addExecutable(.{ .name = "corex-version", .root_module = versioning_module });
    b.installArtifact(versioning_exe);
    const versioning_tests = b.addTest(.{ .root_module = versioning_module });
    const versioning_cli_options = b.addOptions();
    versioning_cli_options.addOptionPath("version_tool", versioning_exe.getEmittedBin());
    versioning_cli_options.addOption([]const u8, "repository_root", repository_root);
    const versioning_cli_module = b.createModule(.{ .root_source_file = b.path("test_versioning_cli.zig"), .target = target, .optimize = optimize });
    versioning_cli_module.addOptions("versioning_cli_options", versioning_cli_options);
    versioning_cli_module.addImport("corex_app", shared.module("corex_app"));
    const versioning_cli_tests = b.addTest(.{ .root_module = versioning_cli_module });
    const probe_module = b.createModule(.{ .root_source_file = b.path("bootstrap_probe.zig"), .target = target, .optimize = optimize });
    const probe_exe = b.addExecutable(.{ .name = "corex-bootstrap-probe", .root_module = probe_module });
    b.installArtifact(probe_exe);
    const bootstrap_cli_tests = bootstrapCliTest(b, target, optimize, probe_exe, shared.module("corex_app"), repository_root);
    const install_extractor = b.step("install-extractor", "Install only the pinned legacy archive extractor");
    install_extractor.dependOn(&b.addInstallArtifact(extractor_exe, .{}).step);
    const run_tests = b.step("test", "Run tooling unit and black-box tests");
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
    const run_capture_cli = b.addRunArtifact(capture_cli_tests);
    run_capture_cli.has_side_effects = true;
    run_tests.dependOn(&run_capture_cli.step);
    const capture_cli_step = b.step("test-capture-cli", "Run black-box tests of the native CI capture executable");
    if (!target.query.isNative()) {
        capture_cli_step.dependOn(&b.addFail("test-capture-cli is native-only; omit -Dtarget and -Dcpu").step);
    } else if (target.result.os.tag != .linux) {
        capture_cli_step.dependOn(&b.addFail("test-capture-cli requires a native Linux host").step);
    } else {
        capture_cli_step.dependOn(&run_capture_cli.step);
    }
    run_tests.dependOn(&b.addRunArtifact(extractor_tests).step);
    const run_bootstrap_cli = b.addRunArtifact(bootstrap_cli_tests);
    run_bootstrap_cli.setCwd(b.path("."));
    run_bootstrap_cli.has_side_effects = true;
    const bootstrap_cli_step = b.step("test-bootstrap-cli", "Run native black-box integration tests of the Editor and Runtime");
    if (!target.query.isNative()) {
        bootstrap_cli_step.dependOn(&b.addFail("test-bootstrap-cli is native-only; omit -Dtarget and -Dcpu").step);
    } else if (target.result.os.tag == .windows) {
        bootstrap_cli_step.dependOn(&b.addFail("test-bootstrap-cli requires a native POSIX host").step);
    } else {
        bootstrap_cli_step.dependOn(&run_bootstrap_cli.step);
    }
    run_tests.dependOn(&b.addRunArtifact(versioning_tests).step);
    const run_versioning_cli_tests = b.addRunArtifact(versioning_cli_tests);
    run_versioning_cli_tests.setCwd(b.path("."));
    run_versioning_cli_tests.has_side_effects = true;
    run_tests.dependOn(&run_versioning_cli_tests.step);
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
        const host_capture_exe = b.addExecutable(.{ .name = "corex-ci-capture-host", .root_module = host_capture });
        const host_capture_cli = captureCliTest(b, host, optimize, host_capture_exe, host_shared.module("corex_app"));
        const run_host_capture_cli = b.addRunArtifact(host_capture_cli);
        run_host_capture_cli.has_side_effects = true;
        validate.dependOn(&run_host_capture_cli.step);
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
    check.dependOn(&capture_cli_tests.step);
    check.dependOn(&extractor_exe.step);
    check.dependOn(&extractor_tests.step);
    check.dependOn(&versioning_exe.step);
    check.dependOn(&versioning_tests.step);
    check.dependOn(&versioning_cli_tests.step);
    check.dependOn(&bootstrap_cli_tests.step);
    check.dependOn(&probe_exe.step);
}
