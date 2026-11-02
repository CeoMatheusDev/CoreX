//! Sole installed table identity, pinned by bytes of the build's manifest.
//! No CWD/project override or network fallback. This authenticates neither the
//! installation nor core ABI; those remain separate checks before real Play.
const std = @import("std");
const presets = @import("presets.zig");
pub const Manifest = struct {
    engine_version: []const u8,
    renderer_contract_version: u32,
    table_revision: []const u8,
    presets_sha256: []const u8,
};
pub const expected_manifest = @embedFile("fixtures/distribution.json");

pub const Bundle = struct {
    manifest: std.json.Parsed(Manifest),
    table: presets.Document,

    pub fn deinit(self: *Bundle) void {
        self.table.deinit();
        self.manifest.deinit();
    }
};

/// Pure verification, also used by tests. Inputs are not retained.
pub fn verify(a: std.mem.Allocator, manifest_bytes: []const u8, table_bytes: []const u8) !Bundle {
    if (!std.mem.eql(u8, manifest_bytes, expected_manifest)) return error.DistributionIdentityMismatch;
    var manifest = try std.json.parseFromSlice(Manifest, a, manifest_bytes, .{ .allocate = .alloc_always });
    errdefer manifest.deinit();
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(table_bytes, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    if (!std.mem.eql(u8, &hex, manifest.value.presets_sha256)) return error.DistributionIdentityMismatch;
    var table = try presets.parse(a, table_bytes);
    errdefer table.deinit();
    if (table.value.renderer_contract_version != manifest.value.renderer_contract_version or !std.mem.eql(u8, table.value.table_revision, manifest.value.table_revision)) return error.DistributionIdentityMismatch;
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
    const manifest = try std.Io.Dir.cwd().readFileAlloc(io, manifest_path, a, .limited(4097));
    defer a.free(manifest);
    if (manifest.len > 4096) return error.DistributionIdentityMismatch;
    const table = try std.Io.Dir.cwd().readFileAlloc(io, table_path, a, .limited(64 * 1024 + 1));
    defer a.free(table);
    return verify(a, manifest, table);
}

test "installed manifest and table must match the sole build identity" {
    const a = std.testing.allocator;
    var bundle = try verify(a, expected_manifest, @embedFile("fixtures/presets.zon"));
    defer bundle.deinit();
    try std.testing.expectEqualStrings("0.1.0", bundle.manifest.value.engine_version);
    try std.testing.expectError(error.DistributionIdentityMismatch, verify(a, "{}", @embedFile("fixtures/presets.zon")));
    try std.testing.expectError(error.DistributionIdentityMismatch, verify(a, expected_manifest, "tampered"));
}

fn allocationProbe(a: std.mem.Allocator) !void {
    var bundle = try verify(a, expected_manifest, @embedFile("fixtures/presets.zon"));
    defer bundle.deinit();
}

test "distribution verification cleans all allocation failures" {
    try @import("testing_allocator.zig").checkAllFailures(allocationProbe, .{});
}
