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
    const timeout: std.Io.Timeout = .{ .duration = .{ .raw = .fromMilliseconds(timeout_ms), .clock = .awake } };
    const deadline = timeout.toDeadline(io);
    var child = try std.process.spawn(io, .{
        .exe = .{ .explicit = .{ .dir = .cwd(), .path = executable } },
        .argv = &.{ executable, "--project", project, "--headless", "--validate-only" },
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
