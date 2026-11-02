//! Asynchronous document preflight for a future Editor splash.
//! This is not a resource loader, graphical splash, or ready-to-edit signal.
const std = @import("std");
const app = @import("corex_app");
const Io = std.Io;

pub const splash_width: u32 = 800;
pub const splash_height: u32 = 600;

pub const Stage = enum(u8) {
    queued,
    resolving_path,
    reading_document,
    validating_document,
    document_validated,
    failed,
    canceled,
};
pub const Failure = struct { code: anyerror, diagnostic: app.project.Diagnostic };
pub const Result = union(enum) {
    /// Caller owns this document and must call its deinit exactly once.
    document: app.project.Document,
    failed: Failure,
};
const Shared = struct {
    allocator: std.mem.Allocator,
    io: Io,
    path: []u8,
    stage: std.atomic.Value(Stage) = .init(.queued),
    diagnostic: app.project.Diagnostic = .{},
};

fn load(shared: *Shared) !app.project.Document {
    const a = shared.allocator;
    const io = shared.io;
    shared.stage.store(.resolving_path, .release);
    const path = try Io.Dir.cwd().realPathFileAlloc(io, shared.path, a);
    defer a.free(path);
    if (!std.unicode.utf8ValidateSlice(path)) return error.UnsupportedProjectPathEncoding;
    shared.stage.store(.reading_document, .release);
    const bytes = try Io.Dir.cwd().readFileAlloc(io, path, a, .limited(1024 * 1024 + 1));
    defer a.free(bytes);
    shared.stage.store(.validating_document, .release);
    return app.project.parse(a, bytes, &shared.diagnostic);
}

fn worker(shared: *Shared) Result {
    const document = load(shared) catch |err| {
        const failure: Failure = .{ .code = err, .diagnostic = shared.diagnostic };
        shared.stage.store(if (err == error.Canceled) .canceled else .failed, .release);
        return .{ .failed = failure };
    };
    shared.stage.store(.document_validated, .release);
    return .{ .document = document };
}

/// Single-owner task; `stage` may be polled across threads only while the owner
/// keeps the task alive (no concurrent `take` or `deinit`). Do not copy a Task.
/// `io` and a thread-safe allocator must outlive it. `take` transfers document ownership;
/// `deinit` cancels/joins and destroys any unclaimed result. Progress is only
/// about the project document, never proof that scene/assets/UI are loaded.
pub const Task = struct {
    shared: ?*Shared,
    future: ?Io.Future(Result),

    pub fn start(a: std.mem.Allocator, io: Io, path: []const u8) !Task {
        try app.cli.validatePath(path);
        const shared = try a.create(Shared);
        errdefer a.destroy(shared);
        const owned_path = try a.dupe(u8, path);
        errdefer a.free(owned_path);
        shared.* = .{ .allocator = a, .io = io, .path = owned_path };
        const future = try Io.concurrent(io, worker, .{shared});
        return .{ .shared = shared, .future = future };
    }

    pub fn stage(self: *const Task) ?Stage {
        const shared = self.shared orelse return null;
        return shared.stage.load(.acquire);
    }

    fn releaseShared(self: *Task) void {
        const shared = self.shared orelse return;
        const a = shared.allocator;
        a.free(shared.path);
        a.destroy(shared);
        self.shared = null;
    }

    /// Await exactly once, moving the result to the caller.
    pub fn take(self: *Task) error{TaskConsumed}!Result {
        var future = self.future orelse return error.TaskConsumed;
        self.future = null;
        const result = future.await(self.shared.?.io);
        self.releaseShared();
        return result;
    }

    /// Cancellation is cooperative at Zig I/O cancellation points and may not
    /// interrupt parsing immediately. Waits for the worker before freeing data.
    pub fn deinit(self: *Task) void {
        if (self.future) |*future| {
            const result = future.cancel(self.shared.?.io);
            switch (result) {
                .document => |doc| {
                    var owned = doc;
                    owned.deinit();
                },
                .failed => {},
            }
            self.future = null;
        }
        self.releaseShared();
    }
};

const test_allocator = std.testing.allocator;
const test_io = std.testing.io;

fn samplePath() ![]u8 {
    return std.fs.path.join(test_allocator, &.{ @import("preflight_options").repository_root, "exemploproject", "Example.proj" });
}

fn waitUntilTerminal(task: *const Task) !Stage {
    const deadline = Io.Clock.awake.now(test_io).nanoseconds + 5 * std.time.ns_per_s;
    while (true) {
        const current = task.stage() orelse return error.TaskConsumed;
        switch (current) {
            .document_validated, .failed, .canceled => return current,
            else => {},
        }
        if (Io.Clock.awake.now(test_io).nanoseconds >= deadline) return error.WorkerTimeout;
        try Io.sleep(test_io, .fromMilliseconds(2), .awake);
    }
}

test "actual project preflight completes asynchronously without claiming resources" {
    const sample_path = try samplePath();
    defer test_allocator.free(sample_path);
    const sample = try Io.Dir.cwd().readFileAlloc(test_io, sample_path, test_allocator, .limited(1024 * 1024));
    defer test_allocator.free(sample);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(test_io, .{ .sub_path = "My Game.proj", .data = sample });
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(test_io, &buf);
    const path = try std.fs.path.join(test_allocator, &.{ buf[0..n], "My Game.proj" });
    defer test_allocator.free(path);
    var task = try Task.start(test_allocator, test_io, path);
    defer task.deinit();
    // The task owns a copy; mutating the caller's buffer cannot change the path.
    path[path.len - 1] = 'X';
    // No await is called here: the concurrent worker must make real progress.
    try std.testing.expectEqual(Stage.document_validated, try waitUntilTerminal(&task));
    const result = try task.take();
    switch (result) {
        .document => |document| {
            var owned = document;
            defer owned.deinit();
            try std.testing.expectEqualStrings("Example Project", owned.value.project.name);
            try std.testing.expectEqual(@as(u32, 2), owned.value.schema_version);
        },
        .failed => return error.UnexpectedWorkerFailure,
    }
    try std.testing.expect(task.stage() == null);
    try std.testing.expectError(error.TaskConsumed, task.take());
}

test "missing and invalid documents fail asynchronously" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(test_io, &buf);
    const path = try std.fs.path.join(test_allocator, &.{ buf[0..n], "invalid.proj" });
    defer test_allocator.free(path);
    var missing = try Task.start(test_allocator, test_io, path);
    defer missing.deinit();
    try std.testing.expectEqual(Stage.failed, try waitUntilTerminal(&missing));
    const no_file = try missing.take();
    switch (no_file) {
        .failed => |failure| try std.testing.expectEqual(error.FileNotFound, failure.code),
        .document => |doc| {
            var owned = doc;
            owned.deinit();
            return error.ExpectedFailure;
        },
    }
    try tmp.dir.writeFile(test_io, .{ .sub_path = "invalid.proj", .data = "{invalid" });
    var invalid = try Task.start(test_allocator, test_io, path);
    defer invalid.deinit();
    try std.testing.expectEqual(Stage.failed, try waitUntilTerminal(&invalid));
    const bad = try invalid.take();
    switch (bad) {
        .failed => |failure| try std.testing.expectEqual(error.InvalidJson, failure.code),
        .document => |doc| {
            var owned = doc;
            owned.deinit();
            return error.ExpectedFailure;
        },
    }
}

test "cancel joins and releases unclaimed results" {
    const sample_path = try samplePath();
    defer test_allocator.free(sample_path);
    for (0..8) |_| {
        var task = try Task.start(test_allocator, test_io, sample_path);
        task.deinit();
        task.deinit();
        try std.testing.expect(task.stage() == null);
        try std.testing.expectError(error.TaskConsumed, task.take());
    }
}

test "oversized project fails without claiming completion" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const bytes = try test_allocator.alloc(u8, 1024 * 1024 + 2);
    defer test_allocator.free(bytes);
    @memset(bytes, 'x');
    try tmp.dir.writeFile(test_io, .{ .sub_path = "large.proj", .data = bytes });
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(test_io, &buf);
    const path = try std.fs.path.join(test_allocator, &.{ buf[0..n], "large.proj" });
    defer test_allocator.free(path);
    var task = try Task.start(test_allocator, test_io, path);
    defer task.deinit();
    try std.testing.expectEqual(Stage.failed, try waitUntilTerminal(&task));
    const result = try task.take();
    switch (result) {
        .failed => |failure| try std.testing.expectEqual(error.StreamTooLong, failure.code),
        .document => |document| {
            var owned = document;
            owned.deinit();
            return error.ExpectedFailure;
        },
    }
}

test "task setup rejects invalid paths and propagates allocator failure" {
    try std.testing.expectError(error.InvalidPathArgument, Task.start(test_allocator, test_io, ""));
    try std.testing.expectError(error.InvalidPathArgument, Task.start(test_allocator, test_io, "bad\n.proj"));
    try std.testing.expectError(error.OutOfMemory, Task.start(std.testing.failing_allocator, test_io, "not-created.proj"));
    var second_allocation_fails = std.testing.FailingAllocator.init(test_allocator, .{ .fail_index = 1 });
    try std.testing.expectError(error.OutOfMemory, Task.start(second_allocation_fails.allocator(), test_io, "not-created.proj"));
}

test "independent tasks complete and release independently" {
    var tasks: [3]?Task = .{ null, null, null };
    defer for (&tasks) |*slot| {
        if (slot.*) |*task| task.deinit();
    };
    const sample_path = try samplePath();
    defer test_allocator.free(sample_path);
    for (&tasks) |*slot| slot.* = try Task.start(test_allocator, test_io, sample_path);
    for (&tasks) |*slot| {
        const task = &slot.*.?;
        try std.testing.expectEqual(Stage.document_validated, try waitUntilTerminal(task));
        const result = try task.take();
        switch (result) {
            .document => |document| {
                var owned = document;
                defer owned.deinit();
                try std.testing.expectEqualStrings("Example Project", owned.value.project.name);
            },
            .failed => return error.UnexpectedWorkerFailure,
        }
    }
    try std.testing.expectEqual(@as(u32, 800), splash_width);
    try std.testing.expectEqual(@as(u32, 600), splash_height);
}
