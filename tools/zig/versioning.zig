//! Native CoreX version/release CLI. The only writable path is VERSION in CWD.
const std = @import("std");
const app = @import("corex_app");
const product_version = app.product_version;
const Version = product_version.Version;
const Io = std.Io;

pub fn main(init: std.process.Init) void {
    run(init) catch |err| {
        std.debug.print("corex-version: {s}\n", .{@errorName(err)});
        std.process.exit(2);
    };
}

fn run(init: std.process.Init) !void {
    var args = try std.process.Args.iterateAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    _ = args.next();
    const command = args.next() orelse return usage(init.io);

    if (std.mem.eql(u8, command, "--help") or std.mem.eql(u8, command, "help")) {
        if (args.next() != null) return error.InvalidArguments;
        return usage(init.io);
    }
    if (std.mem.eql(u8, command, "validate") or std.mem.eql(u8, command, "version")) {
        if (args.next() != null) return error.InvalidArguments;
        const text = try readVersion(init.gpa, init.io);
        defer init.gpa.free(text);
        try writeStdout(init.io, text);
        try writeStdout(init.io, "\n");
        return;
    }
    if (std.mem.eql(u8, command, "compare")) {
        const left_text = args.next() orelse return error.InvalidArguments;
        const right_text = args.next() orelse return error.InvalidArguments;
        if (args.next() != null) return error.InvalidArguments;
        const left = try Version.parse(left_text);
        const right = try Version.parse(right_text);
        const result: []const u8 = switch (left.compare(right)) {
            .lt => "less",
            .eq => "equal",
            .gt => "greater",
        };
        try writeStdout(init.io, result);
        try writeStdout(init.io, "\n");
        return;
    }
    if (std.mem.eql(u8, command, "release")) {
        const action = args.next() orelse return error.InvalidArguments;
        if (!std.mem.eql(u8, action, "check") or args.next() != null) return error.InvalidArguments;
        try checkRelease(init.gpa, init.io);
        try writeStdout(init.io, "Release checks passed; no Git tag or release was created.\n");
        return;
    }
    if (std.mem.eql(u8, command, "bump")) {
        const action_text = args.next() orelse return error.InvalidArguments;
        const action = parseBump(action_text) orelse return error.InvalidArguments;
        const dry_run_arg = args.next();
        const dry_run = if (dry_run_arg) |arg| blk: {
            if (!std.mem.eql(u8, arg, "--dry-run") or args.next() != null) return error.InvalidArguments;
            break :blk true;
        } else false;

        const current_text = try readVersion(init.gpa, init.io);
        defer init.gpa.free(current_text);
        const current = try Version.parse(current_text);
        const next = try current.bump(action);
        var next_buffer: [64]u8 = undefined;
        const next_text = try next.format(&next_buffer);
        if (!dry_run) try replaceVersion(init.io, next_text);
        try Io.File.stdout().writeStreamingAll(init.io, current_text);
        try writeStdout(init.io, " -> ");
        try writeStdout(init.io, next_text);
        try writeStdout(init.io, if (dry_run) " (dry-run)\n" else "\n");
        return;
    }
    return error.InvalidArguments;
}

fn checkRelease(a: std.mem.Allocator, io: Io) !void {
    const current = try readVersion(a, io);
    defer a.free(current);
    if (!std.mem.eql(u8, current, app.engine_identity.version_string)) return error.BuildIdentityStale;
    const table = try Io.Dir.cwd().readFileAlloc(io, "shared/fixtures/presets.zon", a, .limited(64 * 1024 + 1));
    defer a.free(table);
    var bundle = try app.distribution.verify(a, app.distribution.expected_manifest, table);
    defer bundle.deinit();
}

fn parseBump(text: []const u8) ?Version.Bump {
    if (std.mem.eql(u8, text, "alpha")) return .alpha;
    if (std.mem.eql(u8, text, "beta")) return .beta;
    if (std.mem.eql(u8, text, "final")) return .final;
    if (std.mem.eql(u8, text, "patch-release")) return .patch_release;
    if (std.mem.eql(u8, text, "major")) return .major;
    if (std.mem.eql(u8, text, "minor")) return .minor;
    if (std.mem.eql(u8, text, "patch")) return .patch;
    return null;
}

fn readVersion(a: std.mem.Allocator, io: Io) ![]u8 {
    const bytes = try Io.Dir.cwd().readFileAlloc(io, "VERSION", a, .limited(128));
    errdefer a.free(bytes);
    if (bytes.len < 2 or bytes[bytes.len - 1] != '\n') return error.InvalidVersionFile;
    const text = bytes[0 .. bytes.len - 1];
    if (std.mem.indexOfAny(u8, text, "\r\n") != null) return error.InvalidVersionFile;
    _ = try Version.parse(text);
    const copy = try a.dupe(u8, text);
    a.free(bytes);
    return copy;
}

fn replaceVersion(io: Io, text: []const u8) !void {
    var atomic = try Io.Dir.cwd().createFileAtomic(io, "VERSION", .{ .replace = true });
    defer atomic.deinit(io);
    try atomic.file.writeStreamingAll(io, text);
    try atomic.file.writeStreamingAll(io, "\n");
    try atomic.replace(io);
}

fn writeStdout(io: Io, bytes: []const u8) !void {
    try Io.File.stdout().writeStreamingAll(io, bytes);
}

fn usage(io: Io) !void {
    try writeStdout(io,
        \\Usage: corex-version <version|validate|compare|bump> ...
        \\  version | validate                 Validate and print ./VERSION
        \\  compare VERSION VERSION           Compare two product versions
        \\  bump ACTION [--dry-run]           Transition ./VERSION; default writes only VERSION
        \\  release check                    Validate current VERSION, generated manifest and presets
        \\Actions: alpha, beta, final, patch-release, major, minor, patch
        \\No command creates Git tags, commits, or releases.
        \\
    );
}

test "bump action parser is closed and exact" {
    try std.testing.expectEqual(Version.Bump.alpha, parseBump("alpha").?);
    try std.testing.expectEqual(Version.Bump.patch_release, parseBump("patch-release").?);
    try std.testing.expect(parseBump("Alpha") == null);
    try std.testing.expect(parseBump("release") == null);
}
