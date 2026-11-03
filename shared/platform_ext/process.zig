//! Bounded validation subprocess. Native exit polling does not reap the child;
//! only this owner can reap. Never cancels std.Child.wait on a live process.
//! This avoids losing ownership on canceled wait and TERM-resistant cleanup.
const std = @import("std");
pub const Result = std.process.RunResult;
pub const capture_limit = 256 * 1024; // each stream, plus stdlib collection slack
extern fn corex_process_exited(id: u64) callconv(.c) i32;
extern fn corex_process_force_terminate(id: u64) callconv(.c) i32;

pub fn release(a: std.mem.Allocator, result: Result) void {
    a.free(result.stdout);
    a.free(result.stderr);
}
fn nativeId(child: *const std.process.Child) u64 {
    return if (@import("builtin").os.tag == .windows) @intFromPtr(child.id.?) else @intCast(child.id.?);
}
fn terminateAndReap(child: *std.process.Child, io: std.Io) void {
    if (child.id == null) return;
    // Retain ownership until termination and reap. No other task waits/reaps.
    _ = corex_process_force_terminate(nativeId(child));
    child.kill(io);
}
const Capture = struct { stdout: []u8, stderr: []u8 };
const Collector = struct {
    done: std.atomic.Value(bool) = .init(false),
    a: std.mem.Allocator,
    io: std.Io,
    stdout: std.Io.File,
    stderr: std.Io.File,
    deadline: std.Io.Timeout,
};
fn freeCapture(a: std.mem.Allocator, output: Capture) void {
    a.free(output.stdout);
    a.free(output.stderr);
}
fn collect(c: *Collector) !Capture {
    defer c.done.store(true, .release);
    var buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
    var reader: std.Io.File.MultiReader = undefined;
    reader.init(c.a, c.io, buffer.toStreams(), &.{ c.stdout, c.stderr });
    defer reader.deinit();
    while (reader.fill(4096, c.deadline)) |_| {
        if (reader.reader(0).buffered().len > capture_limit or reader.reader(1).buffered().len > capture_limit) return error.StreamTooLong;
    } else |err| switch (err) {
        error.EndOfStream => {},
        else => return err,
    }
    try reader.checkAnyError();
    if (reader.reader(0).buffered().len > capture_limit or reader.reader(1).buffered().len > capture_limit) return error.StreamTooLong;
    const stdout = try reader.toOwnedSlice(0);
    errdefer c.a.free(stdout);
    const stderr = try reader.toOwnedSlice(1);
    return .{ .stdout = stdout, .stderr = stderr };
}

/// One deadline covers drain and exit. No shell or PATH lookup. A single
/// collector drains both pipes concurrently; owner checks exit every 5ms.
/// This polling is bootstrap-only, not in a frame loop. Immediate child only;
/// process trees and cooperative Play shutdown are outside this slice.
pub fn runValidation(a: std.mem.Allocator, io: std.Io, executable: []const u8, project: []const u8, timeout_ms: u32) !Result {
    if (!std.fs.path.isAbsolute(executable) or !std.fs.path.isAbsolute(project)) return error.AbsolutePathRequired;
    if (timeout_ms == 0) return error.InvalidTimeout;
    if (@import("builtin").os.tag == .windows and !std.mem.endsWith(u8, executable, ".exe")) return error.NativeExecutableRequired;
    return runCommand(a, io, executable, &.{ executable, "--project", project, "--headless", "--validate-only" }, .inherit, timeout_ms);
}

/// Run an explicitly selected executable without a shell. Both streams are
/// bounded and a single deadline covers collection and waiting for exit. On
/// timeout cleanup terminates/reaps the child; the OS may delay cleanup itself.
/// Only the direct child is owned/reaped; descendants are not a sandbox.
/// Callers own stdout/stderr on success and release them via release().
pub fn runCommand(a: std.mem.Allocator, io: std.Io, executable: []const u8, argv: []const []const u8, cwd: std.process.Child.Cwd, timeout_ms: u32) !Result {
    if (!std.fs.path.isAbsolute(executable)) return error.AbsolutePathRequired;
    if (argv.len == 0 or !std.mem.eql(u8, argv[0], executable)) return error.InvalidArguments;
    if (timeout_ms == 0) return error.InvalidTimeout;
    const timeout: std.Io.Timeout = .{ .duration = .{ .raw = .fromMilliseconds(timeout_ms), .clock = .awake } };
    const deadline = timeout.toDeadline(io);
    var child = try std.process.spawn(io, .{
        .exe = .{ .explicit = .{ .dir = .cwd(), .path = executable } },
        .argv = argv,
        .cwd = cwd,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    defer terminateAndReap(&child, io);
    var collector: Collector = .{ .a = a, .io = io, .stdout = child.stdout.?, .stderr = child.stderr.?, .deadline = deadline };
    var future = try std.Io.concurrent(io, collect, .{&collector});
    var taken = false;
    defer if (!taken) {
        if (future.cancel(io)) |output| freeCapture(a, output) else |_| {}
    };
    var output: ?Capture = null;
    errdefer if (output) |owned| freeCapture(a, owned);
    while (true) {
        if (!taken and collector.done.load(.acquire)) {
            taken = true;
            output = try future.await(io);
        }
        const exited = corex_process_exited(nativeId(&child));
        if (exited < 0) return error.NativeChildPollFailed;
        if (exited == 1) break;
        if (std.Io.Clock.awake.now(io).nanoseconds >= deadline.deadline.raw.nanoseconds) return error.Timeout;
        try std.Io.sleep(io, .fromMilliseconds(5), .awake);
    }
    // Drain before wait closes pipe handles. Collection still has the same
    // deadline if descendants incorrectly keep a pipe open.
    if (!taken) {
        taken = true;
        output = try future.await(io);
    }
    // Child is confirmed exited but not yet reaped. Protect final wait against
    // cancellation so stdlib cleanup cannot lose the unreaped child on error.
    const old = io.swapCancelProtection(.blocked);
    const term = child.wait(io) catch |err| {
        _ = io.swapCancelProtection(old);
        return err;
    };
    _ = io.swapCancelProtection(old);
    return .{ .term = term, .stdout = output.?.stdout, .stderr = output.?.stderr };
}

test "child validation requires explicit absolute executable and project" {
    try std.testing.expectError(error.AbsolutePathRequired, runValidation(std.testing.allocator, std.testing.io, "player", "/Game.proj", 100));
}

test "generic command validates executable, arguments and deadline" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    try std.testing.expectError(error.AbsolutePathRequired, runCommand(a, io, "relative", &.{"relative"}, .inherit, 1));
    try std.testing.expectError(error.InvalidArguments, runCommand(a, io, "/absolute", &.{}, .inherit, 1));
    try std.testing.expectError(error.InvalidArguments, runCommand(a, io, "/absolute", &.{"different"}, .inherit, 1));
    try std.testing.expectError(error.InvalidTimeout, runCommand(a, io, "/absolute", &.{"/absolute"}, .inherit, 0));
}

test "generic command captures both streams and nonzero status" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    const a = std.testing.allocator;
    const io = std.testing.io;
    const executable = "/bin/sh";
    const result = try runCommand(a, io, executable, &.{ executable, "-c", "printf stdout; printf stderr >&2; exit 7" }, .inherit, 3000);
    defer release(a, result);
    try std.testing.expectEqualStrings("stdout", result.stdout);
    try std.testing.expectEqualStrings("stderr", result.stderr);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 7 }, result.term);
}

test "generic command deadline covers closed pipes and TERM-resistant child" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    const a = std.testing.allocator;
    const io = std.testing.io;
    const executable = "/bin/sh";
    try std.testing.expectError(error.Timeout, runCommand(a, io, executable, &.{ executable, "-c", "exec 1>&- 2>&-; trap '' TERM; while :; do :; done" }, .inherit, 150));
}

test "generic command honors child working directory" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "marker", .data = "" });
    const executable = "/bin/sh";
    const result = try runCommand(a, io, executable, &.{ executable, "-c", "test -f marker && printf found" }, .{ .dir = tmp.dir }, 3000);
    defer release(a, result);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expectEqualStrings("found", result.stdout);
}

test "generic command rejects output beyond capture limit" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    const executable = "/bin/sh";
    try std.testing.expectError(error.StreamTooLong, runCommand(std.testing.allocator, std.testing.io, executable, &.{ executable, "-c", "while :; do printf '01234567890123456789012345678901'; done" }, .inherit, 3000));
}

test "generic command handles collection allocation failure" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    const executable = "/bin/sh";
    try std.testing.expectError(error.OutOfMemory, runCommand(std.testing.failing_allocator, std.testing.io, executable, &.{ executable, "-c", "printf data" }, .inherit, 3000));
}
