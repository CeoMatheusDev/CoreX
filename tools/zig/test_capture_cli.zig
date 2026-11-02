//! Native black-box tests of the actual Linux CI capture executable.
//! The larger Python regression suite remains in CI until coverage is equivalent.
const std = @import("std");
const builtin = @import("builtin");
const process = @import("corex_app").child_process;
const options = @import("capture_cli_options");
const a = std.testing.allocator;
const io = std.testing.io;
const shell = "/bin/sh";
const limit = 16 * 1024;

// Run the real executable under an explicitly controlled environment. /bin/sh
// only sets environment variables, then execs the capture process: arguments
// are passed as positional parameters, never interpolated as shell source.
// The default PATH is empty of tools, including Python.
fn call(actions: []const u8, timeout: ?[]const u8, path: []const u8, args: []const []const u8) !std.process.RunResult {
    const prefix = [_][]const u8{
        shell,
        "-c",
        "GITHUB_ACTIONS=$1; export GITHUB_ACTIONS; if [ \"$2\" = __unset__ ]; then unset COREX_CI_CAPTURE_TIMEOUT_MS; else COREX_CI_CAPTURE_TIMEOUT_MS=$2; export COREX_CI_CAPTURE_TIMEOUT_MS; fi; PATH=$3; export PATH; shift 3; exec \"$@\"",
        "capture-test",
        actions,
        timeout orelse "__unset__",
        path,
        options.capture,
    };
    const argv = try a.alloc([]const u8, prefix.len + args.len);
    defer a.free(argv);
    @memcpy(argv[0..prefix.len], &prefix);
    @memcpy(argv[prefix.len..], args);
    return process.runCommand(a, io, shell, argv, .inherit, 8000);
}

fn exited(r: std.process.RunResult, code: u8) !void {
    try std.testing.expectEqual(std.process.Child.Term{ .exited = code }, r.term);
}

fn contains(haystack: []const u8, needle: []const u8) !void {
    try std.testing.expect(std.mem.indexOf(u8, haystack, needle) != null);
}

test "usage and failed launch do not execute a command" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const usage = try call("true", null, "/nonexistent", &.{});
    defer process.release(a, usage);
    try exited(usage, 2);
    try contains(usage.stderr, "usage:");
    const missing = try call("true", null, "/nonexistent", &.{"/corex-nonexistent-executable-test"});
    defer process.release(a, missing);
    try exited(missing, 127);
    try contains(missing.stderr, "could not launch CI command");
    try std.testing.expectEqualStrings("", missing.stdout);
}

test "binary output and stderr are merged in order without annotation on success" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    for ([_][]const u8{ "false", "true" }) |actions| {
        const result = try call(actions, null, "/nonexistent", &.{ shell, "-c", "printf 'out\\377'; printf 'err\\000' >&2; printf end" });
        defer process.release(a, result);
        try exited(result, 0);
        try std.testing.expectEqualSlices(u8, "out\xfferr\x00end", result.stdout);
        try std.testing.expectEqualStrings("", result.stderr);
    }
}

test "failure annotations require exact true and start on their own line" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    for ([_][]const u8{ "false", "True", "1", "" }) |actions| {
        const result = try call(actions, null, "/nonexistent", &.{ shell, "-c", "printf 'alpha%%\r\nbeta'; exit 7" });
        defer process.release(a, result);
        try exited(result, 7);
        try std.testing.expectEqualStrings("alpha%\r\nbeta", result.stdout);
        try std.testing.expectEqualStrings("", result.stderr);
    }
    const result = try call("true", null, "/nonexistent", &.{ shell, "-c", "printf 'alpha%%\r\nbeta'; exit 7" });
    defer process.release(a, result);
    try exited(result, 7);
    try std.testing.expectEqualStrings("alpha%\r\nbeta\n::error title=CI command failed::exit 7: alpha%25%0D%0Abeta\n", result.stdout);
}

test "empty and already terminated output annotations" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const cases = [_]struct { code: []const u8, expected: []const u8 }{
        .{ .code = "exit 3", .expected = "::error title=CI command failed::exit 3: \n" },
        .{ .code = "printf 'line\\n'; exit 3", .expected = "line\n::error title=CI command failed::exit 3: line%0A\n" },
        .{ .code = "printf 'line\\r'; exit 3", .expected = "line\r\n::error title=CI command failed::exit 3: line%0D\n" },
    };
    for (cases) |case| {
        const result = try call("true", null, "/nonexistent", &.{ shell, "-c", case.code });
        defer process.release(a, result);
        try exited(result, 3);
        try std.testing.expectEqualStrings(case.expected, result.stdout);
    }
}

test "signal status and PATH argument forwarding without shell expansion" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const signaled = try call("true", null, "/nonexistent", &.{ shell, "-c", "kill -TERM $$" });
    defer process.release(a, signaled);
    try exited(signaled, 143);
    try std.testing.expectEqualStrings("::error title=CI command failed::exit -15: \n", signaled.stdout);
    const args = try call("false", null, "/bin", &.{ "sh", "-c", "printf '%s|%s' \"$1\" \"$2\"", "child", "two words", "$(not a shell) ação" });
    defer process.release(a, args);
    try exited(args, 0);
    try std.testing.expectEqualStrings("two words|$(not a shell) ação", args.stdout);
}

test "tail is bounded and invalid UTF-8 at the boundary is replaced" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const script = "printf '\\342\\202\\254'; i=0; while [ $i -lt 255 ]; do printf '%s' 'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx'; i=$((i+1)); done; printf '%s' 'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx'; exit 4";
    const result = try call("true", null, "/nonexistent", &.{ shell, "-c", script });
    defer process.release(a, result);
    try exited(result, 4);
    const payload = try a.alloc(u8, 3 + limit - 1);
    defer a.free(payload);
    @memcpy(payload[0..3], "\xe2\x82\xac");
    @memset(payload[3..], 'x');
    const expected = try std.mem.concat(a, u8, &.{ payload, "\n::error title=CI command failed::exit 4: \xef\xbf\xbd", payload[3..], "\n" });
    defer a.free(expected);
    try std.testing.expectEqualSlices(u8, expected, result.stdout);
}

test "full tail escapes percent without truncation" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const script = "i=0; while [ $i -lt 256 ]; do printf '%s' '%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%'; i=$((i+1)); done; exit 2";
    const result = try call("true", null, "/nonexistent", &.{ shell, "-c", script });
    defer process.release(a, result);
    try exited(result, 2);
    const prefix = "\n::error title=CI command failed::exit 2: ";
    try std.testing.expectEqual(limit + prefix.len + 3 * limit + 1, result.stdout.len);
    for (result.stdout[0..limit]) |byte| try std.testing.expectEqual(@as(u8, '%'), byte);
    try std.testing.expectEqualStrings(prefix, result.stdout[limit..][0..prefix.len]);
    for (0..limit) |i| try std.testing.expectEqualStrings("%25", result.stdout[limit + prefix.len + 3 * i ..][0..3]);
    try std.testing.expectEqual(@as(u8, '\n'), result.stdout[result.stdout.len - 1]);
}

test "invalid timeout is rejected before starting the child" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &buf);
    const marker = try std.fs.path.join(a, &.{ buf[0..n], "child marker" });
    defer a.free(marker);
    const probe = [_][]const u8{ shell, "-c", ": > \"$1\"", "probe", marker };
    for ([_][]const u8{ "", "0", "-1", "+1", " 1", "86400001", "999999999999" }) |value| {
        const result = try call("false", value, "/nonexistent", &probe);
        defer process.release(a, result);
        try exited(result, 1);
        try contains(result.stderr, "InvalidTimeout");
        try std.testing.expectEqualStrings("", result.stdout);
        try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "child marker", .{}));
    }
    // Verify the marker probe itself can run and write to the chosen directory.
    const valid = try call("false", "1200", "/nonexistent", &probe);
    defer process.release(a, valid);
    try exited(valid, 0);
    try tmp.dir.access(io, "child marker", .{});
}

test "timeout handles fast exit, normal status 124, and closed-pipe resistant child" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const fast = try call("true", "1200", "/nonexistent", &.{ shell, "-c", "printf 'ok\\n'" });
    defer process.release(a, fast);
    try exited(fast, 0);
    try std.testing.expectEqualStrings("ok\n", fast.stdout);
    const normal_124 = try call("false", "1200", "/nonexistent", &.{ shell, "-c", "exit 124" });
    defer process.release(a, normal_124);
    try exited(normal_124, 124);
    try std.testing.expect(std.mem.indexOf(u8, normal_124.stderr, "timed out") == null);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &buf);
    const pidfile = try std.fs.path.join(a, &.{ buf[0..n], "pid" });
    defer a.free(pidfile);
    // Bound the probe itself even if the capture process regresses or is killed.
    const timed = try call("true", "1200", "/nonexistent", &.{ shell, "-c", "trap '' TERM; printf '%s' $$ > \"$1\"; printf started; exec 1>&- 2>&-; exec /bin/sleep 5", "probe", pidfile });
    defer process.release(a, timed);
    try exited(timed, 124);
    try contains(timed.stderr, "timed out");
    try std.testing.expectEqualStrings("started\n::error title=CI command failed::exit 124: started\n", timed.stdout);
    const pid = try tmp.dir.readFileAlloc(io, "pid", a, .limited(128));
    defer a.free(pid);
    const number = try std.fmt.parseInt(u32, pid, 10);
    try std.testing.expect(number > 0);
    try std.Io.Dir.cwd().access(io, "/proc/self/status", .{});
    const proc_path = try std.fmt.allocPrint(a, "/proc/{d}", .{number});
    defer a.free(proc_path);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, proc_path, .{}));
}
