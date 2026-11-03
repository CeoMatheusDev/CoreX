//! Native black-box integration tests of the real Editor and Runtime
//! executables. This is the Zig port of `tools/test_bootstrap.py`: real child
//! processes, real JSONL framing on both pipes, real deadlines and cleanup.
//! The Python shebang probes are replaced by `bootstrap_probe.zig`, selected
//! through a sidecar file because the Editor only launches an explicit,
//! absolute executable. POSIX-only: a cross-compiled binary proves nothing.
const std = @import("std");
const builtin = @import("builtin");
const process = @import("corex_app").child_process;
const options = @import("bootstrap_cli_options");
const Io = std.Io;
const a = std.testing.allocator;
const io = std.testing.io;
const max_record = 64 * 1024;

fn requirePosix() !void {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
}

/// Liveness probes are POSIX-only. The `check` step compiles this file for
/// cross targets, so the Windows side must not reference POSIX signal or PID
/// APIs at all; the selection below is resolved at compile time.
const Liveness = if (builtin.os.tag == .windows) struct {
    fn readPid(_: []const u8, _: std.mem.Allocator) !i32 {
        return error.SkipZigTest;
    }
    fn expectReaped(_: []const u8, _: std.mem.Allocator) !void {
        return error.SkipZigTest;
    }
} else struct {
    fn readPid(path: []const u8, allocator: std.mem.Allocator) !i32 {
        const text = try Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(64));
        return @intCast(try std.fmt.parseInt(std.posix.pid_t, std.mem.trim(u8, text, " \r\n"), 10));
    }
    fn expectReaped(path: []const u8, allocator: std.mem.Allocator) !void {
        const pid: std.posix.pid_t = @intCast(try readPid(path, allocator));
        std.posix.kill(pid, @fromBackingInt(@intCast(0))) catch |err| switch (err) {
            error.ProcessNotFound => return,
            else => return err,
        };
        // Never leave a runaway helper behind if the regression returns.
        std.posix.kill(pid, std.posix.SIG.KILL) catch {};
        std.debug.print("child {d} was not killed/reaped\n", .{pid});
        return error.ChildNotReaped;
    }
};

// ---------------------------------------------------------------------------
// JSON helpers
// ---------------------------------------------------------------------------

fn objectOf(value: std.json.Value) !std.json.ObjectMap {
    if (value != .object) return error.NotAnObject;
    return value.object;
}

fn field(value: std.json.Value, key: []const u8) !std.json.Value {
    return (try objectOf(value)).get(key) orelse error.MissingField;
}

fn textField(value: std.json.Value, key: []const u8) ![]const u8 {
    const item = try field(value, key);
    if (item != .string) return error.NotAString;
    return item.string;
}

fn boolField(value: std.json.Value, key: []const u8) !bool {
    const item = try field(value, key);
    if (item != .bool) return error.NotABoolean;
    return item.bool;
}

fn intField(value: std.json.Value, key: []const u8) !i64 {
    const item = try field(value, key);
    return switch (item) {
        .integer => |number| number,
        else => error.NotAnInteger,
    };
}

fn uintField(value: std.json.Value, key: []const u8) !u64 {
    const item = try field(value, key);
    return switch (item) {
        .integer => |number| if (number >= 0) @intCast(number) else error.NotAnInteger,
        .number_string => |text| std.fmt.parseInt(u64, text, 10),
        else => error.NotAnInteger,
    };
}

fn expectTextField(value: std.json.Value, key: []const u8, want: []const u8) !void {
    const actual = textField(value, key) catch |err| {
        std.debug.print("field \"{s}\": {s}\n", .{ key, @errorName(err) });
        return err;
    };
    if (!std.mem.eql(u8, actual, want)) {
        std.debug.print("field \"{s}\": expected \"{s}\", got \"{s}\"\n", .{ key, want, actual });
        return error.UnexpectedFieldValue;
    }
}

fn expectBoolField(value: std.json.Value, key: []const u8, want: bool) !void {
    const actual = try boolField(value, key);
    if (actual != want) {
        std.debug.print("field \"{s}\": expected {}, got {}\n", .{ key, want, actual });
        return error.UnexpectedFieldValue;
    }
}

fn expectIntField(value: std.json.Value, key: []const u8, want: i64) !void {
    const actual = try intField(value, key);
    if (actual != want) {
        std.debug.print("field \"{s}\": expected {d}, got {d}\n", .{ key, want, actual });
        return error.UnexpectedFieldValue;
    }
}

fn expectStringArray(value: std.json.Value, key: []const u8, want: []const []const u8) !void {
    const item = try field(value, key);
    if (item != .array) return error.NotAnArray;
    if (item.array.items.len != want.len) return error.UnexpectedArrayLength;
    for (item.array.items, want) |actual, expected| {
        if (actual != .string or !std.mem.eql(u8, actual.string, expected)) return error.UnexpectedArrayValue;
    }
}

/// Path into a parsed document, e.g. `{"renderer","profile"}`.
fn setJson(allocator: std.mem.Allocator, root: *std.json.Value, path: []const []const u8, value: std.json.Value) !void {
    var current = root;
    for (path[0 .. path.len - 1]) |key| current = current.object.getPtr(key) orelse return error.MissingKey;
    try current.object.put(allocator, path[path.len - 1], value);
}

fn removeJson(root: *std.json.Value, path: []const []const u8) !void {
    var current = root;
    for (path[0 .. path.len - 1]) |key| current = current.object.getPtr(key) orelse return error.MissingKey;
    if (!current.object.orderedRemove(path[path.len - 1])) return error.MissingKey;
}

fn writeCanonical(allocator: std.mem.Allocator, writer: *Io.Writer, value: std.json.Value) !void {
    switch (value) {
        .object => |object| {
            try writer.writeByte('{');
            const keys = try allocator.alloc([]const u8, object.count());
            var index: usize = 0;
            for (object.keys()) |key| {
                keys[index] = key;
                index += 1;
            }
            std.mem.sort([]const u8, keys, {}, struct {
                fn lessThan(_: void, left: []const u8, right: []const u8) bool {
                    return std.mem.order(u8, left, right) == .lt;
                }
            }.lessThan);
            for (keys, 0..) |key, position| {
                if (position != 0) try writer.writeByte(',');
                try std.json.Stringify.value(key, .{}, writer);
                try writer.writeByte(':');
                try writeCanonical(allocator, writer, object.get(key).?);
            }
            try writer.writeByte('}');
        },
        .array => |array| {
            try writer.writeByte('[');
            for (array.items, 0..) |item, position| {
                if (position != 0) try writer.writeByte(',');
                try writeCanonical(allocator, writer, item);
            }
            try writer.writeByte(']');
        },
        else => try std.json.Stringify.value(value, .{}, writer),
    }
}

/// Property order and whitespace must not change the document fingerprint.
fn canonicalJson(allocator: std.mem.Allocator, value: std.json.Value) ![]u8 {
    var out: Io.Writer.Allocating = .init(allocator);
    try writeCanonical(allocator, &out.writer, value);
    try out.writer.writeByte('\n');
    return std.mem.concat(allocator, u8, &.{ out.written(), "" });
}

fn jsonText(allocator: std.mem.Allocator, value: std.json.Value) ![]u8 {
    var out: Io.Writer.Allocating = .init(allocator);
    try std.json.Stringify.value(value, .{}, &out.writer);
    return std.mem.concat(allocator, u8, &.{ out.written(), "" });
}

fn prettyJson(allocator: std.mem.Allocator, value: std.json.Value) ![]u8 {
    var out: Io.Writer.Allocating = .init(allocator);
    try std.json.Stringify.value(value, .{ .whitespace = .indent_2 }, &out.writer);
    try out.writer.writeByte('\n');
    return std.mem.concat(allocator, u8, &.{ out.written(), "" });
}

fn replaceAll(allocator: std.mem.Allocator, haystack: []const u8, needle: []const u8, replacement: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var rest = haystack;
    while (std.mem.indexOf(u8, rest, needle)) |index| {
        try out.appendSlice(allocator, rest[0..index]);
        try out.appendSlice(allocator, replacement);
        rest = rest[index + needle.len ..];
    }
    try out.appendSlice(allocator, rest);
    return out.toOwnedSlice(allocator);
}

fn validTimestamp(text: []const u8) bool {
    if (text.len != 24) return false;
    const template = "0000-00-00T00:00:00.000Z";
    for (text, template) |byte, expected| {
        if (std.ascii.isDigit(expected)) {
            if (!std.ascii.isDigit(byte)) return false;
        } else if (byte != expected) return false;
    }
    const year = std.fmt.parseInt(u32, text[0..4], 10) catch return false;
    const month = std.fmt.parseInt(u32, text[5..7], 10) catch return false;
    const day = std.fmt.parseInt(u32, text[8..10], 10) catch return false;
    const hour = std.fmt.parseInt(u32, text[11..13], 10) catch return false;
    const minute = std.fmt.parseInt(u32, text[14..16], 10) catch return false;
    const second = std.fmt.parseInt(u32, text[17..19], 10) catch return false;
    if (year == 0 or month == 0 or month > 12 or day == 0) return false;
    const leap = (year % 4 == 0 and year % 100 != 0) or year % 400 == 0;
    const days = [_]u32{ 31, if (leap) 29 else 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    if (day > days[month - 1]) return false;
    return hour < 24 and minute < 60 and second < 60;
}

// ---------------------------------------------------------------------------
// Captured records of one child execution
// ---------------------------------------------------------------------------

const Run = struct {
    arena: std.heap.ArenaAllocator,
    roots: std.ArrayList(std.json.Value) = .empty,
    result: std.process.RunResult = undefined,
    owned: bool = false,

    fn init() Run {
        return .{ .arena = std.heap.ArenaAllocator.init(a) };
    }

    fn deinit(self: *Run) void {
        if (self.owned) process.release(a, self.result);
        self.arena.deinit();
    }

    fn allocator(self: *Run) std.mem.Allocator {
        return self.arena.allocator();
    }

    fn event(self: *Run, name: []const u8) !std.json.Value {
        return findEvent(self.roots.items, name);
    }

    fn countOf(self: *Run, name: []const u8) usize {
        var count: usize = 0;
        for (self.roots.items) |root| {
            const candidate = textField(root, "event") catch continue;
            if (std.mem.eql(u8, candidate, name)) count += 1;
        }
        return count;
    }

    /// Records the child of `--check-runtime` printed, unwrapped from
    /// `runtime.output.fields.record`.
    fn childRoots(self: *Run) ![]std.json.Value {
        var list: std.ArrayList(std.json.Value) = .empty;
        for (self.roots.items) |root| {
            const candidate = textField(root, "event") catch continue;
            if (!std.mem.eql(u8, candidate, "runtime.output")) continue;
            try list.append(self.allocator(), try field(try field(root, "fields"), "record"));
        }
        return list.toOwnedSlice(self.allocator());
    }
};

fn findEvent(roots: []const std.json.Value, name: []const u8) !std.json.Value {
    var found: ?std.json.Value = null;
    var count: usize = 0;
    for (roots) |root| {
        const candidate = textField(root, "event") catch continue;
        if (!std.mem.eql(u8, candidate, name)) continue;
        count += 1;
        found = try field(root, "fields");
    }
    if (count != 1 or found == null) {
        std.debug.print("expected exactly one \"{s}\" record, got {d}\n", .{ name, count });
        return error.EventCountMismatch;
    }
    return found.?;
}

// ---------------------------------------------------------------------------
// Temporary project and compiled executables
// ---------------------------------------------------------------------------

const Distribution = struct { prefix: []const u8, runtime: []const u8 };

const Cwd = std.process.Child.Cwd;

const Fixture = struct {
    tmp: std.testing.TmpDir,
    directory: []u8,
    project_dir: Io.Dir,
    project_name: []u8,
    project_path: []u8,
    editor: [:0]u8,
    runtime: [:0]u8,
    probe: [:0]u8,
    share_dir: []u8,
    base: []u8,
    v3: []u8,

    fn init() !Fixture {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        var buffer: [std.fs.max_path_bytes]u8 = undefined;
        const length = try tmp.dir.realPath(io, &buffer);
        const root_path = try a.dupe(u8, buffer[0..length]);
        defer a.free(root_path);
        const directory = try std.fs.path.join(a, &.{ root_path, "Jogo ação" });
        errdefer a.free(directory);
        try Io.Dir.cwd().createDirPath(io, directory);
        const project_dir = try Io.Dir.cwd().openDir(io, directory, .{});
        errdefer project_dir.close(io);
        const project_name = try a.dupe(u8, "My Game.proj");
        errdefer a.free(project_name);
        const project_path = try std.fs.path.join(a, &.{ directory, project_name });
        errdefer a.free(project_path);
        const editor = try Io.Dir.cwd().realPathFileAlloc(io, options.editor, a);
        errdefer a.free(editor);
        const runtime = try Io.Dir.cwd().realPathFileAlloc(io, options.runtime, a);
        errdefer a.free(runtime);
        const probe = try Io.Dir.cwd().realPathFileAlloc(io, options.probe, a);
        errdefer a.free(probe);
        // `zig-out/bin/CoreXRuntime` resolves presets relative to the installed
        // distribution, never the current working directory.
        const share_dir = try std.fs.path.join(a, &.{ std.fs.path.dirname(runtime).?, "..", "share" });
        errdefer a.free(share_dir);
        const base = try readRepositoryFile("docs/examples/EmptyGame.proj");
        errdefer a.free(base);
        const v3 = try readRepositoryFile("docs/examples/EmptyGameV3.proj");
        errdefer a.free(v3);
        var fixture: Fixture = .{
            .tmp = tmp,
            .directory = directory,
            .project_dir = project_dir,
            .project_name = project_name,
            .project_path = project_path,
            .editor = editor,
            .runtime = runtime,
            .probe = probe,
            .share_dir = share_dir,
            .base = base,
            .v3 = v3,
        };
        try fixture.writeText(fixture.base);
        return fixture;
    }

    fn deinit(self: *Fixture) void {
        self.project_dir.close(io);
        a.free(self.directory);
        a.free(self.project_name);
        a.free(self.project_path);
        a.free(self.editor);
        a.free(self.runtime);
        a.free(self.probe);
        a.free(self.share_dir);
        a.free(self.base);
        a.free(self.v3);
        self.tmp.cleanup();
    }

    fn readRepositoryFile(sub_path: []const u8) ![]u8 {
        var root = try Io.Dir.cwd().openDir(io, options.repository_root, .{});
        defer root.close(io);
        return root.readFileAlloc(io, sub_path, a, .limited(4 * 1024 * 1024));
    }

    fn writeText(self: *Fixture, data: []const u8) !void {
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = self.project_path, .data = data });
    }

    fn document(self: *Fixture, allocator: std.mem.Allocator) !std.json.Value {
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, self.base, .{ .allocate = .alloc_always });
        return parsed.value;
    }

    fn writeJson(self: *Fixture, allocator: std.mem.Allocator, value: std.json.Value) !void {
        try self.writeText(try prettyJson(allocator, value));
    }

    /// A UTF-8 CLI argument may name a path that cannot itself be represented
    /// as UTF-8 on POSIX; the project path has to follow the CLI argument.
    fn setProjectName(self: *Fixture, name: []const u8) !void {
        const next = try std.fs.path.join(a, &.{ self.directory, name });
        a.free(self.project_path);
        self.project_path = next;
        a.free(self.project_name);
        self.project_name = try a.dupe(u8, name);
    }

    fn sidecar(self: *Fixture, extension: []const u8, allocator: std.mem.Allocator) ![]u8 {
        return std.mem.concat(allocator, u8, &.{ self.project_path, extension });
    }

    /// The probe selects its behavior from a sidecar file, because the Editor
    /// never forwards extra arguments to the child it supervises.
    fn useProbe(self: *Fixture, allocator: std.mem.Allocator, mode: []const u8, parameter: []const u8) ![]const u8 {
        const path = try self.sidecar(".probe", allocator);
        const contents = try std.mem.concat(allocator, u8, &.{ mode, "\n", parameter, "\n" });
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = contents });
        return self.probe;
    }

    fn expectReaped(self: *Fixture, allocator: std.mem.Allocator) !void {
        return Liveness.expectReaped(try self.sidecar(".pid", allocator), allocator);
    }

    fn copyDistribution(self: *Fixture, allocator: std.mem.Allocator) !Distribution {
        const prefix = try std.fs.path.join(allocator, &.{ self.directory, "Moved distribution" });
        const bin = try std.fs.path.join(allocator, &.{ prefix, "bin" });
        const share = try std.fs.path.join(allocator, &.{ prefix, "share", "corex" });
        try Io.Dir.cwd().createDirPath(io, bin);
        try Io.Dir.cwd().createDirPath(io, share);
        const runtime = try std.fs.path.join(allocator, &.{ bin, std.fs.path.basename(self.runtime) });
        try Io.Dir.copyFileAbsolute(self.runtime, runtime, io, .{});
        for ([_][]const u8{ "presets.zon", "distribution.json" }) |name| {
            const source = try std.fs.path.join(allocator, &.{ self.share_dir, "corex", name });
            const destination = try std.fs.path.join(allocator, &.{ share, name });
            try Io.Dir.copyFileAbsolute(source, destination, io, .{});
        }
        return .{ .prefix = prefix, .runtime = runtime };
    }

    const Options = struct {
        expected: u8 = 0,
        cwd: Cwd = .inherit,
        timeout_ms: u32 = 20_000,
        track_project: bool = true,
        /// The product supervisor bounds child capture at 256 KiB per pipe. A
        /// few bootstrap cases intentionally expect more output from the
        /// application itself, so the harness needs its own wider bound.
        capture_limit: usize = process.capture_limit,
    };

    fn runApp(self: *Fixture, out: *Run, executable: []const u8, extra: []const []const u8, opts: Options) !void {
        const allocator = out.allocator();
        const argv = try allocator.alloc([]const u8, extra.len + 1);
        argv[0] = executable;
        @memcpy(argv[1..], extra);

        var before: ?[]u8 = null;
        var before_mtime: ?Io.Timestamp = null;
        if (opts.track_project) {
            before = Io.Dir.cwd().readFileAlloc(io, self.project_path, allocator, .limited(8 * 1024 * 1024)) catch null;
            if (Io.Dir.cwd().statFile(io, self.project_path, .{})) |stat| before_mtime = stat.mtime else |_| {}
        }
        out.result = if (opts.capture_limit > process.capture_limit)
            try captureLarge(a, io, executable, argv, opts.cwd, opts.timeout_ms, opts.capture_limit)
        else
            try process.runCommand(a, io, executable, argv, opts.cwd, opts.timeout_ms);
        out.owned = true;
        const term = out.result.term;
        if (term != .exited or term.exited != opts.expected) {
            std.debug.print("unexpected exit for {s}: {any}\nstdout:\n{s}\nstderr:\n{s}\n", .{
                executable, term, out.result.stdout, out.result.stderr,
            });
            return error.UnexpectedExit;
        }
        if (opts.track_project) {
            const after = Io.Dir.cwd().readFileAlloc(io, self.project_path, allocator, .limited(8 * 1024 * 1024)) catch null;
            const after_mtime: ?Io.Timestamp = if (Io.Dir.cwd().statFile(io, self.project_path, .{})) |stat| stat.mtime else |_| null;
            const same_bytes = if (before == null and after == null) true else if (before != null and after != null) std.mem.eql(u8, before.?, after.?) else false;
            if (!same_bytes) return error.ProjectBytesChanged;
            if (before_mtime != null and after_mtime != null and before_mtime.?.nanoseconds != after_mtime.?.nanoseconds) return error.ProjectMtimeChanged;
        }
        try parseStream(out, "stdout", out.result.stdout);
        try parseStream(out, "stderr", out.result.stderr);
        try validateSequence(out);
    }

    fn validate(self: *Fixture, out: *Run, executable: []const u8, extra: []const []const u8, opts: Options) !void {
        const allocator = out.allocator();
        var args: std.ArrayList([]const u8) = .empty;
        try args.appendSlice(allocator, &.{ "--project", self.project_path, "--headless", "--validate-only" });
        try args.appendSlice(allocator, extra);
        try self.runApp(out, executable, args.items, opts);
    }

    /// The Editor compares its own fingerprint with a real Runtime child.
    fn check(self: *Fixture, out: *Run, child: []const u8, opts: Options) !void {
        try self.validate(out, self.editor, &.{ "--check-runtime", child }, opts);
    }
};

fn parseStream(out: *Run, stream: []const u8, bytes: []const u8) !void {
    if (bytes.len == 0) return;
    if (bytes[bytes.len - 1] != '\n') {
        std.debug.print("{s}: official writer omitted the final LF\n", .{stream});
        return error.MissingLineFeed;
    }
    var lines = std.mem.splitScalar(u8, bytes[0 .. bytes.len - 1], '\n');
    while (lines.next()) |line| {
        if (line.len + 1 > max_record) return error.LineTooLong;
        const parsed = try std.json.parseFromSlice(std.json.Value, out.allocator(), line, .{ .allocate = .alloc_always });
        const root = parsed.value;
        try std.testing.expectEqual(@as(i64, 1), try intField(root, "log_version"));
        const stamp = try textField(root, "timestamp");
        if (!validTimestamp(stamp)) {
            std.debug.print("{s}: invalid timestamp \"{s}\"\n", .{ stream, stamp });
            return error.InvalidTimestamp;
        }
        const level = try textField(root, "level");
        const wants_stderr = std.mem.eql(u8, level, "warn") or std.mem.eql(u8, level, "error");
        if (!wants_stderr and !(std.mem.eql(u8, level, "debug") or std.mem.eql(u8, level, "info"))) return error.InvalidLevel;
        if (wants_stderr != std.mem.eql(u8, stream, "stderr")) {
            std.debug.print("{s}: level \"{s}\" written to the wrong stream\n", .{ stream, level });
            return error.WrongStreamForLevel;
        }
        if ((try field(root, "fields")) != .object) return error.FieldsNotAnObject;
        if ((try field(root, "tick")) != .null) return error.UnexpectedTick;
        if (std.mem.eql(u8, try textField(root, "event"), "runtime.ready")) return error.FakeRuntimeReady;
        try out.roots.append(out.allocator(), root);
    }
}

fn validateSequence(self: *Run) !void {
    if (self.roots.items.len == 0) {
        std.debug.print("missing structured diagnostics\n", .{});
        return error.NoDiagnostics;
    }
    const allocator = self.allocator();
    const sessions = try allocator.alloc([]const u8, self.roots.items.len);
    const sequences = try allocator.alloc(u64, self.roots.items.len);
    for (self.roots.items, 0..) |root, index| {
        sessions[index] = try textField(root, "session_id");
        sequences[index] = @intCast(try intField(root, "seq"));
    }
    for (sessions) |session| {
        if (!std.mem.eql(u8, session, sessions[0])) return error.MultipleSessions;
    }
    // stdout and stderr are separate pipes: only the sorted set of sequence
    // numbers can be compared, never the interleaving.
    std.mem.sort(u64, sequences, {}, std.sort.asc(u64));
    for (sequences, 0..) |sequence, index| {
        if (sequence != index + 1) return error.NonContiguousSequence;
    }
}

// ---------------------------------------------------------------------------
// Dataset-level contracts
// ---------------------------------------------------------------------------

test "runtime validation is not game execution" {
    try requirePosix();
    var f = try Fixture.init();
    defer f.deinit();
    var run = Run.init();
    defer run.deinit();
    try f.validate(&run, f.runtime, &.{}, .{});
    const complete = try run.event("runtime.validation_complete");
    try expectTextField(complete, "scope", "document_and_presets");
    try expectBoolField(complete, "resources_loaded", false);
    try expectBoolField(complete, "core_linked", false);
    try expectBoolField(complete, "core_abi_checked", false);
    try expectBoolField(try run.event("graphics.config_resolved"), "gpu_created", false);
    try expectTextField(try run.event("project.engine_compatibility"), "compatibility", "same_version");
}

test "fingerprint normalizes JSON property order and whitespace" {
    try requirePosix();
    var f = try Fixture.init();
    defer f.deinit();
    var run = Run.init();
    defer run.deinit();
    try f.validate(&run, f.runtime, &.{}, .{});
    const first = try textField(try run.event("runtime.validation_complete"), "fingerprint");
    const allocator = run.allocator();
    const reordered = try canonicalJson(allocator, try f.document(allocator));
    try std.testing.expect(!std.mem.eql(u8, reordered, f.base));
    try f.writeText(reordered);
    var second_run = Run.init();
    defer second_run.deinit();
    try f.validate(&second_run, f.runtime, &.{}, .{});
    try std.testing.expectEqualStrings(first, try textField(try second_run.event("runtime.validation_complete"), "fingerprint"));
}

test "compiled product identity is exposed without opening a project" {
    try requirePosix();
    var f = try Fixture.init();
    defer f.deinit();
    for ([_][]const u8{ f.editor, f.runtime }) |executable| {
        var run = Run.init();
        defer run.deinit();
        try f.runApp(&run, executable, &.{"--version"}, .{});
        const fields = try run.event("application.version");
        try expectTextField(fields, "engine_version", "0.1.0a1");
        try expectTextField(fields, "project_engine_version", "0.1.0-alpha.1");
        try expectBoolField(fields, "core_abi_checked", false);
    }
}

test "editor launches real runtime and compares full fingerprint" {
    try requirePosix();
    var f = try Fixture.init();
    defer f.deinit();
    var run = Run.init();
    defer run.deinit();
    try f.check(&run, f.runtime, .{});
    const own = try run.event("editor.validation_complete");
    const checked = try run.event("runtime.check_complete");
    try std.testing.expectEqualStrings(try textField(own, "fingerprint"), try textField(checked, "fingerprint"));
    try expectBoolField(checked, "play_started", false);
    const children = try run.childRoots();
    try std.testing.expect(children.len != 0);
    const child_complete = try findEvent(children, "runtime.validation_complete");
    try std.testing.expectEqualStrings(try textField(own, "fingerprint"), try textField(child_complete, "fingerprint"));
    // The child is a separate process with its own session identity.
    try std.testing.expect(!std.mem.eql(u8, try textField(children[0], "session_id"), try textField(run.roots.items[0], "session_id")));
    const parent_parameters = try jsonText(run.allocator(), try field(try run.event("graphics.config_resolved"), "parameters"));
    const child_parameters = try jsonText(run.allocator(), try field(try findEvent(children, "graphics.config_resolved"), "parameters"));
    try std.testing.expectEqualStrings(parent_parameters, child_parameters);

    // JSONL is framed by LF only, not Unicode line/paragraph separators.
    try f.setProjectName("Line\u{2028}break\u{85}project.proj");
    try f.writeText(f.base);
    var unicode_run = Run.init();
    defer unicode_run.deinit();
    try f.check(&unicode_run, f.runtime, .{});
    const path = try textField(try unicode_run.event("project.document_validated"), "path");
    try std.testing.expect(std.mem.indexOf(u8, path, "Line\u{2028}break\u{85}project.proj") != null);

    if (builtin.os.tag == .linux) {
        // A UTF-8 CLI symlink may resolve to a non-UTF8 POSIX filename.
        const allocator = unicode_run.allocator();
        const target = try std.mem.concat(allocator, u8, &.{ f.directory, "/invalid-", "\xff", ".proj" });
        const contents = try Io.Dir.cwd().readFileAlloc(io, f.project_path, allocator, .limited(1024 * 1024));
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = target, .data = contents });
        try f.setProjectName("UTF8 symlink.proj");
        try Io.Dir.symLinkAbsolute(io, target, f.project_path, .{});
        var symlink_run = Run.init();
        defer symlink_run.deinit();
        try f.validate(&symlink_run, f.runtime, &.{}, .{ .expected = 3 });
        try expectTextField(try symlink_run.event("project.read_failed"), "code", "UnsupportedProjectPathEncoding");
    }
}

test "v3 renderer profile is explicit and separate from product profile" {
    try requirePosix();
    var f = try Fixture.init();
    defer f.deinit();
    var scratch = std.heap.ArenaAllocator.init(a);
    defer scratch.deinit();
    const allocator = scratch.allocator();
    var value = (try std.json.parseFromSlice(std.json.Value, allocator, f.v3, .{ .allocate = .alloc_always })).value;
    try f.writeJson(allocator, value);
    var run = Run.init();
    defer run.deinit();
    try f.validate(&run, f.runtime, &.{}, .{});
    const policy = try run.event("application.target_policy");
    try expectTextField(policy, "profile", "desktop-3d-canvas-v1");
    try expectTextField(policy, "renderer_profile", "lite");
    const resolved = try run.event("graphics.config_resolved");
    try expectTextField(resolved, "renderer_profile_requested", "lite");
    try expectBoolField(resolved, "gpu_created", false);
    try expectBoolField(resolved, "capabilities_checked", false);
    const lite = try allocator.dupe(u8, try textField(try run.event("runtime.validation_complete"), "fingerprint"));

    try setJson(allocator, &value, &.{ "renderer", "profile" }, .{ .string = "advanced" });
    try f.writeJson(allocator, value);
    var advanced_run = Run.init();
    defer advanced_run.deinit();
    try f.validate(&advanced_run, f.runtime, &.{}, .{});
    try std.testing.expect(!std.mem.eql(u8, lite, try textField(try advanced_run.event("runtime.validation_complete"), "fingerprint")));

    try removeJson(&value, &.{ "renderer", "profile" });
    try f.writeJson(allocator, value);
    var missing_run = Run.init();
    defer missing_run.deinit();
    try f.validate(&missing_run, f.runtime, &.{}, .{ .expected = 3 });
    try expectTextField(try missing_run.event("project.invalid"), "pointer", "/renderer/profile");

    try setJson(allocator, &value, &.{ "renderer", "profile" }, .{ .string = "future" });
    try f.writeJson(allocator, value);
    var future_run = Run.init();
    defer future_run.deinit();
    try f.validate(&future_run, f.runtime, &.{}, .{ .expected = 3 });
    try expectTextField(try future_run.event("project.invalid"), "pointer", "/renderer/profile");
}

test "v2 backends and host policy are not gpu claims" {
    try requirePosix();
    var f = try Fixture.init();
    defer f.deinit();
    var scratch = std.heap.ArenaAllocator.init(a);
    defer scratch.deinit();
    const allocator = scratch.allocator();
    for ([_][]const u8{ "vulkan", "opengl", "d3d11", "d3d12" }) |backend| {
        var value = try f.document(allocator);
        try setJson(allocator, &value, &.{"schema_version"}, .{ .integer = 2 });
        try setJson(allocator, &value, &.{ "engine", "graphics_backend" }, .{ .string = backend });
        try f.writeJson(allocator, value);

        var check_run = Run.init();
        defer check_run.deinit();
        try f.check(&check_run, f.runtime, .{});
        const policy = try check_run.event("application.target_policy");
        try expectStringArray(policy, "authoring_domains", &.{ "scene_3d", "ui_canvas" });
        try expectBoolField(policy, "scene_2d_supported", false);
        try expectBoolField(policy, "renderer_linked", false);
        const unsupported = builtin.os.tag == .linux and std.mem.startsWith(u8, backend, "d3d");
        try expectTextField(policy, "decision", if (unsupported) "backend_not_on_platform" else "allowed");

        var normal_run = Run.init();
        defer normal_run.deinit();
        try f.runApp(&normal_run, f.runtime, &.{ "--project", f.project_path }, .{ .expected = 4 });
        _ = try normal_run.event(if (unsupported) "application.backend_unsupported" else "application.core_unavailable");
    }
}

test "legacy removed backends are inspectable but not executable" {
    try requirePosix();
    var f = try Fixture.init();
    defer f.deinit();
    var scratch = std.heap.ArenaAllocator.init(a);
    defer scratch.deinit();
    const allocator = scratch.allocator();
    for ([_][]const u8{ "metal", "webgpu" }) |backend| {
        var value = try f.document(allocator);
        try setJson(allocator, &value, &.{ "engine", "graphics_backend" }, .{ .string = backend });
        try f.writeJson(allocator, value);
        var policy_run = Run.init();
        defer policy_run.deinit();
        try f.validate(&policy_run, f.runtime, &.{}, .{});
        try expectTextField(try policy_run.event("application.target_policy"), "decision", "backend_out_of_scope");

        var normal_run = Run.init();
        defer normal_run.deinit();
        try f.runApp(&normal_run, f.runtime, &.{ "--project", f.project_path }, .{ .expected = 4 });
        _ = try normal_run.event("application.backend_unsupported");

        var value2 = try f.document(allocator);
        try setJson(allocator, &value2, &.{"schema_version"}, .{ .integer = 2 });
        try setJson(allocator, &value2, &.{ "engine", "graphics_backend" }, .{ .string = backend });
        try f.writeJson(allocator, value2);
        var schema_run = Run.init();
        defer schema_run.deinit();
        try f.validate(&schema_run, f.runtime, &.{}, .{ .expected = 3 });
        try expectTextField(try schema_run.event("project.invalid"), "pointer", "/engine/graphics_backend");
    }
}

test "low medium high and false zero overrides" {
    try requirePosix();
    var f = try Fixture.init();
    defer f.deinit();
    var scratch = std.heap.ArenaAllocator.init(a);
    defer scratch.deinit();
    const allocator = scratch.allocator();
    const cases = [_]struct { preset: []const u8, samples: i64, map_size: i64 }{
        .{ .preset = "low", .samples = 1, .map_size = 512 },
        .{ .preset = "medium", .samples = 2, .map_size = 2048 },
        .{ .preset = "high", .samples = 4, .map_size = 4096 },
    };
    var fingerprints: [3][]const u8 = undefined;
    for (cases, 0..) |case, index| {
        var value = try f.document(allocator);
        try setJson(allocator, &value, &.{ "renderer", "graphics_preset" }, .{ .string = case.preset });
        try f.writeJson(allocator, value);
        var run = Run.init();
        defer run.deinit();
        try f.validate(&run, f.runtime, &.{}, .{});
        const parameters = try field(try run.event("graphics.config_resolved"), "parameters");
        try expectIntField(parameters, "msaa_samples", case.samples);
        try expectIntField(parameters, "shadow_map_size", case.map_size);
        try std.testing.expectEqual(@as(usize, 27), (try objectOf(parameters)).count());
        fingerprints[index] = try allocator.dupe(u8, try textField(try run.event("runtime.validation_complete"), "fingerprint"));
    }
    try std.testing.expect(!std.mem.eql(u8, fingerprints[0], fingerprints[1]));
    try std.testing.expect(!std.mem.eql(u8, fingerprints[1], fingerprints[2]));
    try std.testing.expect(!std.mem.eql(u8, fingerprints[0], fingerprints[2]));

    var overrides: std.json.ObjectMap = .empty;
    try overrides.put(allocator, "shadows_enabled", .{ .bool = false });
    try overrides.put(allocator, "texture_mip_bias", .{ .integer = 0 });
    try overrides.put(allocator, "tone_mapping", .{ .string = "none" });
    try overrides.put(allocator, "msaa_samples", .{ .integer = 1 });
    var value = try f.document(allocator);
    try setJson(allocator, &value, &.{"schema_version"}, .{ .integer = 1 });
    try setJson(allocator, &value, &.{ "renderer", "overrides" }, .{ .object = overrides });
    try f.writeJson(allocator, value);
    var run = Run.init();
    defer run.deinit();
    try f.check(&run, f.runtime, .{});
    const parameters = try field(try run.event("graphics.config_resolved"), "parameters");
    try expectBoolField(parameters, "shadows_enabled", false);
    try expectIntField(parameters, "texture_mip_bias", 0);
    try expectTextField(parameters, "tone_mapping", "none");
    try expectIntField(parameters, "msaa_samples", 1);
}

test "cli help missing unknown duplicate" {
    try requirePosix();
    var f = try Fixture.init();
    defer f.deinit();
    for ([_][]const u8{ f.editor, f.runtime }) |executable| {
        var help_run = Run.init();
        defer help_run.deinit();
        try f.runApp(&help_run, executable, &.{"--help"}, .{});
        _ = try help_run.event("cli.help");

        const cases = [_][]const []const u8{ &.{}, &.{"--headless"}, &.{"--wat"}, &.{"--project"}, &.{ "--headless", "--headless" } };
        for (cases) |arguments| {
            var run = Run.init();
            defer run.deinit();
            try f.runApp(&run, executable, arguments, .{ .expected = 2 });
            _ = try run.event("cli.invalid");
        }
    }
}

test "future missing and string schema version" {
    try requirePosix();
    var f = try Fixture.init();
    defer f.deinit();
    var scratch = std.heap.ArenaAllocator.init(a);
    defer scratch.deinit();
    const allocator = scratch.allocator();
    for ([_][]const u8{ f.editor, f.runtime }) |executable| {
        var future = try f.document(allocator);
        try setJson(allocator, &future, &.{"schema_version"}, .{ .integer = 4 });
        try f.writeJson(allocator, future);
        var future_run = Run.init();
        defer future_run.deinit();
        try f.validate(&future_run, executable, &.{}, .{ .expected = 3 });
        const fields = try future_run.event("project.invalid");
        try expectTextField(fields, "code", "UnsupportedSchemaVersion");
        try expectTextField(fields, "pointer", "/schema_version");

        var string_version = try f.document(allocator);
        try setJson(allocator, &string_version, &.{"schema_version"}, .{ .string = "1" });
        try f.writeJson(allocator, string_version);
        var string_run = Run.init();
        defer string_run.deinit();
        try f.validate(&string_run, executable, &.{}, .{ .expected = 3 });
        const string_fields = try string_run.event("project.invalid");
        try expectTextField(string_fields, "code", "InvalidField");
        try expectTextField(string_fields, "pointer", "/schema_version");

        var missing = try f.document(allocator);
        try removeJson(&missing, &.{"schema_version"});
        try f.writeJson(allocator, missing);
        var missing_run = Run.init();
        defer missing_run.deinit();
        try f.validate(&missing_run, executable, &.{}, .{ .expected = 3 });
        const missing_fields = try missing_run.event("project.invalid");
        try expectTextField(missing_fields, "code", "MissingSchemaVersion");
        try expectTextField(missing_fields, "pointer", "/schema_version");
    }
}

test "duplicate keys and invalid override" {
    try requirePosix();
    var f = try Fixture.init();
    defer f.deinit();
    var scratch = std.heap.ArenaAllocator.init(a);
    defer scratch.deinit();
    const allocator = scratch.allocator();
    try f.writeText("{\"schema_version\":1,\"schema_version\":1}");
    var duplicate_run = Run.init();
    defer duplicate_run.deinit();
    try f.validate(&duplicate_run, f.runtime, &.{}, .{ .expected = 3 });
    try expectTextField(try duplicate_run.event("project.invalid"), "code", "DuplicateField");

    var overrides: std.json.ObjectMap = .empty;
    try overrides.put(allocator, "draw_distance_m", .{ .integer = 1 });
    var value = try f.document(allocator);
    try setJson(allocator, &value, &.{ "renderer", "overrides" }, .{ .object = overrides });
    try f.writeJson(allocator, value);
    var run = Run.init();
    defer run.deinit();
    try f.validate(&run, f.runtime, &.{}, .{ .expected = 3 });
    _ = try run.event("presets.invalid_configuration");
}

test "normal and headless execution fail instead of faking core" {
    try requirePosix();
    var f = try Fixture.init();
    defer f.deinit();
    for ([_][]const u8{ f.editor, f.runtime }) |executable| {
        const variants = [_][]const []const u8{ &.{}, &.{"--headless"} };
        for (variants) |flags| {
            var allocator_state = std.heap.ArenaAllocator.init(a);
            defer allocator_state.deinit();
            const allocator = allocator_state.allocator();
            var arguments: std.ArrayList([]const u8) = .empty;
            try arguments.appendSlice(allocator, &.{ "--project", f.project_path });
            try arguments.appendSlice(allocator, flags);
            var run = Run.init();
            defer run.deinit();
            try f.runApp(&run, executable, arguments.items, .{ .expected = 4 });
            _ = try run.event("application.core_unavailable");
            for (run.roots.items) |root| {
                const event = try textField(root, "event");
                try std.testing.expect(!std.mem.endsWith(u8, event, "validation_complete"));
            }
        }
    }
}

test "headless run executes the core loop without a window or gpu" {
    try requirePosix();
    var f = try Fixture.init();
    defer f.deinit();
    var run = Run.init();
    defer run.deinit();
    try f.runApp(&run, f.runtime, &.{ "--project", f.project_path, "--headless", "--frames", "120" }, .{ .expected = 0 });

    const starting = try run.event("runtime.run_starting");
    try expectIntField(starting, "frames_requested", 120);
    try expectTextField(starting, "scene", "smoke");
    try expectIntField(starting, "tick_hz", 60);
    try expectIntField(starting, "frame_ns", 16_666_667);
    try expectBoolField(starting, "headless", true);
    try expectBoolField(starting, "core_linked", true);
    try expectBoolField(starting, "gpu_created", false);
    try expectBoolField(starting, "window_created", false);
    try expectBoolField(starting, "input_staged", false);

    const complete = try run.event("runtime.run_complete");
    try expectIntField(complete, "frames", 120);
    try expectIntField(complete, "steps", 120);
    try expectIntField(complete, "ticks", 120);
    try expectIntField(complete, "input_ticks", 120);
    try expectIntField(complete, "phase_remainder", 2_400);
    try expectTextField(complete, "scene", "smoke");
    try expectIntField(complete, "entities_alive", 8);
    if (builtin.cpu.arch.endian() == .little) {
        try std.testing.expectEqual(@as(u64, 4676086859710612434), try uintField(complete, "state_checksum"));
    }
    try std.testing.expect((try uintField(complete, "state_checksum")) != 0);
    try expectIntField(complete, "presented_frames", 0);
    try expectBoolField(complete, "play_started", false);
    try expectBoolField(complete, "gpu_created", false);
    try expectBoolField(complete, "core_linked", true);

    // Execution is neither a validation pass nor a renderer claim.
    for (run.roots.items) |root| {
        const event = try textField(root, "event");
        try std.testing.expect(!std.mem.eql(u8, event, "runtime.validation_complete"));
        try std.testing.expect(!std.mem.eql(u8, event, "runtime.ready"));
    }
}

test "headless run reports final entity state in run_complete" {
    try requirePosix();
    var f = try Fixture.init();
    defer f.deinit();
    var run = Run.init();
    defer run.deinit();
    try f.runApp(&run, f.runtime, &.{ "--project", f.project_path, "--headless", "--frames", "120" }, .{ .expected = 0 });
    const complete = try run.event("runtime.run_complete");
    try expectIntField(complete, "entities_alive", 8);
    try std.testing.expect((try uintField(complete, "state_checksum")) != 0);
    // The state proof is additive; it is not a play or renderer claim.
    try expectBoolField(complete, "play_started", false);
    try expectBoolField(complete, "gpu_created", false);
}

test "headless run is deterministic for equal frame counts" {
    try requirePosix();
    var f = try Fixture.init();
    defer f.deinit();
    var first_run = Run.init();
    defer first_run.deinit();
    try f.runApp(&first_run, f.runtime, &.{ "--project", f.project_path, "--headless", "--frames", "60" }, .{ .expected = 0 });
    const first = try first_run.event("runtime.run_complete");

    var second_run = Run.init();
    defer second_run.deinit();
    try f.runApp(&second_run, f.runtime, &.{ "--project", f.project_path, "--headless", "--frames", "60" }, .{ .expected = 0 });
    const second = try second_run.event("runtime.run_complete");

    try expectIntField(second, "entities_alive", try intField(first, "entities_alive"));
    try std.testing.expectEqual(try uintField(first, "state_checksum"), try uintField(second, "state_checksum"));

    var different_run = Run.init();
    defer different_run.deinit();
    try f.runApp(&different_run, f.runtime, &.{ "--project", f.project_path, "--headless", "--frames", "61" }, .{ .expected = 0 });
    const different = try different_run.event("runtime.run_complete");
    try std.testing.expect(try uintField(different, "state_checksum") != try uintField(first, "state_checksum"));
}

test "runtime loads a flat content scene read-only and deterministically" {
    try requirePosix();
    var f = try Fixture.init();
    defer f.deinit();
    const scene_path = try std.fs.path.join(a, &.{ f.directory, "cena.scene" });
    defer a.free(scene_path);
    const scene = "{\"entities\":[{\"components\":[{\"kind\":\"position\",\"x\":1,\"y\":2},{\"kind\":\"velocity\",\"x\":1,\"y\":1}]},{\"components\":[{\"kind\":\"age\",\"ticks\":0}]}]}";
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = scene_path, .data = scene });
    const before = try Io.Dir.cwd().statFile(io, scene_path, .{});

    var first = Run.init();
    defer first.deinit();
    try f.runApp(&first, f.runtime, &.{ "--project", f.project_path, "--headless", "--frames", "60", "--scene", scene_path }, .{ .expected = 0 });
    try expectTextField(try first.event("runtime.run_starting"), "scene", "content");
    const first_complete = try first.event("runtime.run_complete");
    try expectTextField(first_complete, "scene", "content");
    try expectIntField(first_complete, "entities_alive", 2);
    try expectIntField(first_complete, "frames", 60);
    try expectBoolField(first_complete, "gpu_created", false);
    if (builtin.cpu.arch.endian() == .little) {
        try std.testing.expectEqual(@as(u64, 7028052042953051678), try uintField(first_complete, "state_checksum"));
    }

    var second = Run.init();
    defer second.deinit();
    try f.runApp(&second, f.runtime, &.{ "--project", f.project_path, "--headless", "--frames", "60", "--scene", scene_path }, .{ .expected = 0 });
    const second_complete = try second.event("runtime.run_complete");
    try std.testing.expectEqual(try uintField(first_complete, "state_checksum"), try uintField(second_complete, "state_checksum"));
    const after = try Io.Dir.cwd().statFile(io, scene_path, .{});
    try std.testing.expectEqual(before.mtime.nanoseconds, after.mtime.nanoseconds);
    const bytes = try Io.Dir.cwd().readFileAlloc(io, scene_path, a, .limited(4096));
    defer a.free(bytes);
    try std.testing.expectEqualStrings(scene, bytes);
}

test "runtime loads hierarchy read-only and reports its deterministic ordered state" {
    try requirePosix();
    var f = try Fixture.init();
    defer f.deinit();
    const path = try std.fs.path.join(a, &.{ f.directory, "hierarchy.scene" });
    defer a.free(path);
    const source =
        \\{"entities":[{"parent_index":3,"sibling_index":1,"components":[{"kind":"position","x":1},{"kind":"velocity","x":2}]},{"parent_index":3,"sibling_index":0},{"parent_index":0,"components":[{"kind":"age","ticks":2}]},{}]}
    ;
    const reversed =
        \\{"entities":[{"parent_index":3,"sibling_index":0,"components":[{"kind":"position","x":1},{"kind":"velocity","x":2}]},{"parent_index":3,"sibling_index":1},{"parent_index":0,"components":[{"kind":"age","ticks":2}]},{}]}
    ;
    const reparented =
        \\{"entities":[{"parent_index":3,"sibling_index":1,"components":[{"kind":"position","x":1},{"kind":"velocity","x":2}]},{"parent_index":3,"sibling_index":0},{"parent_index":1,"components":[{"kind":"age","ticks":2}]},{}]}
    ;
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = source });
    const before = try Io.Dir.cwd().statFile(io, path, .{});
    var first = Run.init();
    defer first.deinit();
    try f.runApp(&first, f.runtime, &.{ "--project", f.project_path, "--headless", "--frames", "60", "--scene", path }, .{ .expected = 0 });
    const complete = try first.event("runtime.run_complete");
    try expectTextField(complete, "scene", "content");
    try expectIntField(complete, "entities_alive", 4);
    try expectIntField(complete, "ticks", 60);
    try expectBoolField(complete, "gpu_created", false);
    const original_checksum = try uintField(complete, "state_checksum");
    const after = try Io.Dir.cwd().statFile(io, path, .{});
    try std.testing.expectEqual(before.size, after.size);
    try std.testing.expectEqual(before.mtime.nanoseconds, after.mtime.nanoseconds);
    const retained = try Io.Dir.cwd().readFileAlloc(io, path, a, .limited(source.len + 1));
    defer a.free(retained);
    try std.testing.expectEqualStrings(source, retained);

    var repeat = Run.init();
    defer repeat.deinit();
    try f.runApp(&repeat, f.runtime, &.{ "--project", f.project_path, "--headless", "--frames", "60", "--scene", path }, .{ .expected = 0 });
    try std.testing.expectEqual(original_checksum, try uintField(try repeat.event("runtime.run_complete"), "state_checksum"));

    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = reversed });
    var reorder_run = Run.init();
    defer reorder_run.deinit();
    try f.runApp(&reorder_run, f.runtime, &.{ "--project", f.project_path, "--headless", "--frames", "60", "--scene", path }, .{ .expected = 0 });
    try std.testing.expect(original_checksum != try uintField(try reorder_run.event("runtime.run_complete"), "state_checksum"));

    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = reparented });
    var reparent_run = Run.init();
    defer reparent_run.deinit();
    try f.runApp(&reparent_run, f.runtime, &.{ "--project", f.project_path, "--headless", "--frames", "60", "--scene", path }, .{ .expected = 0 });
    try std.testing.expect(original_checksum != try uintField(try reparent_run.event("runtime.run_complete"), "state_checksum"));
}

test "runtime returns structured errors for invalid content hierarchy" {
    try requirePosix();
    var f = try Fixture.init();
    defer f.deinit();
    const path = try std.fs.path.join(a, &.{ f.directory, "invalid_hierarchy.scene" });
    defer a.free(path);
    const cases = [_]struct { json: []const u8, code: []const u8 }{
        .{ .json = "{\"entities\":[{\"parent_index\":1},{\"parent_index\":0}]}", .code = "CycleDetected" },
        .{ .json = "{\"entities\":[{\"parent_index\":9}]}", .code = "InvalidParentIndex" },
        .{ .json = "{\"entities\":[{},{\"parent_index\":0,\"sibling_index\":1}]}", .code = "InvalidSiblingIndex" },
        .{ .json = "{\"entities\":[{\"components\":[{\"kind\":\"parent\"}]}]}", .code = "InvalidHierarchyComponent" },
        .{ .json = "{\"entities\":[{\"components\":[{\"kind\":\"children\"}]}]}", .code = "InvalidHierarchyComponent" },
    };
    for (cases) |case| {
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = case.json });
        var run = Run.init();
        defer run.deinit();
        try f.runApp(&run, f.runtime, &.{ "--project", f.project_path, "--headless", "--frames", "1", "--scene", path }, .{ .expected = 70 });
        try expectTextField(try run.event("runtime.run_failed"), "code", case.code);
        try std.testing.expectEqual(@as(usize, 0), run.countOf("runtime.run_complete"));
        const retained = try Io.Dir.cwd().readFileAlloc(io, path, run.allocator(), .limited(case.json.len + 1));
        try std.testing.expectEqualStrings(case.json, retained);
    }
}

test "runtime reports arithmetic overflow as an error after loading hierarchy" {
    try requirePosix();
    var f = try Fixture.init();
    defer f.deinit();
    const path = try std.fs.path.join(a, &.{ f.directory, "overflow.scene" });
    defer a.free(path);
    const cases = [_]struct { json: []const u8, code: []const u8 }{
        .{ .json = "{\"entities\":[{},{\"parent_index\":0,\"components\":[{\"kind\":\"age\",\"ticks\":18446744073709551615}]}]}", .code = "AgeOverflow" },
        .{ .json = "{\"entities\":[{},{\"parent_index\":0,\"components\":[{\"kind\":\"position\",\"x\":9223372036854775807},{\"kind\":\"velocity\",\"x\":1}]}]}", .code = "PositionOverflow" },
    };
    for (cases) |case| {
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = case.json });
        var run = Run.init();
        defer run.deinit();
        try f.runApp(&run, f.runtime, &.{ "--project", f.project_path, "--headless", "--frames", "1", "--scene", path }, .{ .expected = 70 });
        try expectTextField(try run.event("runtime.run_failed"), "code", case.code);
        try std.testing.expectEqual(@as(usize, 0), run.countOf("runtime.run_complete"));
    }
}

test "execution flags are explicit bounded and rejected otherwise" {
    try requirePosix();
    var f = try Fixture.init();
    defer f.deinit();
    const cases = [_]struct { arguments: []const []const u8, code: []const u8 }{
        .{ .arguments = &.{ "--project", f.project_path, "--frames", "10" }, .code = "InvalidCombination" },
        .{ .arguments = &.{ "--project", f.project_path, "--headless", "--frames", "0" }, .code = "InvalidValue" },
        .{ .arguments = &.{ "--project", f.project_path, "--headless", "--frames", "1000001" }, .code = "InvalidValue" },
        .{ .arguments = &.{ "--project", f.project_path, "--headless", "--frames", "12x" }, .code = "InvalidValue" },
        .{ .arguments = &.{ "--project", f.project_path, "--headless", "--frames" }, .code = "MissingValue" },
        .{ .arguments = &.{ "--project", f.project_path, "--headless", "--validate-only", "--frames", "10" }, .code = "InvalidCombination" },
        .{ .arguments = &.{ "--project", f.project_path, "--headless", "--frames", "1", "--frames", "2" }, .code = "DuplicateArgument" },
    };
    for (cases) |case| {
        var run = Run.init();
        defer run.deinit();
        try f.runApp(&run, f.runtime, case.arguments, .{ .expected = 2 });
        try expectTextField(try run.event("cli.invalid"), "code", case.code);
    }
    // The Editor has no play mode: accepting --frames there would imply one.
    var editor_run = Run.init();
    defer editor_run.deinit();
    try f.runApp(&editor_run, f.editor, &.{ "--project", f.project_path, "--headless", "--frames", "10" }, .{ .expected = 2 });
    try expectTextField(try editor_run.event("cli.invalid"), "code", "InvalidCombination");
}

test "engine identity mismatch" {
    try requirePosix();
    var f = try Fixture.init();
    defer f.deinit();
    var scratch = std.heap.ArenaAllocator.init(a);
    defer scratch.deinit();
    const allocator = scratch.allocator();
    var value = try f.document(allocator);
    try setJson(allocator, &value, &.{ "engine", "version" }, .{ .string = "99.0.0" });
    try f.writeJson(allocator, value);
    var run = Run.init();
    defer run.deinit();
    try f.validate(&run, f.runtime, &.{}, .{ .expected = 4 });
    try expectTextField(try run.event("project.engine_incompatible"), "compatibility", "incompatible");
}

test "missing and oversized project" {
    try requirePosix();
    var f = try Fixture.init();
    defer f.deinit();
    var scratch = std.heap.ArenaAllocator.init(a);
    defer scratch.deinit();
    const buffer = scratch.allocator();
    const missing = try std.mem.concat(buffer, u8, &.{ f.directory, "/missing.proj" });
    var missing_run = Run.init();
    defer missing_run.deinit();
    try f.runApp(&missing_run, f.runtime, &.{ "--project", missing, "--validate-only" }, .{ .expected = 3 });
    _ = try missing_run.event("project.read_failed");

    const oversized = try buffer.alloc(u8, 1024 * 1024 + 1);
    @memset(oversized, ' ');
    try f.writeText(oversized);
    var run = Run.init();
    defer run.deinit();
    try f.validate(&run, f.runtime, &.{}, .{ .expected = 3 });
    var seen = false;
    for (run.roots.items) |root| {
        const event = try textField(root, "event");
        if (std.mem.eql(u8, event, "project.invalid") or std.mem.eql(u8, event, "project.read_failed")) seen = true;
    }
    try std.testing.expect(seen);
}

test "distribution relocation and different cwd" {
    try requirePosix();
    var f = try Fixture.init();
    defer f.deinit();
    var scratch = std.heap.ArenaAllocator.init(a);
    defer scratch.deinit();
    const allocator = scratch.allocator();
    const distribution = try f.copyDistribution(allocator);
    var run = Run.init();
    defer run.deinit();
    try f.validate(&run, distribution.runtime, &.{}, .{ .cwd = .{ .dir = f.project_dir } });
    _ = try run.event("runtime.validation_complete");
}

test "missing resources do not fall back to cwd" {
    try requirePosix();
    var f = try Fixture.init();
    defer f.deinit();
    var scratch = std.heap.ArenaAllocator.init(a);
    defer scratch.deinit();
    const allocator = scratch.allocator();
    const distribution = try f.copyDistribution(allocator);
    const table = try std.fs.path.join(allocator, &.{ distribution.prefix, "share", "corex", "presets.zon" });
    try Io.Dir.deleteFileAbsolute(io, table);
    // A table in the working directory must never be used as a fallback.
    const cwd_table = try std.fs.path.join(allocator, &.{ f.directory, "presets.zon" });
    const example = try Fixture.readRepositoryFile("docs/examples/presets.zon");
    defer a.free(example);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = cwd_table, .data = example });
    var run = Run.init();
    defer run.deinit();
    try f.validate(&run, distribution.runtime, &.{}, .{ .expected = 4, .cwd = .{ .dir = f.project_dir } });
    _ = try run.event("distribution.invalid");
}

test "tampered table and manifest are rejected" {
    try requirePosix();
    var f = try Fixture.init();
    defer f.deinit();
    var scratch = std.heap.ArenaAllocator.init(a);
    defer scratch.deinit();
    const allocator = scratch.allocator();
    const distribution = try f.copyDistribution(allocator);
    const table = try std.fs.path.join(allocator, &.{ distribution.prefix, "share", "corex", "presets.zon" });
    const original = try Io.Dir.cwd().readFileAlloc(io, table, allocator, .limited(1024 * 1024));
    const tampered = try replaceAll(allocator, original, "250.0", "251.0");
    try std.testing.expect(!std.mem.eql(u8, tampered, original));
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = table, .data = tampered });
    var tampered_run = Run.init();
    defer tampered_run.deinit();
    try f.validate(&tampered_run, distribution.runtime, &.{}, .{ .expected = 4 });
    try expectTextField(try tampered_run.event("distribution.invalid"), "code", "DistributionInvalid");

    try Io.Dir.cwd().writeFile(io, .{ .sub_path = table, .data = original });
    const manifest = try std.fs.path.join(allocator, &.{ distribution.prefix, "share", "corex", "distribution.json" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = manifest, .data = "{}\n" });
    var manifest_run = Run.init();
    defer manifest_run.deinit();
    try f.validate(&manifest_run, distribution.runtime, &.{}, .{ .expected = 4 });
    try expectTextField(try manifest_run.event("distribution.manifest_corrupted"), "code", "ManifestCorrupted");
}

test "manifest cannot self authorize an older project version" {
    try requirePosix();
    var f = try Fixture.init();
    defer f.deinit();
    var scratch = std.heap.ArenaAllocator.init(a);
    defer scratch.deinit();
    const allocator = scratch.allocator();
    const distribution = try f.copyDistribution(allocator);
    var value = try f.document(allocator);
    try setJson(allocator, &value, &.{ "engine", "version" }, .{ .string = "0.1.0" });
    try f.writeJson(allocator, value);

    // The real manifest has a valid presets SHA-256 but empty trusted policy.
    var denied_run = Run.init();
    defer denied_run.deinit();
    try f.validate(&denied_run, distribution.runtime, &.{}, .{ .expected = 4 });
    try expectTextField(try denied_run.event("project.engine_incompatible"), "compatibility", "incompatible");

    // A forged declaration of compatibility is rejected as corruption before
    // any authorization or classification can take place.
    const manifest_path = try std.fs.path.join(allocator, &.{ distribution.prefix, "share", "corex", "distribution.json" });
    const bytes = try Io.Dir.cwd().readFileAlloc(io, manifest_path, allocator, .limited(1024 * 1024));
    var manifest = (try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{ .allocate = .alloc_always })).value;
    var versions: std.json.Array = .init(allocator);
    try versions.append(.{ .string = "0.1.0" });
    try setJson(allocator, &manifest, &.{"compatible_project_engine_versions"}, .{ .array = versions });
    const forged = try jsonText(allocator, manifest);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = manifest_path, .data = forged });

    var forged_run = Run.init();
    defer forged_run.deinit();
    try f.validate(&forged_run, distribution.runtime, &.{}, .{ .expected = 4 });
    try expectTextField(try forged_run.event("distribution.manifest_corrupted"), "code", "ManifestCorrupted");
    try std.testing.expectEqual(@as(usize, 0), forged_run.countOf("project.engine_compatibility"));
}

test "missing or relative child is not path searched" {
    try requirePosix();
    var f = try Fixture.init();
    defer f.deinit();
    var scratch = std.heap.ArenaAllocator.init(a);
    defer scratch.deinit();
    const allocator = scratch.allocator();
    const missing = try std.fs.path.join(allocator, &.{ f.directory, "missing runtime" });
    var missing_run = Run.init();
    defer missing_run.deinit();
    try f.check(&missing_run, missing, .{ .expected = 5 });
    _ = try missing_run.event("runtime.check_failed");

    var relative_run = Run.init();
    defer relative_run.deinit();
    try f.check(&relative_run, "CoreXRuntime", .{ .expected = 5 });
    try expectTextField(try relative_run.event("runtime.check_failed"), "code", "AbsolutePathRequired");
}

test "child failure is propagated from real runtime" {
    try requirePosix();
    var f = try Fixture.init();
    defer f.deinit();
    var scratch = std.heap.ArenaAllocator.init(a);
    defer scratch.deinit();
    const allocator = scratch.allocator();
    const distribution = try f.copyDistribution(allocator);
    const manifest = try std.fs.path.join(allocator, &.{ distribution.prefix, "share", "corex", "distribution.json" });
    try Io.Dir.deleteFileAbsolute(io, manifest);
    var run = Run.init();
    defer run.deinit();
    try f.check(&run, distribution.runtime, .{ .expected = 5 });
    try std.testing.expectEqual(@as(i64, 4), try intField(try run.event("runtime.check_failed"), "exit_code"));
    const children = try run.childRoots();
    _ = try findEvent(children, "distribution.invalid");
}

test "exit zero without protocol is not success" {
    try requirePosix();
    var f = try Fixture.init();
    defer f.deinit();
    var run = Run.init();
    defer run.deinit();
    const probe = try f.useProbe(run.allocator(), "silent", "");
    try f.check(&run, probe, .{ .expected = 5 });
    try expectIntField(try run.event("runtime.check_failed"), "matching_completions", 0);
}

test "invalid fragmented and unterminated output is diagnostic" {
    try requirePosix();
    var f = try Fixture.init();
    defer f.deinit();
    var run = Run.init();
    defer run.deinit();
    const probe = try f.useProbe(run.allocator(), "invalid-fragmented", "");
    try f.check(&run, probe, .{ .expected = 5 });
    try std.testing.expectEqual(@as(usize, 3), run.countOf("runtime.output_invalid"));
}

test "wrong fingerprint is not a handshake" {
    try requirePosix();
    var f = try Fixture.init();
    defer f.deinit();
    var run = Run.init();
    defer run.deinit();
    const probe = try f.useProbe(run.allocator(), "wrong-fingerprint", "");
    try f.check(&run, probe, .{ .expected = 5 });
    try expectBoolField(try run.event("runtime.check_failed"), "protocol_mismatch", true);
}

test "session and sequence mismatches" {
    try requirePosix();
    var f = try Fixture.init();
    defer f.deinit();
    for ([_][]const u8{ "session-gap", "sequence-order" }) |mode| {
        var run = Run.init();
        defer run.deinit();
        const probe = try f.useProbe(run.allocator(), mode, "");
        try f.check(&run, probe, .{ .expected = 5 });
        try expectBoolField(try run.event("runtime.check_failed"), "protocol_mismatch", true);
    }
}

test "duplicate sequence across pipes is rejected" {
    try requirePosix();
    var f = try Fixture.init();
    defer f.deinit();
    var run = Run.init();
    defer run.deinit();
    const probe = try f.useProbe(run.allocator(), "duplicate-sequence", "");
    try f.check(&run, probe, .{ .expected = 5 });
    try expectBoolField(try run.event("runtime.check_failed"), "protocol_mismatch", true);
}

test "raw library output does not hide valid runtime confirmation" {
    try requirePosix();
    var f = try Fixture.init();
    defer f.deinit();
    var run = Run.init();
    defer run.deinit();
    const probe = try f.useProbe(run.allocator(), "raw-exec", f.runtime);
    try f.check(&run, probe, .{});
    _ = try run.event("runtime.output_invalid");
    _ = try run.event("runtime.check_complete");
}

test "two pipes are drained without deadlock" {
    try requirePosix();
    var f = try Fixture.init();
    defer f.deinit();
    var run = Run.init();
    defer run.deinit();
    const probe = try f.useProbe(run.allocator(), "two-pipes", "");
    try f.check(&run, probe, .{ .expected = 5 });
    try std.testing.expectEqual(@as(usize, 2), run.countOf("runtime.output_invalid"));
    for (run.roots.items) |root| {
        const event = try textField(root, "event");
        if (!std.mem.eql(u8, event, "runtime.output_invalid")) continue;
        try expectTextField(try field(root, "fields"), "code", "LineTooLong");
    }
}

test "capture overflow kills and reaps child" {
    try requirePosix();
    var f = try Fixture.init();
    defer f.deinit();
    var run = Run.init();
    defer run.deinit();
    const probe = try f.useProbe(run.allocator(), "capture-overflow", "");
    try f.check(&run, probe, .{ .expected = 5 });
    try expectTextField(try run.event("runtime.check_failed"), "code", "StreamTooLong");
    try f.expectReaped(run.allocator());
}

test "deadline reaps term resistant child after early pipe close" {
    try requirePosix();
    var f = try Fixture.init();
    defer f.deinit();
    var run = Run.init();
    defer run.deinit();
    const probe = try f.useProbe(run.allocator(), "term-resistant", "");
    const started = std.Io.Clock.awake.now(io).nanoseconds;
    try f.check(&run, probe, .{ .expected = 5, .timeout_ms = 18_000 });
    const elapsed = std.Io.Clock.awake.now(io).nanoseconds - started;
    try expectTextField(try run.event("runtime.check_failed"), "code", "Timeout");
    try std.testing.expect(elapsed < 15 * std.time.ns_per_s);
    try f.expectReaped(run.allocator());
}

test "invalid line flood has a bounded diagnostic budget" {
    try requirePosix();
    var f = try Fixture.init();
    defer f.deinit();
    var run = Run.init();
    defer run.deinit();
    const probe = try f.useProbe(run.allocator(), "line-flood", "");
    try f.check(&run, probe, .{ .expected = 5, .capture_limit = 8 * 1024 * 1024 });
    try std.testing.expectEqual(@as(usize, 4097), run.countOf("runtime.output_invalid"));
    var last: ?std.json.Value = null;
    for (run.roots.items) |root| {
        const event = try textField(root, "event");
        if (std.mem.eql(u8, event, "runtime.output_invalid")) last = try field(root, "fields");
    }
    try expectTextField(last.?, "code", "RecordBudgetExceeded");
    const failed = try run.event("runtime.check_failed");
    try expectIntField(failed, "discarded_frames", 904);
    try expectBoolField(failed, "protocol_mismatch", true);
}

test "wrapped record overflow is a bounded warning" {
    try requirePosix();
    var f = try Fixture.init();
    defer f.deinit();
    var run = Run.init();
    defer run.deinit();
    const probe = try f.useProbe(run.allocator(), "record-overflow", "");
    try f.check(&run, probe, .{ .expected = 5 });
    const fields = try run.event("log.record_too_large");
    try expectBoolField(fields, "truncated", true);
    try expectTextField(fields, "original_event", "runtime.output");
}

test "broken output pipe returns controlled nonzero status" {
    try requirePosix();
    var f = try Fixture.init();
    defer f.deinit();
    var scratch = std.heap.ArenaAllocator.init(a);
    defer scratch.deinit();
    const allocator = scratch.allocator();
    const result = try runWithClosedStdout(allocator, f.runtime, &.{ "--project", f.project_path, "--validate-only" });
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 74 }, result.term);
    try std.testing.expectEqualStrings("", result.stderr);
}

test "nonzero exit is not silently accepted" {
    try requirePosix();
    var f = try Fixture.init();
    defer f.deinit();
    var run = Run.init();
    defer run.deinit();
    const probe = try f.useProbe(run.allocator(), "nonzero-exit", "");
    try f.check(&run, probe, .{ .expected = 5 });
    try expectIntField(try run.event("runtime.check_failed"), "exit_code", 9);
}

const ClosedStdout = struct { term: std.process.Child.Term, stderr: []u8 };

/// The Runtime must report a controlled status when its own stdout pipe is
/// already closed, instead of dying from an unhandled write failure.
fn runWithClosedStdout(allocator: std.mem.Allocator, executable: []const u8, args: []const []const u8) !ClosedStdout {
    const argv = try allocator.alloc([]const u8, args.len + 1);
    argv[0] = executable;
    @memcpy(argv[1..], args);
    var child = try std.process.spawn(io, .{
        .exe = .{ .explicit = .{ .dir = .cwd(), .path = executable } },
        .argv = argv,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    defer child.kill(io);
    // Closing our read end before the child writes makes the first write fail.
    child.stdout.?.close(io);
    child.stdout = null;
    var buffer: [256]u8 = undefined;
    var reader = child.stderr.?.readerStreaming(io, &buffer);
    const stderr = try reader.interface.allocRemaining(allocator, .limited(4096));
    const term = try child.wait(io);
    return .{ .term = term, .stderr = stderr };
}

/// Same observable contract as the shared supervisor, with a caller-selected
/// bound on each pipe. Used only where the expected application output is
/// intentionally larger than the product limit, never by the applications.
fn captureLarge(allocator: std.mem.Allocator, runtime_io: Io, executable: []const u8, argv: []const []const u8, cwd: Cwd, timeout_ms: u32, limit: usize) !std.process.RunResult {
    const timeout: Io.Timeout = .{ .duration = .{ .raw = .fromMilliseconds(timeout_ms), .clock = .awake } };
    const deadline = timeout.toDeadline(runtime_io);
    var child = try std.process.spawn(runtime_io, .{
        .exe = .{ .explicit = .{ .dir = .cwd(), .path = executable } },
        .argv = argv,
        .cwd = cwd,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    defer child.kill(io);
    var buffer: Io.File.MultiReader.Buffer(2) = undefined;
    var reader: Io.File.MultiReader = undefined;
    reader.init(allocator, runtime_io, buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer reader.deinit();
    while (reader.fill(4096, deadline)) |_| {
        if (reader.reader(0).buffered().len > limit or reader.reader(1).buffered().len > limit) return error.StreamTooLong;
    } else |err| switch (err) {
        error.EndOfStream => {},
        else => return err,
    }
    try reader.checkAnyError();
    const stdout = try reader.toOwnedSlice(0);
    errdefer allocator.free(stdout);
    const stderr = try reader.toOwnedSlice(1);
    const term = try child.wait(runtime_io);
    return .{ .term = term, .stdout = stdout, .stderr = stderr };
}
