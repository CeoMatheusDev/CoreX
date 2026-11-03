//! Deliberately misbehaving child used by `test_bootstrap_cli.zig`.
//! It replaces the Python shebang probes of `tools/test_bootstrap.py`: the
//! Editor launches only an explicitly selected absolute executable, so a probe
//! is selected through a sidecar file (`<project>.probe`) whose first line is
//! the mode and whose second line is the optional parameter.
//! Test infrastructure only; not a product tool and not a sandbox.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

const timestamp = "2026-11-01T12:00:00.000Z";

pub fn main(init: std.process.Init) void {
    const code = run(init) catch |err| {
        std.debug.print("bootstrap probe failed: {s}\n", .{@errorName(err)});
        std.process.exit(70);
    };
    if (code != 0) std.process.exit(code);
}

fn write(io: Io, file: Io.File, bytes: []const u8) !void {
    try file.writeStreamingAll(io, bytes);
}

fn emit(io: Io, file: Io.File, seq: u64, session: []const u8, event: []const u8, fields: []const u8, level: []const u8) !void {
    var buffer: [70 * 1024]u8 = undefined;
    const line = try std.fmt.bufPrint(&buffer, "{{\"log_version\":1,\"timestamp\":\"{s}\",\"level\":\"{s}\",\"source\":\"runtime\",\"event\":\"{s}\",\"message\":\"probe\",\"session_id\":\"{s}\",\"seq\":{d},\"tick\":null,\"fields\":{s}}}\n", .{ timestamp, level, event, session, seq, fields });
    try write(io, file, line);
}

fn currentPid() i32 {
    return switch (builtin.os.tag) {
        .linux => std.os.linux.getpid(),
        else => @intCast(std.c.getpid()),
    };
}

/// The probe records its own PID next to the project, so the test can prove the
/// Editor killed and reaped this child. The project file itself is untouched.
fn pidFile(io: Io, gpa: std.mem.Allocator, project: []const u8) !void {
    const path = try std.mem.concat(gpa, u8, &.{ project, ".pid" });
    defer gpa.free(path);
    var buffer: [32]u8 = undefined;
    const text = try std.fmt.bufPrint(&buffer, "{d}", .{currentPid()});
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = text });
}

fn run(init: std.process.Init) !u8 {
    if (builtin.os.tag == .windows) return error.PosixOnly;
    const gpa = init.gpa;
    const io = init.io;
    var args = try std.process.Args.iterateAllocator(init.minimal.args, gpa);
    defer args.deinit();
    _ = args.next();
    var list: std.ArrayList([]const u8) = .empty;
    defer list.deinit(gpa);
    while (args.next()) |arg| try list.append(gpa, arg);

    var project: ?[]const u8 = null;
    for (list.items, 0..) |arg, index| {
        if (std.mem.eql(u8, arg, "--project") and index + 1 < list.items.len) project = list.items[index + 1];
    }
    const path = project orelse return error.MissingProject;

    const config_path = try std.mem.concat(gpa, u8, &.{ path, ".probe" });
    defer gpa.free(config_path);
    const config = try Io.Dir.cwd().readFileAlloc(io, config_path, gpa, .limited(8192));
    defer gpa.free(config);
    var lines = std.mem.splitScalar(u8, config, '\n');
    const mode = std.mem.trim(u8, lines.next() orelse return error.MissingMode, " \r");
    const parameter = std.mem.trim(u8, lines.next() orelse "", " \r");

    const stdout = Io.File.stdout();
    const stderr = Io.File.stderr();
    if (std.mem.eql(u8, mode, "silent")) return 0;
    if (std.mem.eql(u8, mode, "invalid-fragmented")) {
        // One invalid record, one invalid record assembled from two fragments on
        // stdout, and one unterminated line on stderr.
        try write(io, stdout, "not json\n{bad");
        try write(io, stdout, "}\n");
        try write(io, stderr, "last without LF");
        return 0;
    }
    if (std.mem.eql(u8, mode, "wrong-fingerprint")) {
        const fingerprint: [64]u8 = @splat('f');
        var buffer: [128]u8 = undefined;
        const fields = try std.fmt.bufPrint(&buffer, "{{\"fingerprint\":\"{s}\",\"scope\":\"document_and_presets\"}}", .{&fingerprint});
        try emit(io, stdout, 1, "probe", "runtime.validation_complete", fields, "info");
        return 0;
    }
    if (std.mem.eql(u8, mode, "session-gap")) {
        try emit(io, stdout, 1, "a", "probe.event", "{}", "info");
        try emit(io, stdout, 2, "b", "probe.event", "{}", "info");
        return 0;
    }
    if (std.mem.eql(u8, mode, "sequence-order")) {
        try emit(io, stdout, 2, "probe", "probe.event", "{}", "info");
        try emit(io, stdout, 1, "probe", "probe.event", "{}", "info");
        return 0;
    }
    if (std.mem.eql(u8, mode, "duplicate-sequence")) {
        // The same sequence number arrives on both pipes.
        try emit(io, stdout, 1, "probe", "probe.event", "{}", "info");
        try emit(io, stderr, 1, "probe", "probe.event", "{}", "error");
        return 0;
    }
    if (std.mem.eql(u8, mode, "raw-exec")) {
        if (parameter.len == 0) return error.MissingRuntime;
        // Raw library output on stderr, then replace this process with the real
        // Runtime so a valid handshake still has to survive the noise.
        try write(io, stderr, "library warning\n");
        var argv = try gpa.alloc([]const u8, list.items.len + 1);
        defer gpa.free(argv);
        argv[0] = parameter;
        @memcpy(argv[1..], list.items);
        return std.process.replace(io, .{ .exe = .detect, .argv = argv });
    }
    if (std.mem.eql(u8, mode, "two-pipes")) {
        // Both pipes must be drained concurrently; neither side may deadlock.
        var chunk_out: [8192]u8 = @splat('x');
        var chunk_err: [8192]u8 = @splat('y');
        var iteration: usize = 0;
        while (iteration < 16) : (iteration += 1) {
            try write(io, stdout, &chunk_out);
            try write(io, stderr, &chunk_err);
        }
        return 0;
    }
    if (std.mem.eql(u8, mode, "capture-overflow")) {
        try pidFile(io, gpa, path);
        var chunk: [8192]u8 = @splat('x');
        while (true) write(io, stdout, &chunk) catch |err| switch (err) {
            error.BrokenPipe => std.process.exit(0),
            else => return err,
        };
    }
    if (std.mem.eql(u8, mode, "term-resistant")) {
        if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.PosixOnly;
        try pidFile(io, gpa, path);
        const action: std.posix.Sigaction = .{
            .handler = .{ .handler = std.posix.SIG.IGN },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };
        std.posix.sigaction(.TERM, &action, null);
        // Closing both pipes removes the last reason for the supervisor to keep
        // draining, so only its deadline can end this process.
        (Io.File.stdout()).close(io);
        (Io.File.stderr()).close(io);
        try std.Io.sleep(io, .fromSeconds(60), .awake);
        return 0;
    }
    if (std.mem.eql(u8, mode, "line-flood")) {
        var chunk: [5000]u8 = @splat('\n');
        try write(io, stdout, &chunk);
        return 0;
    }
    if (std.mem.eql(u8, mode, "record-overflow")) {
        // A valid child record that does not fit once the Editor wraps it as a
        // field of its own `runtime.output` record.
        var payload: [65_100]u8 = @splat('x');
        var fields_buffer: [65_120]u8 = undefined;
        const fields = try std.fmt.bufPrint(&fields_buffer, "{{\"payload\":\"{s}\"}}", .{&payload});
        try emit(io, stdout, 1, "probe", "probe.event", fields, "info");
        return 0;
    }
    if (std.mem.eql(u8, mode, "nonzero-exit")) {
        try emit(io, stderr, 1, "probe", "probe.event", "{}", "error");
        return 9;
    }
    return error.UnknownMode;
}
