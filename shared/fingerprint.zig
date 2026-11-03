//! Stable identity of normalized project, parameters and packaged table metadata.
const std = @import("std");
const project = @import("project.zig");
const presets = @import("presets.zig");
const distribution = @import("distribution.zig");

pub fn compute(p: project.Project, parameters: presets.Parameters, manifest: distribution.Manifest) ![64]u8 {
    var diagnostic: project.Diagnostic = .{};
    try project.validate(p, &diagnostic);
    try presets.validate(parameters);
    var buffer: [32 * 1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    std.json.Stringify.value(.{
        .fingerprint_version = @as(u32, 4),
        .application_profile = @import("scope.zig").profile_id,
        .renderer_profile = p.renderer.profile,
        .project = p,
        .parameters = parameters,
        .distribution = manifest,
    }, .{}, &writer) catch return error.ValidationFingerprintTooLarge;
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(writer.buffered(), &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

test "fingerprint includes complete normalized values and not process state" {
    const a = std.testing.allocator;
    var d: project.Diagnostic = .{};
    var p = try project.parse(a, @embedFile("fixtures/EmptyGame.proj"), &d);
    defer p.deinit();
    var bundle = try distribution.verify(a, distribution.expected_manifest, @embedFile("fixtures/presets.zon"));
    defer bundle.deinit();
    const params = try bundle.table.value.resolve(p.value.renderer.graphics_preset, p.value.renderer.overrides);
    const original = try compute(p.value, params, bundle.manifest.value);
    try std.testing.expectEqualStrings(&original, &(try compute(p.value, params, bundle.manifest.value)));
    p.value.simulation.seed = 0;
    try std.testing.expect(!std.mem.eql(u8, &original, &(try compute(p.value, params, bundle.manifest.value))));
}

test "a recalculated fingerprint cannot authorize an unapproved project version" {
    const a = std.testing.allocator;
    var diagnostic: project.Diagnostic = .{};
    const source = @embedFile("fixtures/EmptyGame.proj");
    const unauthorized_bytes = try std.mem.replaceOwned(u8, a, source, "0.1.0-alpha.1", "0.1.0");
    defer a.free(unauthorized_bytes);
    var unauthorized_project = try project.parse(a, unauthorized_bytes, &diagnostic);
    defer unauthorized_project.deinit();

    var bundle = try distribution.verify(a, distribution.expected_manifest, @embedFile("fixtures/presets.zon"));
    defer bundle.deinit();
    const parameters = try bundle.table.value.resolve(
        unauthorized_project.value.renderer.graphics_preset,
        unauthorized_project.value.renderer.overrides,
    );

    // Simulate a forged manifest declaration and a newly calculated digest
    // over it. The digest remains reproducible but is not an authorization.
    const test_only_declaration = [_][]const u8{"0.1.0"};
    var forged_manifest = bundle.manifest.value;
    forged_manifest.compatible_project_engine_versions = &test_only_declaration;
    const recalculated = try compute(unauthorized_project.value, parameters, forged_manifest);
    const recalculated_again = try compute(unauthorized_project.value, parameters, forged_manifest);
    try std.testing.expectEqualStrings(&recalculated, &recalculated_again);
    try std.testing.expectEqual(
        distribution.Compatibility.incompatible,
        distribution.classify(unauthorized_project.value.engine.version),
    );
}

test "fingerprint v4 separates renderer profile from application profile" {
    const a = std.testing.allocator;
    var diagnostic: project.Diagnostic = .{};
    var document = try project.parse(a, @embedFile("fixtures/EmptyGameV3.proj"), &diagnostic);
    defer document.deinit();
    var bundle = try distribution.verify(a, distribution.expected_manifest, @embedFile("fixtures/presets.zon"));
    defer bundle.deinit();
    const parameters = try bundle.table.value.resolve(document.value.renderer.graphics_preset, document.value.renderer.overrides);
    const lite = try compute(document.value, parameters, bundle.manifest.value);
    document.value.renderer.profile = .advanced;
    const advanced = try compute(document.value, parameters, bundle.manifest.value);
    try std.testing.expect(!std.mem.eql(u8, &lite, &advanced));
}
