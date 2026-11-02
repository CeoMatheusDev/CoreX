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
        .fingerprint_version = @as(u32, 3),
        .application_profile = @import("scope.zig").profile_id,
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
