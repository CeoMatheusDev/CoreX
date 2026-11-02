//! Single-owner coordination for a future splash, not a GUI or resource loader.
//! Only actual worker results may advance it; tests use synthetic resource events.
const std = @import("std");
const app = @import("corex_app");
const preflight = @import("project_preflight.zig");
const Io = std.Io;

pub const max_resources: usize = 65536;
pub const Phase = enum { document, discovery, resources, initialization, ready, failed, canceled, disposed };

/// Determinate progress counts completed resources, plus one reserved step for
/// real editor initialization. It never reaches 10000 before `ready`.
pub const Snapshot = struct {
    phase: Phase,
    document_stage: ?preflight.Stage = null,
    completed: usize = 0,
    total: ?usize = null,
    basis_points: ?u16 = null,
    failure: ?anyerror = null,
};

pub const Error = error{
    InvalidPhase,
    NotFinished,
    TooManyResources,
    InvalidResource,
    DuplicateCompletion,
};

/// A single owner operates the coordinator; worker threads publish only into
/// preflight's atomic stage. Do not copy it or use it concurrently. The I/O
/// context and thread-safe allocator must outlive it. `cancel`/`deinit` join the
/// preflight worker and may block on OS I/O: a future GUI must arrange cleanup
/// off its event loop rather than assuming cancellation is instantaneous.
pub const Opening = struct {
    allocator: std.mem.Allocator,
    phase: Phase = .document,
    task: ?preflight.Task,
    document: ?app.project.Document = null,
    failure: ?anyerror = null,
    diagnostic: app.project.Diagnostic = .{},
    finished: ?[]bool = null,
    completed: usize = 0,

    pub fn start(a: std.mem.Allocator, io: Io, path: []const u8) !Opening {
        return .{ .allocator = a, .task = try preflight.Task.start(a, io, path) };
    }

    /// Only collects after observing a terminal stage. The worker publishes that
    /// stage just before returning, so await can still briefly block (with no
    /// scheduling deadline). A successful document is owned until deinit.
    pub fn pollDocument(self: *Opening) Error!void {
        if (self.phase != .document) return error.InvalidPhase;
        const task = if (self.task) |*value| value else return error.InvalidPhase;
        const stage = task.stage() orelse return error.InvalidPhase;
        switch (stage) {
            .document_validated, .failed, .canceled => {},
            else => return,
        }
        const result = task.take() catch return error.InvalidPhase;
        self.task = null;
        switch (result) {
            .document => |doc| {
                self.document = doc;
                self.phase = .discovery;
            },
            .failed => |failure| {
                self.failure = failure.code;
                self.diagnostic = failure.diagnostic;
                self.phase = if (failure.code == error.Canceled) .canceled else .failed;
            },
        }
    }

    /// Borrowed until the coordinator is deinitialized; never mutate or retain it.
    pub fn project(self: *const Opening) ?*const app.project.Project {
        if (self.document) |*doc| return &doc.value;
        return null;
    }

    /// Called only after the real resource list has been discovered and frozen.
    /// Counts are tickets for required resources, not bytes or a claim that any
    /// decoding has happened. Zero is valid if real discovery found no work.
    pub fn beginResources(self: *Opening, total: usize) !void {
        if (self.phase != .discovery) return error.InvalidPhase;
        if (total > max_resources) return error.TooManyResources;
        const tickets = try self.allocator.alloc(bool, total);
        @memset(tickets, false);
        self.finished = tickets;
        self.completed = 0;
        self.phase = .resources;
    }

    /// Called once, only after the indexed real required resource is loaded.
    /// Duplicate completion cannot increase progress or accidentally reach ready.
    pub fn resourceLoaded(self: *Opening, index: usize) Error!void {
        if (self.phase != .resources) return error.InvalidPhase;
        const tickets = self.finished.?;
        if (index >= tickets.len) return error.InvalidResource;
        if (tickets[index]) return error.DuplicateCompletion;
        tickets[index] = true;
        self.completed += 1;
    }

    /// The final reserved step starts only after all required resources finish.
    pub fn beginInitialization(self: *Opening) Error!void {
        if (self.phase != .resources) return error.InvalidPhase;
        if (self.completed != self.finished.?.len) return error.NotFinished;
        self.phase = .initialization;
    }

    /// The application must call this only after real editor services and UI
    /// are initialized and usable. No current production code calls it.
    pub fn editorReady(self: *Opening) Error!void {
        if (self.phase != .initialization) return error.InvalidPhase;
        self.phase = .ready;
    }

    /// Called by the owner on a real discovery/load/initialization failure.
    pub fn fail(self: *Opening, reason: anyerror) Error!void {
        switch (self.phase) {
            .discovery, .resources, .initialization => {},
            else => return error.InvalidPhase,
        }
        self.failure = reason;
        self.phase = .failed;
    }

    pub fn snapshot(self: *const Opening) Snapshot {
        return switch (self.phase) {
            .document => .{ .phase = .document, .document_stage = if (self.task) |*task| task.stage() else null },
            .discovery => .{ .phase = .discovery },
            .resources, .initialization => blk: {
                const total = self.finished.?.len;
                const points: u16 = @intCast((@as(u64, @intCast(self.completed)) * 10000) / (@as(u64, @intCast(total)) + 1));
                break :blk .{ .phase = self.phase, .completed = self.completed, .total = total, .basis_points = points };
            },
            .ready => .{ .phase = .ready, .completed = self.completed, .total = self.finished.?.len, .basis_points = 10000 },
            .failed => .{ .phase = .failed, .failure = self.failure },
            .canceled => .{ .phase = .canceled },
            .disposed => .{ .phase = .disposed },
        };
    }

    /// Cooperative cancellation is not a real-time deadline; this joins the
    /// worker before releasing its shared state. Safe to call more than once.
    pub fn cancel(self: *Opening) Error!void {
        switch (self.phase) {
            .ready, .failed, .disposed => return error.InvalidPhase,
            .canceled => return,
            else => {},
        }
        if (self.task) |*task| task.deinit();
        self.task = null;
        self.phase = .canceled;
    }

    pub fn deinit(self: *Opening) void {
        if (self.task) |*task| task.deinit();
        self.task = null;
        if (self.document) |*doc| doc.deinit();
        self.document = null;
        if (self.finished) |tickets| self.allocator.free(tickets);
        self.finished = null;
        self.phase = .disposed;
    }
};

const test_allocator = std.testing.allocator;
const test_io = std.testing.io;

fn samplePath() ![]u8 {
    return std.fs.path.join(test_allocator, &.{ @import("preflight_options").repository_root, "exemploproject", "Example.proj" });
}

fn awaitDocument(opening: *Opening) !void {
    const deadline = Io.Clock.awake.now(test_io).nanoseconds + 5 * std.time.ns_per_s;
    while (opening.phase == .document) {
        try opening.pollDocument();
        if (Io.Clock.awake.now(test_io).nanoseconds >= deadline) return error.WorkerTimeout;
        if (opening.phase == .document) try Io.sleep(test_io, .fromMilliseconds(2), .awake);
    }
}

test "preflight runs concurrently and discovery never claims resource completion" {
    const path = try samplePath();
    defer test_allocator.free(path);
    var opening = try Opening.start(test_allocator, test_io, path);
    defer opening.deinit();
    const initial = opening.snapshot();
    try std.testing.expectEqual(Phase.document, initial.phase);
    try std.testing.expect(initial.basis_points == null and initial.total == null);
    try std.testing.expectError(error.InvalidPhase, opening.beginResources(1));
    try std.testing.expectError(error.InvalidPhase, opening.editorReady());
    try awaitDocument(&opening);
    try std.testing.expectEqual(Phase.discovery, opening.phase);
    try std.testing.expectEqualStrings("Example Project", opening.project().?.project.name);
    try std.testing.expect(opening.snapshot().basis_points == null);
}

test "frozen resource tickets are monotonic and reserve actual editor initialization" {
    const path = try samplePath();
    defer test_allocator.free(path);
    var opening = try Opening.start(test_allocator, test_io, path);
    defer opening.deinit();
    try awaitDocument(&opening);
    try std.testing.expectError(error.TooManyResources, opening.beginResources(max_resources + 1));
    try std.testing.expectEqual(Phase.discovery, opening.phase);
    try opening.beginResources(3);
    try std.testing.expectError(error.InvalidPhase, opening.beginResources(4));
    try std.testing.expectEqual(@as(?u16, 0), opening.snapshot().basis_points);
    try std.testing.expectError(error.NotFinished, opening.beginInitialization());
    try opening.resourceLoaded(2);
    try std.testing.expectEqual(@as(?u16, 2500), opening.snapshot().basis_points);
    try std.testing.expectError(error.DuplicateCompletion, opening.resourceLoaded(2));
    try std.testing.expectError(error.InvalidResource, opening.resourceLoaded(3));
    try std.testing.expectEqual(@as(?u16, 2500), opening.snapshot().basis_points);
    try opening.resourceLoaded(0);
    try opening.resourceLoaded(1);
    try std.testing.expectEqual(@as(?u16, 7500), opening.snapshot().basis_points);
    try opening.beginInitialization();
    try std.testing.expectEqual(@as(?u16, 7500), opening.snapshot().basis_points);
    try std.testing.expectError(error.InvalidPhase, opening.resourceLoaded(0));
    try opening.editorReady(); // synthetic event; no actual Editor is started
    try std.testing.expectEqual(@as(?u16, 10000), opening.snapshot().basis_points);
    try std.testing.expectError(error.InvalidPhase, opening.cancel());
}

test "zero discovered resources still requires real initialization" {
    const path = try samplePath();
    defer test_allocator.free(path);
    var opening = try Opening.start(test_allocator, test_io, path);
    defer opening.deinit();
    try awaitDocument(&opening);
    try opening.beginResources(0); // synthetic test; not discovery of example files
    try std.testing.expectEqual(@as(?u16, 0), opening.snapshot().basis_points);
    try opening.beginInitialization();
    try std.testing.expectEqual(@as(?u16, 0), opening.snapshot().basis_points);
    try opening.editorReady();
    try std.testing.expectEqual(@as(?u16, 10000), opening.snapshot().basis_points);
}

test "failure and cancellation cannot silently become success" {
    const path = try samplePath();
    defer test_allocator.free(path);
    var canceled = try Opening.start(test_allocator, test_io, path);
    defer canceled.deinit();
    try canceled.cancel();
    try canceled.cancel();
    try std.testing.expectEqual(Phase.canceled, canceled.snapshot().phase);
    try std.testing.expect(canceled.snapshot().basis_points == null);
    try std.testing.expectError(error.InvalidPhase, canceled.beginResources(0));
    var failed = try Opening.start(test_allocator, test_io, path);
    defer failed.deinit();
    try awaitDocument(&failed);
    try failed.beginResources(2);
    try failed.resourceLoaded(0);
    try failed.fail(error.ResourceMissing);
    const state = failed.snapshot();
    try std.testing.expectEqual(Phase.failed, state.phase);
    try std.testing.expectEqual(error.ResourceMissing, state.failure.?);
    try std.testing.expect(state.basis_points == null);
    try std.testing.expectError(error.InvalidPhase, failed.editorReady());
    try std.testing.expectError(error.InvalidPhase, failed.cancel());
}

test "missing project reports its actual error and never discovers resources" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(test_io, &buf);
    const path = try std.fs.path.join(test_allocator, &.{ buf[0..n], "missing.proj" });
    defer test_allocator.free(path);
    var opening = try Opening.start(test_allocator, test_io, path);
    defer opening.deinit();
    try awaitDocument(&opening);
    try std.testing.expectEqual(Phase.failed, opening.phase);
    try std.testing.expectEqual(error.FileNotFound, opening.snapshot().failure.?);
    try std.testing.expect(opening.project() == null);
    try std.testing.expectError(error.InvalidPhase, opening.beginResources(0));
}

test "allocation failure and maximum resource count preserve invariants" {
    const path = try samplePath();
    defer test_allocator.free(path);
    var opening = try Opening.start(test_allocator, test_io, path);
    defer opening.deinit();
    try awaitDocument(&opening);
    opening.allocator = std.testing.failing_allocator;
    try std.testing.expectError(error.OutOfMemory, opening.beginResources(3));
    opening.allocator = test_allocator;
    try std.testing.expectEqual(Phase.discovery, opening.phase);
    try opening.beginResources(max_resources);
    for (0..max_resources) |i| try opening.resourceLoaded(i);
    try std.testing.expectEqual(@as(?u16, 9999), opening.snapshot().basis_points);
    try opening.beginInitialization();
    try std.testing.expectEqual(@as(?u16, 9999), opening.snapshot().basis_points);
    try opening.editorReady();
    try std.testing.expectEqual(@as(?u16, 10000), opening.snapshot().basis_points);
}

test "deinitialization is idempotent and exposes no stale document or progress" {
    const path = try samplePath();
    defer test_allocator.free(path);
    var opening = try Opening.start(test_allocator, test_io, path);
    try awaitDocument(&opening);
    try opening.beginResources(1);
    opening.deinit();
    opening.deinit();
    try std.testing.expectEqual(Phase.disposed, opening.snapshot().phase);
    try std.testing.expect(opening.project() == null);
    try std.testing.expectError(error.InvalidPhase, opening.cancel());
    try std.testing.expectError(error.InvalidPhase, opening.resourceLoaded(0));
}
