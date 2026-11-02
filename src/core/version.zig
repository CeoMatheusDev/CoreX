const std = @import("std");
const build_options = @import("build_options");
const product_version = @import("corex_product_version");

const compiled_identity = product_version.Version.parse(build_options.engine_version) catch @compileError("invalid Engine identity injected by the build");

pub const VERSION_MAJOR = compiled_identity.major;
pub const VERSION_MINOR = compiled_identity.minor;
pub const VERSION_PATCH = compiled_identity.patch;
pub const VERSION_CHANNEL = compiled_identity.channel;
pub const VERSION_REVISION = compiled_identity.revision;
pub const VERSION_STRING = build_options.engine_version;

/// Backwards-compatible core-facing value, now carrying the complete product
/// identity rather than reconstructing a SemVer string from numeric fields.
pub const Version = struct {
    major: u32 = VERSION_MAJOR,
    minor: u32 = VERSION_MINOR,
    patch: u32 = VERSION_PATCH,
    channel: product_version.Channel = VERSION_CHANNEL,
    revision: u32 = VERSION_REVISION,

    pub fn toString(self: Version, buffer: []u8) []const u8 {
        return (product_version.Version{
            .major = self.major,
            .minor = self.minor,
            .patch = self.patch,
            .channel = self.channel,
            .revision = self.revision,
        }).format(buffer) catch "";
    }
};

test "core exposes the complete version injected from VERSION" {
    const version = Version{};
    var buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings(VERSION_STRING, version.toString(&buffer));
    try std.testing.expectEqual(@as(u32, 0), VERSION_MAJOR);
    try std.testing.expectEqual(@as(u32, 1), VERSION_MINOR);
    try std.testing.expectEqual(@as(u32, 0), VERSION_PATCH);
    try std.testing.expectEqual(product_version.Channel.alpha, VERSION_CHANNEL);
    try std.testing.expectEqual(@as(u32, 1), VERSION_REVISION);
}
