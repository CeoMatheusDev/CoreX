//! Build-configuration helper shared by the root legacy build and app package.
//! It reads the root VERSION file; no package SemVer or toolchain data is used.
const std = @import("std");
const product_version = @import("product_version.zig");

pub const Identity = struct {
    product: product_version.Version,
    product_string: []const u8,
    project_requirement: []const u8,
};

pub fn load(b: *std.Build, path: []const u8) Identity {
    const full_path = b.root.joinString(b.allocator, path) catch @panic("out of memory resolving VERSION path");
    defer b.allocator.free(full_path);
    const bytes = std.Io.Dir.cwd().readFileAlloc(b.graph.io, full_path, b.allocator, .limited(128)) catch |err| {
        std.debug.panic("required product VERSION at {s} could not be read: {s}", .{ path, @errorName(err) });
    };
    if (bytes.len < 2 or bytes[bytes.len - 1] != '\n') @panic("VERSION must contain one canonical version followed by LF");
    const product_string = bytes[0 .. bytes.len - 1];
    if (std.mem.indexOfAny(u8, product_string, "\r\n") != null) @panic("VERSION must contain exactly one line with LF endings");
    const product = product_version.Version.parse(product_string) catch |err| std.debug.panic("invalid root VERSION: {s}", .{@errorName(err)});
    var requirement_buffer: [64]u8 = undefined;
    const requirement_slice = product.projectRequirement(&requirement_buffer) catch @panic("project version projection buffer too small");
    const project_requirement = b.allocator.dupe(u8, requirement_slice) catch @panic("out of memory projecting VERSION");
    return .{ .product = product, .product_string = product_string, .project_requirement = project_requirement };
}
