//! Product policy, not a claim that any GPU backend is implemented.
const std = @import("std");
const project = @import("project.zig");
pub const profile_id = "desktop-3d-canvas-v1";
pub const Platform = enum { windows, linux };
pub const AuthoringDomain = enum { scene_3d, ui_canvas };
pub const Decision = enum { allowed, backend_out_of_scope, backend_not_on_platform };

pub fn host() ?Platform {
    return switch (@import("builtin").os.tag) {
        .windows => .windows,
        .linux => .linux,
        else => null,
    };
}

pub fn decide(platform: Platform, backend: project.Backend) Decision {
    return switch (backend) {
        .vulkan, .opengl => .allowed,
        .d3d11, .d3d12 => if (platform == .windows) .allowed else .backend_not_on_platform,
        .metal, .webgpu => .backend_out_of_scope,
    };
}

pub fn parseDomain(text: []const u8) error{UnsupportedAuthoringDomain}!AuthoringDomain {
    return std.meta.stringToEnum(AuthoringDomain, text) orelse error.UnsupportedAuthoringDomain;
}

test "product matrix enumerates all platforms and backends without a GPU" {
    inline for (std.meta.tags(Platform)) |platform| {
        inline for (std.meta.tags(project.Backend)) |backend| {
            const expected: Decision = switch (backend) {
                .vulkan, .opengl => .allowed,
                .d3d11, .d3d12 => if (platform == .windows) .allowed else .backend_not_on_platform,
                .metal, .webgpu => .backend_out_of_scope,
            };
            try std.testing.expectEqual(expected, decide(platform, backend));
        }
    }
}

test "only 3D and UI Canvas are authoring domains" {
    try std.testing.expectEqual(AuthoringDomain.scene_3d, try parseDomain("scene_3d"));
    try std.testing.expectEqual(AuthoringDomain.ui_canvas, try parseDomain("ui_canvas"));
    for ([_][]const u8{ "scene_2d", "sprite", "tilemap", "", "canvas" }) |text|
        try std.testing.expectError(error.UnsupportedAuthoringDomain, parseDomain(text));
}
