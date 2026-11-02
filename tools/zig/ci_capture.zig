//! Experimental Linux CI log capture. This is not an application logger.
//! stdout and stderr share one pipe; only the immediate child is owned.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const tail_limit = 16 * 1024;

const Tail = struct {
    bytes: [tail_limit]u8 = undefined,
    len: usize = 0,

    fn push(self: *Tail, chunk: []const u8) void {
        if (chunk.len >= tail_limit) {
            @memcpy(&self.bytes, chunk[chunk.len - tail_limit ..]);
            self.len = tail_limit;
            return;
        }
        const discard = if (self.len + chunk.len > tail_limit) self.len + chunk.len - tail_limit else 0;
        std.mem.copyForwards(u8, self.bytes[0 .. self.len - discard], self.bytes[discard..self.len]);
        self.len -= discard;
        @memcpy(self.bytes[self.len..][0..chunk.len], chunk);
        self.len += chunk.len;
    }

    fn slice(self: *const Tail) []const u8 {
        return self.bytes[0..self.len];
    }
};

// Decode like UTF-8 with replacement, then escape the three GitHub workflow
// command delimiters. Each input byte expands to at most three output bytes.
fn escapedTail(input: []const u8, buffer: []u8) []const u8 {
    var i: usize = 0;
    var n: usize = 0;
    while (i < input.len) {
        const b = input[i];
        const escape: ?[]const u8 = switch (b) {
            '%' => "%25",
            '\r' => "%0D",
            '\n' => "%0A",
            else => null,
        };
        if (escape) |text| {
            @memcpy(buffer[n..][0..text.len], text);
            n += text.len;
            i += 1;
            continue;
        }
        if (b < 0x80) {
            buffer[n] = b;
            n += 1;
            i += 1;
            continue;
        }
        const width: usize = if (b >= 0xc2 and b <= 0xdf) 2 else if (b >= 0xe0 and b <= 0xef) 3 else if (b >= 0xf0 and b <= 0xf4) 4 else 0;
        var consumed: usize = 1;
        if (width != 0) {
            while (consumed < width and i + consumed < input.len) {
                const c = input[i + consumed];
                if (c < 0x80 or c > 0xbf) break;
                if (consumed == 1 and ((b == 0xe0 and c < 0xa0) or (b == 0xed and c > 0x9f) or (b == 0xf0 and c < 0x90) or (b == 0xf4 and c > 0x8f))) break;
                consumed += 1;
            }
        }
        if (width != 0 and consumed == width) {
            @memcpy(buffer[n..][0..width], input[i..][0..width]);
            n += width;
        } else {
            @memcpy(buffer[n..][0..3], "\xef\xbf\xbd");
            n += 3;
        }
        i += consumed;
    }
    return buffer[0..n];
}

const Status = struct { code: u8, annotation: i32 };

fn exitStatus(term: std.process.Child.Term) Status {
    return switch (term) {
        .exited => |code| .{ .code = code, .annotation = code },
        .signal => |sig| .{ .code = @intCast(128 + @backingInt(sig)), .annotation = -@as(i32, @intCast(@backingInt(sig))) },
        else => .{ .code = 1, .annotation = 1 },
    };
}

const max_timeout_ms = 24 * 60 * 60 * 1000;

fn parseTimeout(text: ?[]const u8) !?u32 {
    const value = text orelse return null;
    if (value.len == 0) return error.InvalidTimeout;
    for (value) |c| if (c < '0' or c > '9') return error.InvalidTimeout;
    const ms = std.fmt.parseInt(u32, value, 10) catch return error.InvalidTimeout;
    if (ms == 0 or ms > max_timeout_ms) return error.InvalidTimeout;
    return ms;
}

fn remainingMs(io: Io, deadline: Io.Timestamp) !i32 {
    const remaining = deadline.nanoseconds - Io.Clock.awake.now(io).nanoseconds;
    if (remaining <= 0) return error.Timeout;
    // Round up to avoid polling early. The configured maximum fits in i32.
    return @intCast(@divTrunc(remaining + std.time.ns_per_ms - 1, std.time.ns_per_ms));
}

fn waitReadable(io: Io, fd: std.os.linux.fd_t, deadline: Io.Timestamp) !void {
    const linux = std.os.linux;
    var fds = [_]linux.pollfd{.{ .fd = fd, .events = linux.POLL.IN, .revents = 0 }};
    while (true) {
        const result = linux.poll(&fds, 1, try remainingMs(io, deadline));
        switch (linux.errno(result)) {
            .SUCCESS => {
                if (result == 0) continue;
                if (fds[0].revents & linux.POLL.NVAL != 0) return error.InvalidPipe;
                return; // read also observes EOF on HUP and errors on ERR
            },
            .INTR => continue,
            else => return error.PollFailed,
        }
    }
}

fn waitUntilExited(io: Io, pid: std.os.linux.pid_t, deadline: Io.Timestamp) !void {
    const linux = std.os.linux;
    while (true) {
        _ = try remainingMs(io, deadline);
        var info: linux.siginfo_t = std.mem.zeroes(linux.siginfo_t);
        const result = linux.waitid(.PID, pid, &info, linux.W.EXITED | linux.W.NOHANG | linux.W.NOWAIT, null);
        switch (linux.errno(result)) {
            .SUCCESS => if (info.fields.common.first.piduid.pid != 0) return,
            .INTR => continue,
            else => return error.ChildPollFailed,
        }
        const delay = @min(try remainingMs(io, deadline), 5);
        try Io.sleep(io, .fromMilliseconds(delay), .awake);
    }
}

fn forceReap(child: *std.process.Child, io: Io) void {
    const pid = child.id orelse return;
    // std.Child.kill sends SIGTERM on Linux and can wait forever for a
    // resistant child. Force termination before asking it to reap.
    while (std.os.linux.errno(std.os.linux.kill(pid, .KILL)) == .INTR) {}
    child.kill(io);
}

fn drainAndWait(init: std.process.Init, child: *std.process.Child, reader: Io.File, tail: *Tail, deadline: ?Io.Timestamp) !std.process.Child.Term {
    var chunk: [4096]u8 = undefined;
    while (true) {
        if (deadline) |limit| try waitReadable(init.io, reader.handle, limit);
        const n = reader.readStreaming(init.io, &.{&chunk}) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        if (n == 0) continue;
        try Io.File.stdout().writeStreamingAll(init.io, chunk[0..n]);
        tail.push(chunk[0..n]);
    }
    if (deadline) |limit| try waitUntilExited(init.io, child.id.?, limit);
    return child.wait(init.io);
}

fn capture(init: std.process.Init, argv: []const []const u8) !u8 {
    // The Zig prototype is intentionally Linux-only until native Windows pipe
    // semantics and cleanup are implemented and verified, not just compiled.
    if (builtin.os.tag != .linux) return error.UnsupportedPlatform;
    const timeout_ms = try parseTimeout(init.environ_map.get("COREX_CI_CAPTURE_TIMEOUT_MS"));
    const deadline: ?Io.Timestamp = if (timeout_ms) |ms| Io.Clock.awake.now(init.io).addDuration(.fromMilliseconds(ms)) else null;
    const fds = try Io.Threaded.pipe2(.{ .CLOEXEC = true });
    const reader: Io.File = .{ .handle = fds[0], .flags = .{ .nonblocking = false } };
    const writer: Io.File = .{ .handle = fds[1], .flags = .{ .nonblocking = false } };
    defer reader.close(init.io);
    var writer_open = true;
    defer if (writer_open) writer.close(init.io);
    // Avoid descriptor aliasing if an inherited standard stream was closed.
    if (fds[0] <= 2 or fds[1] <= 2) return error.StandardStreamClosed;
    var child = std.process.spawn(init.io, .{
        .argv = argv,
        .stdin = .inherit,
        .stdout = .{ .file = writer },
        .stderr = .{ .file = writer },
    }) catch |err| {
        std.debug.print("could not launch CI command: {s}\n", .{@errorName(err)});
        return 127;
    };
    defer forceReap(&child, init.io);
    writer.close(init.io);
    writer_open = false;
    var tail: Tail = .{};
    const status: Status = if (drainAndWait(init, &child, reader, &tail, deadline)) |term|
        exitStatus(term)
    else |err| switch (err) {
        error.Timeout => blk: {
            forceReap(&child, init.io);
            std.debug.print("CI command timed out after {d} ms\n", .{timeout_ms.?});
            break :blk .{ .code = @as(u8, 124), .annotation = @as(i32, 124) };
        },
        else => return err,
    };
    const actions = init.environ_map.get("GITHUB_ACTIONS") orelse "";
    if (status.code != 0 and std.mem.eql(u8, actions, "true")) {
        const out = Io.File.stdout();
        const suffix = tail.slice();
        if (suffix.len != 0 and suffix[suffix.len - 1] != '\n') try out.writeStreamingAll(init.io, "\n");
        var header: [80]u8 = undefined;
        try out.writeStreamingAll(init.io, try std.fmt.bufPrint(&header, "::error title=CI command failed::exit {d}: ", .{status.annotation}));
        var escaped: [tail_limit * 3]u8 = undefined;
        try out.writeStreamingAll(init.io, escapedTail(suffix, &escaped));
        try out.writeStreamingAll(init.io, "\n");
    }
    return status.code;
}

pub fn main(init: std.process.Init) void {
    const status = run(init) catch |err| blk: {
        std.debug.print("CI capture failed: {s}\n", .{@errorName(err)});
        break :blk 1;
    };
    if (status != 0) std.process.exit(status);
}

fn run(init: std.process.Init) !u8 {
    var args = try std.process.Args.iterateAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    _ = args.next();
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(init.gpa);
    while (args.next()) |arg| try argv.append(init.gpa, arg);
    if (argv.items.len == 0) {
        std.debug.print("usage: corex-ci-capture <executable> [arguments...]\n", .{});
        return 2;
    }
    return capture(init, argv.items);
}

test "bounded tail retains last bytes across chunks" {
    var tail: Tail = .{};
    tail.push("first");
    tail.push(" second");
    try std.testing.expectEqualStrings("first second", tail.slice());
    var large: [tail_limit + 2]u8 = @splat('x');
    large[large.len - 1] = 'z';
    tail.push(&large);
    try std.testing.expectEqual(@as(usize, tail_limit), tail.len);
    try std.testing.expectEqual(@as(u8, 'z'), tail.slice()[tail_limit - 1]);
    tail.push("end");
    try std.testing.expectEqualStrings("end", tail.slice()[tail_limit - 3 ..]);
}

test "escape delimiters and malformed UTF-8" {
    var buf: [100]u8 = undefined;
    try std.testing.expectEqualStrings("a%25%0D%0A\xef\xbf\xbdx", escapedTail("a%\r\n\xffx", &buf));
    try std.testing.expectEqualStrings("\xef\xbf\xbdx", escapedTail("\xe2\x82x", &buf));
    try std.testing.expectEqualStrings("\xef\xbf\xbd\xef\xbf\xbd\xef\xbf\xbd", escapedTail("\xed\xa0\x80", &buf));
}

test "tail across many uneven chunks matches a reference suffix" {
    var input: [tail_limit * 2 + 17]u8 = undefined;
    for (&input, 0..) |*byte, i| byte.* = @intCast(i % 251);
    var tail: Tail = .{};
    var start: usize = 0;
    while (start < input.len) {
        const end = @min(start + 97, input.len);
        tail.push(input[start..end]);
        start = end;
    }
    try std.testing.expectEqualSlices(u8, input[input.len - tail_limit ..], tail.slice());
}

test "timeout configuration accepts only bounded decimal milliseconds" {
    try std.testing.expectEqual(@as(?u32, null), try parseTimeout(null));
    try std.testing.expectEqual(@as(?u32, 100), try parseTimeout("100"));
    try std.testing.expectEqual(@as(?u32, max_timeout_ms), try parseTimeout("86400000"));
    for ([_][]const u8{ "", "0", "-1", "+1", " 1", "0x10", "86400001", "999999999999" }) |input| {
        try std.testing.expectError(error.InvalidTimeout, parseTimeout(input));
    }
}
