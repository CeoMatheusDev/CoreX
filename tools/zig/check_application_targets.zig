//! Verify the real builds reject unsupported targets, without a shell.
//! This test never executes a cross-compiled executable.
const std = @import("std");
const process = @import("corex_app").child_process;
const Io = std.Io;
const Allocator = std.mem.Allocator;
const marker = "Unsupported application target:";
const timeout_ms = 120_000;
const packages = [_][]const u8{ "editor", "runtime" };
const targets = [_][]const u8{ "aarch64-macos", "x86_64-freebsd", "wasm32-wasi" };

fn expectedRejection(term: std.process.Child.Term, stderr: []const u8) bool {
    const exit_code = switch (term) {
        .exited => |code| code,
        else => return false,
    };
    return exit_code != 0 and std.mem.indexOf(u8, stderr, marker) != null;
}

fn versionMatches(term: std.process.Child.Term, stdout: []const u8) bool {
    if (!term.success()) return false;
    return std.mem.eql(u8, std.mem.trim(u8, stdout, " \t\r\n"), "0.17.0");
}

fn check(a: Allocator, io: Io, zig: []const u8, root: Io.Dir) !void {
    if (!std.fs.path.isAbsolute(zig)) return error.AbsoluteZigPathRequired;
    const version = try process.runCommand(a, io, zig, &.{ zig, "version" }, .{ .dir = root }, 10_000);
    defer process.release(a, version);
    if (!versionMatches(version.term, version.stdout)) {
        std.debug.print("Expected Zig 0.17.0; got: {s}\nstderr: {s}\n", .{ version.stdout, version.stderr });
        return error.UnsupportedZigVersion;
    }
    for (packages) |package| {
        var cwd = try root.openDir(io, package, .{});
        defer cwd.close(io);
        for (targets) |target| {
            const target_option = try std.fmt.allocPrint(a, "-Dtarget={s}", .{target});
            defer a.free(target_option);
            const result = process.runCommand(a, io, zig, &.{ zig, "build", "check", target_option, "-j2" }, .{ .dir = cwd }, timeout_ms) catch |err| {
                std.debug.print("Target check failed for {s}/{s}: {s}\n", .{ package, target, @errorName(err) });
                return err;
            };
            defer process.release(a, result);
            if (!expectedRejection(result.term, result.stderr)) {
                std.debug.print("Unexpected result for {s}/{s}: {f}\nstderr:\n{s}\nstdout:\n{s}\n", .{ package, target, result.term, result.stderr, result.stdout });
                return error.WrongTargetRejection;
            }
            var buf: [160]u8 = undefined;
            const line = try std.fmt.bufPrint(&buf, "OK: {s} rejects {s} explicitly\n", .{ package, target });
            try Io.File.stdout().writeStreamingAll(io, line);
        }
    }
}

pub fn main(init: std.process.Init) void {
    run(init) catch |err| {
        std.debug.print("Target check failed: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
}

fn run(init: std.process.Init) !void {
    var args = try std.process.Args.iterateAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    _ = args.next();
    var root_path: ?[]const u8 = null;
    var zig_path: ?[]const u8 = null;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help")) {
            if (root_path != null or zig_path != null or args.next() != null) return error.InvalidArguments;
            try Io.File.stdout().writeStreamingAll(init.io, "Usage: corex-check-targets --zig ABSOLUTE_ZIG_PATH --root REPOSITORY_ROOT\n");
            return;
        }
        if (std.mem.eql(u8, arg, "--root")) {
            if (root_path != null) return error.InvalidArguments;
            root_path = args.next() orelse return error.InvalidArguments;
        } else if (std.mem.eql(u8, arg, "--zig")) {
            if (zig_path != null) return error.InvalidArguments;
            zig_path = args.next() orelse return error.InvalidArguments;
        } else return error.InvalidArguments;
    }
    const zig = zig_path orelse return error.InvalidArguments;
    const root = root_path orelse return error.InvalidArguments;
    if (root.len == 0) return error.InvalidArguments;
    if (!std.fs.path.isAbsolute(zig)) return error.AbsoluteZigPathRequired;
    var dir = try Io.Dir.cwd().openDir(init.io, root, .{});
    defer dir.close(init.io);
    try check(init.gpa, init.io, zig, dir);
}

test "only a normal nonzero exit with the target diagnostic is accepted" {
    try std.testing.expect(expectedRejection(.{ .exited = 1 }, "error: Unsupported application target: freebsd"));
    try std.testing.expect(!expectedRejection(.{ .exited = 0 }, "Unsupported application target:"));
    try std.testing.expect(!expectedRejection(.{ .exited = 1 }, "some other build error"));
    try std.testing.expect(!expectedRejection(.{ .unknown = 42 }, "Unsupported application target:"));
}

test "exact Zig version is mandatory" {
    try std.testing.expect(versionMatches(.{ .exited = 0 }, "0.17.0\n"));
    try std.testing.expect(!versionMatches(.{ .exited = 0 }, "0.16.0\n"));
    try std.testing.expect(!versionMatches(.{ .exited = 1 }, "0.17.0\n"));
    try std.testing.expect(!versionMatches(.{ .unknown = 3 }, "0.17.0"));
}
