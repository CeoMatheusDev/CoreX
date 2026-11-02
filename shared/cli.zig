//! Shared strict CLI, borrowing argument slices for the duration of bootstrap.
const std = @import("std");
pub const Kind = enum { editor, runtime };
pub const Options = struct {
    project: ?[]const u8 = null,
    headless: bool = false,
    validate_only: bool = false,
    help: bool = false,
    check_runtime: ?[]const u8 = null,
};
pub const Error = error{ TooManyArguments, UnknownArgument, DuplicateArgument, MissingValue, MissingProject, InvalidPathArgument, InvalidCombination };

/// Validate a borrowed CLI path before use or asynchronous copying.
pub fn validatePath(path: []const u8) Error!void {
    if (path.len == 0 or path.len > 4096 or !std.unicode.utf8ValidateSlice(path)) return error.InvalidPathArgument;
    for (path) |c| if (c < 32 or c == 127) return error.InvalidPathArgument;
}

/// args excludes argv[0]. Editor accepts one positional .proj for file association.
/// No shell parsing, environment expansion or allocation.
pub fn parse(kind: Kind, args: []const []const u8) Error!Options {
    if (args.len > 32) return error.TooManyArguments;
    var o: Options = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--project") or std.mem.eql(u8, arg, "--check-runtime")) {
            const project = std.mem.eql(u8, arg, "--project");
            if ((!project and o.check_runtime != null) or (project and o.project != null)) return error.DuplicateArgument;
            i += 1;
            if (i == args.len or std.mem.startsWith(u8, args[i], "--")) return error.MissingValue;
            const path = args[i];
            try validatePath(path);
            if (project) o.project = path else o.check_runtime = path;
        } else if (kind == .editor and !std.mem.startsWith(u8, arg, "-") and std.ascii.endsWithIgnoreCase(arg, ".proj")) {
            if (o.project != null) return error.DuplicateArgument;
            try validatePath(arg);
            o.project = arg;
        } else if (std.mem.eql(u8, arg, "--headless")) {
            if (o.headless) return error.DuplicateArgument;
            o.headless = true;
        } else if (std.mem.eql(u8, arg, "--validate-only")) {
            if (o.validate_only) return error.DuplicateArgument;
            o.validate_only = true;
        } else if (std.mem.eql(u8, arg, "--help")) {
            if (o.help) return error.DuplicateArgument;
            o.help = true;
        } else return error.UnknownArgument;
    }
    if (o.help) {
        if (args.len != 1) return error.InvalidCombination;
        return o;
    }
    if (o.project == null) return error.MissingProject;
    if (o.check_runtime != null and (kind != .editor or !o.validate_only)) return error.InvalidCombination;
    return o;
}

test "CLI requires project and never treats headless as validate-only" {
    try std.testing.expectError(error.MissingProject, parse(.runtime, &.{"--headless"}));
    const o = try parse(.runtime, &.{ "--headless", "--project", "My Game/Game.proj" });
    try std.testing.expect(o.headless and !o.validate_only);
    try std.testing.expectEqualStrings("My Game/Game.proj", o.project.?);
}

test "CLI rejects unknown duplicate missing and conflicting arguments" {
    try std.testing.expectError(error.UnknownArgument, parse(.runtime, &.{"--wat"}));
    try std.testing.expectError(error.MissingValue, parse(.runtime, &.{"--project"}));
    try std.testing.expectError(error.MissingValue, parse(.runtime, &.{ "--project", "--headless" }));
    try std.testing.expectError(error.DuplicateArgument, parse(.runtime, &.{ "--headless", "--headless" }));
    try std.testing.expectError(error.DuplicateArgument, parse(.runtime, &.{ "--project", "a", "--project", "b" }));
    try std.testing.expectError(error.InvalidCombination, parse(.runtime, &.{ "--project", "a", "--validate-only", "--check-runtime", "/bin/player" }));
    try std.testing.expectError(error.InvalidCombination, parse(.editor, &.{ "--project", "a", "--check-runtime", "/bin/player" }));
    try std.testing.expectError(error.InvalidCombination, parse(.editor, &.{ "--help", "--project", "a" }));
    try std.testing.expect((try parse(.editor, &.{"--help"})).help);
}

test "editor accepts a single positional project for desktop file opening" {
    for ([_][]const u8{ "exemploproject/Example.proj", "My Game/ação.PROJ", "./--project.proj" }) |path| {
        const o = try parse(.editor, &.{ path, "--headless", "--validate-only" });
        try std.testing.expectEqualStrings(path, o.project.?);
        try std.testing.expect(o.headless and o.validate_only);
    }
    try std.testing.expectError(error.MissingProject, parse(.editor, &.{}));
    try std.testing.expectError(error.UnknownArgument, parse(.runtime, &.{"Game.proj"}));
    try std.testing.expectError(error.UnknownArgument, parse(.editor, &.{"Game.txt"}));
    try std.testing.expectError(error.UnknownArgument, parse(.editor, &.{"--Game.proj"}));
    try std.testing.expectError(error.DuplicateArgument, parse(.editor, &.{ "first.proj", "second.proj" }));
    try std.testing.expectError(error.DuplicateArgument, parse(.editor, &.{ "first.proj", "--project", "second.proj" }));
    try std.testing.expectError(error.DuplicateArgument, parse(.editor, &.{ "--project", "first.proj", "second.proj" }));
    try std.testing.expectError(error.InvalidCombination, parse(.editor, &.{ "--help", "first.proj" }));
    try std.testing.expectError(error.InvalidPathArgument, parse(.editor, &.{"bad\nname.proj"}));
    try std.testing.expectError(error.InvalidPathArgument, parse(.editor, &.{"bad\xff.proj"}));
    var long: [4101]u8 = @splat('x');
    @memcpy(long[4096..], ".proj");
    try std.testing.expectError(error.InvalidPathArgument, parse(.editor, &.{&long}));
}
