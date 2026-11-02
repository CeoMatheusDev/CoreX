//! Shared installed-distribution and Editor/Runtime compatibility contract.
//! Manifest identity, product identity, and the presets-table digest are separate.
const std = @import("std");
const presets = @import("presets.zig");
const validation = @import("validation.zig");
const product_version = @import("product_version.zig");
const engine_identity = @import("engine_identity.zig");
const build_options = @import("build_options");

pub const Manifest = struct {
    format_version: u32,
    engine_version: []const u8,
    project_engine_version: []const u8,
    compatible_project_engine_versions: []const []const u8,
    renderer_contract_version: u32,
    table_revision: []const u8,
    presets_sha256: []const u8,
};

pub const Compatibility = enum { same_version, compatible, incompatible };
pub const expected_manifest = build_options.distribution_manifest;

pub const Bundle = struct {
    manifest: std.json.Parsed(Manifest),
    table: presets.Document,

    pub fn deinit(self: *Bundle) void {
        self.table.deinit();
        self.manifest.deinit();
    }
};

/// Version comparison is deliberately explicit; table integrity alone never
/// grants compatibility. The allow-list is part of the validated manifest.
pub fn classify(required_project_version: []const u8, manifest: Manifest) Compatibility {
    if (std.mem.eql(u8, required_project_version, manifest.project_engine_version)) return .same_version;
    for (manifest.compatible_project_engine_versions) |supported| {
        if (std.mem.eql(u8, required_project_version, supported)) return .compatible;
    }
    return .incompatible;
}

/// Compare untrusted installed bytes to the build-pinned manifest before parsing.
/// A changed manifest is corruption; a bad table/hash/schema is invalid distribution.
pub fn verify(a: std.mem.Allocator, manifest_bytes: []const u8, table_bytes: []const u8) !Bundle {
    if (!std.mem.eql(u8, manifest_bytes, expected_manifest)) return error.ManifestCorrupted;
    var manifest = std.json.parseFromSlice(Manifest, a, manifest_bytes, .{ .allocate = .alloc_always }) catch |err| {
        if (err == error.OutOfMemory) return err;
        return error.DistributionInvalid;
    };
    errdefer manifest.deinit();
    const value = manifest.value;
    _ = product_version.Version.parse(value.engine_version) catch return error.DistributionInvalid;
    if (value.format_version != 1 or
        !std.mem.eql(u8, value.engine_version, engine_identity.version_string) or
        !std.mem.eql(u8, value.project_engine_version, engine_identity.project_engine_version) or
        !validation.semver(value.project_engine_version) or
        value.compatible_project_engine_versions.len > 64)
    {
        return error.DistributionInvalid;
    }
    for (value.compatible_project_engine_versions, 0..) |supported, i| {
        if (!validation.semver(supported) or std.mem.eql(u8, supported, value.project_engine_version)) return error.DistributionInvalid;
        for (value.compatible_project_engine_versions[0..i]) |earlier| {
            if (std.mem.eql(u8, earlier, supported)) return error.DistributionInvalid;
        }
    }

    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(table_bytes, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    if (!std.mem.eql(u8, &hex, value.presets_sha256)) return error.DistributionInvalid;
    var table = presets.parse(a, table_bytes) catch |err| {
        if (err == error.OutOfMemory) return err;
        return error.DistributionInvalid;
    };
    errdefer table.deinit();
    if (table.value.renderer_contract_version != value.renderer_contract_version or
        !std.mem.eql(u8, table.value.table_revision, value.table_revision)) return error.DistributionInvalid;
    return .{ .manifest = manifest, .table = table };
}

/// Read from the installed executable's ../share/corex directory, not argv[0].
/// Missing/tampered resources are fatal even in --headless/--validate-only.
pub fn load(a: std.mem.Allocator, io: std.Io) !Bundle {
    const executable_dir = try std.process.executableDirPathAlloc(io, a);
    defer a.free(executable_dir);
    const data_dir = try std.fs.path.join(a, &.{ executable_dir, "..", "share", "corex" });
    defer a.free(data_dir);
    const manifest_path = try std.fs.path.join(a, &.{ data_dir, "distribution.json" });
    defer a.free(manifest_path);
    const table_path = try std.fs.path.join(a, &.{ data_dir, "presets.zon" });
    defer a.free(table_path);
    const manifest = try std.Io.Dir.cwd().readFileAlloc(io, manifest_path, a, .limited(16 * 1024 + 1));
    defer a.free(manifest);
    if (manifest.len > 16 * 1024) return error.ManifestCorrupted;
    const table = try std.Io.Dir.cwd().readFileAlloc(io, table_path, a, .limited(64 * 1024 + 1));
    defer a.free(table);
    return verify(a, manifest, table);
}

test "manifest pins product identity and explicitly classifies project requirements" {
    const a = std.testing.allocator;
    var bundle = try verify(a, expected_manifest, @embedFile("fixtures/presets.zon"));
    defer bundle.deinit();
    try std.testing.expectEqual(@as(u32, 1), bundle.manifest.value.format_version);
    try std.testing.expectEqualStrings("0.1.0a1", bundle.manifest.value.engine_version);
    try std.testing.expectEqualStrings("0.1.0-alpha.1", bundle.manifest.value.project_engine_version);
    try std.testing.expectEqual(Compatibility.same_version, classify("0.1.0-alpha.1", bundle.manifest.value));
    try std.testing.expectEqual(Compatibility.incompatible, classify("0.1.0", bundle.manifest.value));
    try std.testing.expectEqual(Compatibility.incompatible, classify("9.9.9", bundle.manifest.value));
    var explicitly_compatible_versions = [_][]const u8{"0.1.0"};
    var compatible_manifest = bundle.manifest.value;
    compatible_manifest.compatible_project_engine_versions = &explicitly_compatible_versions;
    try std.testing.expectEqual(Compatibility.compatible, classify("0.1.0", compatible_manifest));
}

test "manifest corruption and distribution invalidity are distinct" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.ManifestCorrupted, verify(a, "{}", @embedFile("fixtures/presets.zon")));
    try std.testing.expectError(error.DistributionInvalid, verify(a, expected_manifest, "tampered"));
}

fn allocationProbe(a: std.mem.Allocator) !void {
    var bundle = try verify(a, expected_manifest, @embedFile("fixtures/presets.zon"));
    defer bundle.deinit();
}

test "distribution verification cleans all allocation failures" {
    try @import("testing_allocator.zig").checkAllFailures(allocationProbe, .{});
}
