//! Trusted project-version compatibility policy compiled into every CoreX
//! application binary. The installed distribution manifest only declares this
//! policy; it is not an authorization source. Production starts fail-closed.

/// Additional SemVer project requirements approved for the current Engine.
/// Keep empty until a deliberate compatibility decision updates this source.
pub const compatible_project_engine_versions = [_][]const u8{};

/// The manifest declaration must exactly mirror the separately compiled policy.
pub fn declarationMatches(declared: []const []const u8) bool {
    return declarationsMatchForPolicy(declared, &compatible_project_engine_versions);
}

fn declarationsMatchForPolicy(declared: []const []const u8, trusted: []const []const u8) bool {
    if (declared.len != trusted.len) return false;
    for (declared, trusted) |actual, approved| {
        if (!std.mem.eql(u8, actual, approved)) return false;
    }
    return true;
}

const std = @import("std");

test "production compatibility policy is fail-closed and declarations cannot expand it" {
    try std.testing.expectEqual(@as(usize, 0), compatible_project_engine_versions.len);
    try std.testing.expect(declarationMatches(&.{}));
    try std.testing.expect(!declarationMatches(&.{"0.1.0"}));
    try std.testing.expect(!declarationMatches(&.{"9.9.9"}));

    // Test-only authority is passed explicitly and never mutates production.
    const isolated_test_policy = [_][]const u8{"0.1.0"};
    try std.testing.expect(declarationsMatchForPolicy(&isolated_test_policy, &isolated_test_policy));
    try std.testing.expect(!declarationsMatchForPolicy(&isolated_test_policy, &.{}));
    try std.testing.expectEqual(@as(usize, 0), compatible_project_engine_versions.len);
}
