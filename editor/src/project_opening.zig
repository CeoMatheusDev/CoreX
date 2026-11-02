//! Single-owner coordination for a future splash, not a GUI or resource loader.
//! Only actual worker results may advance it; tests use synthetic resource events.
//! Real filesystem discovery is provided by `resource_discovery.zig` and is
//! started by `startDiscovery` once the document is validated.
const std = @import("std");
const app = @import("corex_app");
const preflight = @import("project_preflight.zig");
const discovery_mod = @import("resource_discovery.zig");
const Io = std.Io;

pub const max_resources: usize = 65536;
pub const Phase = enum { document, discovery, resources, initialization, ready, failed, canceled, disposed };

/// Determinate progress counts completed resources, plus one reserved step for
/// real editor initialization. It never reaches 10000 before `ready`.
pub const Snapshot = struct {
    phase: Phase,
    document_stage: ?preflight.Stage = null,
    discovery_stage: ?discovery_mod.Stage = null,
    asset_read_stage: ?discovery_mod.AssetReadStage = null,
    asset_read_failure: ?anyerror = null,
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
    AssetInventoryUnavailable,
    AssetReadActive,
    AssetReadUnavailable,
};

pub const AssetOpenError = discovery_mod.AssetOpenError || error{AssetInventoryUnavailable};
pub const ResourceOpenError = discovery_mod.ResourceOpenError || error{AssetInventoryUnavailable};

/// A single owner operates the coordinator; worker threads publish only into
/// preflight's atomic stage. Do not copy it or use it concurrently. The I/O
/// context and thread-safe allocator must outlive it. `cancel`/`deinit` join the
/// preflight worker and may block on OS I/O: a future GUI must arrange cleanup
/// off its event loop rather than assuming cancellation is instantaneous.
pub const Opening = struct {
    allocator: std.mem.Allocator,
    io: Io,
    phase: Phase = .document,
    task: ?preflight.Task,
    project_path: ?[]u8 = null,
    document: ?app.project.Document = null,
    discovery_task: ?discovery_mod.Task = null,
    discovery: ?discovery_mod.Discovery = null,
    asset_read_task: ?discovery_mod.AssetReadTask = null,
    asset_read_failure: ?anyerror = null,
    failure: ?anyerror = null,
    diagnostic: app.project.Diagnostic = .{},
    finished: ?[]bool = null,
    completed: usize = 0,

    pub fn start(a: std.mem.Allocator, io: Io, path: []const u8) !Opening {
        const owned = try a.dupe(u8, path);
        errdefer a.free(owned);
        return .{
            .allocator = a,
            .io = io,
            .project_path = owned,
            .task = try preflight.Task.start(a, io, path),
        };
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

    /// Start filesystem discovery without blocking the owner thread. The task
    /// borrows the immutable project document until `pollDiscovery` collects it
    /// or `deinit` joins/cancels it.
    pub fn startDiscovery(self: *Opening) !void {
        if (self.phase != .discovery or self.discovery_task != null or self.discovery != null) return error.InvalidPhase;
        const doc = if (self.document) |*d| d.value else return error.InvalidPhase;
        const proj_path = self.project_path orelse return error.InvalidPhase;
        self.discovery_task = try discovery_mod.Task.start(self.allocator, self.io, proj_path, doc);
    }

    /// Non-blocking poll until a terminal worker stage is observed. Collection
    /// may briefly wait for the worker to return after publishing that stage.
    /// On success, freezes progress tickets from the real discovery result.
    pub fn pollDiscovery(self: *Opening) !void {
        if (self.phase != .discovery) return error.InvalidPhase;
        const task = if (self.discovery_task) |*value| value else return error.InvalidPhase;
        const stage = task.stage() orelse return error.InvalidPhase;
        switch (stage) {
            .complete, .failed, .canceled => {},
            .queued, .resolving_project, .checking_resources => return,
        }
        const result = try task.take();
        self.discovery_task = null;
        switch (result) {
            .discovery => |discovery| {
                // Allocate/freeze tickets before transferring the discovery. On
                // OOM, dispose it and leave the phase retryable at discovery.
                self.beginResources(discovery.resources.len) catch |err| {
                    var owned = discovery;
                    owned.deinit();
                    return err;
                };
                self.discovery = discovery;
            },
            .failed => |failure| {
                self.failure = failure.code;
                self.diagnostic = failure.diagnostic;
                self.phase = if (failure.code == error.Canceled) .canceled else .failed;
            },
        }
    }

    /// Access discovered resources after `pollDiscovery` succeeds. Borrowed.
    pub fn discovered(self: *const Opening) ?[]const discovery_mod.Resource {
        if (self.discovery) |*d| return d.resources;
        return null;
    }

    /// Borrowed metadata index for a future content browser; does not imply
    /// that any listed asset has been opened or decoded.
    pub fn assetInventory(self: *const Opening) ?[]const discovery_mod.AssetEntry {
        if (self.discovery) |*d| return d.asset_files;
        return null;
    }

    /// Borrowed directory metadata for hierarchical content-browser navigation.
    pub fn assetDirectoryInventory(self: *const Opening) ?[]const discovery_mod.AssetDirectory {
        if (self.discovery) |*d| return d.asset_directories;
        return null;
    }

    /// Allocation-free immediate-child iteration for the indexed asset tree.
    pub fn assetChildren(self: *const Opening, relative_dir: []const u8) ?discovery_mod.AssetChildrenIterator {
        if (self.discovery) |*d| return d.assetChildren(relative_dir);
        return null;
    }

    /// Open an indexed asset through no-follow directory handles. Caller owns the file handle.
    pub fn openAsset(self: *const Opening, relative: []const u8) AssetOpenError!Io.File {
        const discovered_snapshot = if (self.discovery) |*d| d else return error.AssetInventoryUnavailable;
        return discovered_snapshot.openAsset(self.io, relative);
    }

    /// Open an existing project resource (startup scene, Lua entry or library)
    /// via no-follow directory handles. Caller owns the returned file handle.
    pub fn openResourceFile(self: *const Opening, kind: discovery_mod.ResourceKind) ResourceOpenError!Io.File {
        const discovered_snapshot = if (self.discovery) |*d| d else return error.AssetInventoryUnavailable;
        return discovered_snapshot.openResourceFile(self.io, kind);
    }

    /// Read opaque bytes from an indexed asset under the caller's hard limit.
    pub fn readAssetAlloc(self: *const Opening, allocator: std.mem.Allocator, relative: []const u8, max_bytes: usize) ![]u8 {
        const discovered_snapshot = if (self.discovery) |*d| d else return error.AssetInventoryUnavailable;
        return discovered_snapshot.readAssetAlloc(allocator, self.io, relative, max_bytes);
    }

    pub fn readResourceAlloc(self: *const Opening, allocator: std.mem.Allocator, kind: discovery_mod.ResourceKind, max_bytes: usize) ![]u8 {
        const discovered_snapshot = if (self.discovery) |*d| d else return error.AssetInventoryUnavailable;
        return discovered_snapshot.readResourceAlloc(allocator, self.io, kind, max_bytes);
    }

    /// Start one bounded asset read tied to this coordinator's discovery
    /// lifetime. Only one read may be active; its result is not a progress ticket.
    pub fn startAssetRead(self: *Opening, relative: []const u8, max_bytes: usize) !void {
        switch (self.phase) {
            .resources, .ready => {},
            else => return error.InvalidPhase,
        }
        if (self.asset_read_task != null) return error.AssetReadActive;
        const discovered_snapshot = if (self.discovery) |*d| d else return error.AssetInventoryUnavailable;
        self.asset_read_failure = null;
        self.asset_read_task = try discovery_mod.AssetReadTask.start(self.allocator, self.io, discovered_snapshot, relative, max_bytes);
    }

    pub fn assetReadStage(self: *const Opening) ?discovery_mod.AssetReadStage {
        if (self.asset_read_task) |*task| return task.stage();
        return null;
    }

    /// Collect only after a terminal stage; on success caller owns the bytes and
    /// must free them with the Opening allocator. Failed results contain an error.
    pub fn takeAssetRead(self: *Opening) Error!discovery_mod.AssetReadResult {
        const task = if (self.asset_read_task) |*value| value else return error.AssetReadUnavailable;
        const stage = task.stage() orelse return error.AssetReadUnavailable;
        switch (stage) {
            .complete, .failed, .canceled => {},
            .queued, .reading => return error.NotFinished,
        }
        const result = task.take() catch return error.InvalidPhase;
        self.asset_read_task = null;
        self.asset_read_failure = switch (result) {
            .bytes => null,
            .failed => |failure| failure,
        };
        return result;
    }

    /// Cancel/reap the owned read before dropping its Discovery borrow; may block on I/O.
    pub fn cancelAssetRead(self: *Opening) Error!void {
        if (self.asset_read_task) |*task| {
            task.deinit();
            self.asset_read_task = null;
            return;
        }
        return error.AssetReadUnavailable;
    }

    /// Validate cached file metadata through the retained discovery snapshot.
    pub fn verifyAssetSnapshot(self: *const Opening, relative: []const u8) !void {
        const discovered_snapshot = if (self.discovery) |*d| d else return error.AssetInventoryUnavailable;
        try discovered_snapshot.verifyAssetSnapshot(self.allocator, self.io, relative);
    }

    /// Validate that an indexed directory still resolves to the discovered object.
    pub fn verifyAssetDirectorySnapshot(self: *const Opening, relative: []const u8) !void {
        const discovered_snapshot = if (self.discovery) |*d| d else return error.AssetInventoryUnavailable;
        try discovered_snapshot.verifyAssetDirectorySnapshot(self.allocator, self.io, relative);
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
        if (self.asset_read_task != null) return error.AssetReadActive;
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
    /// Cancel and join active discovery/asset-read workers before publishing the
    /// terminal phase so none outlive the failed opening. This may block on I/O;
    /// a future UI must perform it off the event loop.
    pub fn fail(self: *Opening, reason: anyerror) Error!void {
        switch (self.phase) {
            .discovery, .resources, .initialization => {},
            else => return error.InvalidPhase,
        }
        if (self.asset_read_task) |*task| task.deinit();
        self.asset_read_task = null;
        if (self.discovery_task) |*task| task.deinit();
        self.discovery_task = null;
        self.failure = reason;
        self.phase = .failed;
    }

    pub fn snapshot(self: *const Opening) Snapshot {
        return switch (self.phase) {
            .document => .{ .phase = .document, .document_stage = if (self.task) |*task| task.stage() else null },
            .discovery => .{ .phase = .discovery, .discovery_stage = if (self.discovery_task) |*task| task.stage() else null },
            .resources, .initialization => blk: {
                const total = self.finished.?.len;
                const points: u16 = @intCast((@as(u64, @intCast(self.completed)) * 10000) / (@as(u64, @intCast(total)) + 1));
                break :blk .{ .phase = self.phase, .asset_read_stage = if (self.asset_read_task) |*task| task.stage() else null, .asset_read_failure = self.asset_read_failure, .completed = self.completed, .total = total, .basis_points = points };
            },
            .ready => .{ .phase = .ready, .asset_read_stage = if (self.asset_read_task) |*task| task.stage() else null, .asset_read_failure = self.asset_read_failure, .completed = self.completed, .total = self.finished.?.len, .basis_points = 10000 },
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
        if (self.asset_read_task) |*task| task.deinit();
        self.asset_read_task = null;
        if (self.discovery_task) |*task| task.deinit();
        self.discovery_task = null;
        self.phase = .canceled;
    }

    pub fn deinit(self: *Opening) void {
        if (self.task) |*task| task.deinit();
        self.task = null;
        if (self.asset_read_task) |*task| task.deinit();
        self.asset_read_task = null;
        if (self.discovery_task) |*task| task.deinit();
        self.discovery_task = null;
        if (self.document) |*doc| doc.deinit();
        self.document = null;
        if (self.discovery) |*dis| dis.deinit();
        self.discovery = null;
        if (self.project_path) |p| self.allocator.free(p);
        self.project_path = null;
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

fn awaitDiscovery(opening: *Opening) !void {
    const deadline = Io.Clock.awake.now(test_io).nanoseconds + 5 * std.time.ns_per_s;
    while (opening.phase == .discovery and opening.discovery_task != null) {
        try opening.pollDiscovery();
        if (Io.Clock.awake.now(test_io).nanoseconds >= deadline) return error.WorkerTimeout;
        if (opening.phase == .discovery) try Io.sleep(test_io, .fromMilliseconds(2), .awake);
    }
}

fn awaitAssetRead(opening: *const Opening) !discovery_mod.AssetReadStage {
    const deadline = Io.Clock.awake.now(test_io).nanoseconds + 5 * std.time.ns_per_s;
    while (true) {
        const stage = opening.assetReadStage() orelse return error.AssetReadUnavailable;
        switch (stage) {
            .complete, .failed, .canceled => return stage,
            .queued, .reading => {},
        }
        if (Io.Clock.awake.now(test_io).nanoseconds >= deadline) return error.WorkerTimeout;
        try Io.sleep(test_io, .fromMilliseconds(2), .awake);
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
    var canceled_discovery = try Opening.start(test_allocator, test_io, path);
    defer canceled_discovery.deinit();
    try awaitDocument(&canceled_discovery);
    try canceled_discovery.startDiscovery();
    try canceled_discovery.cancel();
    try std.testing.expectEqual(Phase.canceled, canceled_discovery.snapshot().phase);
    try std.testing.expect(canceled_discovery.discovery_task == null);

    var failed_discovery = try Opening.start(test_allocator, test_io, path);
    defer failed_discovery.deinit();
    try awaitDocument(&failed_discovery);
    try failed_discovery.startDiscovery();
    try failed_discovery.fail(error.ExternalFailure);
    try std.testing.expectEqual(Phase.failed, failed_discovery.snapshot().phase);
    try std.testing.expectEqual(error.ExternalFailure, failed_discovery.snapshot().failure.?);
    try std.testing.expect(failed_discovery.discovery_task == null);

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

test "asynchronous filesystem discovery freezes real resources before tickets" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // Replicate exemploproject layout inside tmp
    for ([_][]const u8{ "scenes", "assets", "scripts/cpp", "scripts/lua" }) |dir| {
        try tmp.dir.createDirPath(test_io, dir);
    }
    try tmp.dir.createDirPath(test_io, "assets/nested");
    try tmp.dir.writeFile(test_io, .{ .sub_path = "scenes/Main.scene", .data = "scene placeholder" });
    try tmp.dir.writeFile(test_io, .{ .sub_path = "assets/readme.txt", .data = "indexed only" });
    const example_path = try samplePath();
    defer test_allocator.free(example_path);
    const bytes = try Io.Dir.cwd().readFileAlloc(test_io, example_path, test_allocator, .limited(1024 * 1024));
    defer test_allocator.free(bytes);
    // Write copy to tmp/Real.proj
    try tmp.dir.writeFile(test_io, .{ .sub_path = "Real.proj", .data = bytes });
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(test_io, &buf);
    const proj_path = try std.fs.path.join(test_allocator, &.{ buf[0..n], "Real.proj" });
    defer test_allocator.free(proj_path);

    var opening = try Opening.start(test_allocator, test_io, proj_path);
    defer opening.deinit();
    try awaitDocument(&opening);
    try std.testing.expectEqual(Phase.discovery, opening.phase);
    try std.testing.expectError(error.AssetInventoryUnavailable, opening.verifyAssetSnapshot("assets/readme.txt"));
    try std.testing.expectError(error.AssetInventoryUnavailable, opening.openAsset("assets/readme.txt"));
    try opening.startDiscovery();
    try std.testing.expect(opening.snapshot().discovery_stage != null);
    try awaitDiscovery(&opening);
    try std.testing.expectEqual(Phase.resources, opening.phase);
    const discovered = opening.discovered().?;
    try std.testing.expectEqual(@as(usize, 5), discovered.len);
    const assets = opening.assetInventory().?;
    try std.testing.expectEqual(@as(usize, 1), assets.len);
    try std.testing.expectEqualStrings("assets/readme.txt", assets[0].relative);
    const asset_directories = opening.assetDirectoryInventory().?;
    try std.testing.expectEqual(@as(usize, 1), asset_directories.len);
    try std.testing.expectEqualStrings("assets/nested", asset_directories[0].relative);
    var children = opening.assetChildren("assets").?;
    try std.testing.expectEqualStrings("assets/nested", children.next().?.directory.relative);
    try std.testing.expectEqualStrings("assets/readme.txt", children.next().?.file.relative);
    try std.testing.expect(children.next() == null);
    try opening.verifyAssetSnapshot("assets/readme.txt");
    try opening.verifyAssetDirectorySnapshot("assets/nested");
    {
        var opened = try opening.openAsset("assets/readme.txt");
        defer opened.close(test_io);
        try std.testing.expectEqual(@as(u64, 12), (try opened.stat(test_io)).size);
    }
    const asset_bytes = try opening.readAssetAlloc(test_allocator, "assets/readme.txt", 12);
    defer test_allocator.free(asset_bytes);
    try std.testing.expectEqualStrings("indexed only", asset_bytes);
    try std.testing.expectError(error.AssetTooLarge, opening.readAssetAlloc(test_allocator, "assets/readme.txt", 11));
    try std.testing.expectError(error.AssetNotIndexed, opening.openAsset("assets/unknown.bin"));
    {
        var startup = try opening.openResourceFile(.startup_scene);
        defer startup.close(test_io);
        try std.testing.expectEqual(@as(u64, "scene placeholder".len), (try startup.stat(test_io)).size);
    }
    const startup_bytes = try opening.readResourceAlloc(test_allocator, .startup_scene, "scene placeholder".len);
    defer test_allocator.free(startup_bytes);
    try std.testing.expectEqualStrings("scene placeholder", startup_bytes);
    try std.testing.expectError(error.ResourceTooLarge, opening.readResourceAlloc(test_allocator, .startup_scene, "scene placeholder".len - 1));
    try opening.startAssetRead("assets/readme.txt", 12);
    try std.testing.expectError(error.AssetReadActive, opening.startAssetRead("assets/readme.txt", 12));
    try std.testing.expectError(error.AssetReadActive, opening.beginInitialization());
    try std.testing.expectEqual(discovery_mod.AssetReadStage.complete, try awaitAssetRead(&opening));
    switch (try opening.takeAssetRead()) {
        .bytes => |payload| {
            defer test_allocator.free(payload);
            try std.testing.expectEqualStrings("indexed only", payload);
        },
        .failed => return error.AssetReadFailed,
    }
    try std.testing.expect(opening.snapshot().asset_read_stage == null);
    try std.testing.expect(opening.snapshot().asset_read_failure == null);
    try opening.startAssetRead("assets/readme.txt", 11);
    try std.testing.expectEqual(discovery_mod.AssetReadStage.failed, try awaitAssetRead(&opening));
    switch (try opening.takeAssetRead()) {
        .bytes => |payload| {
            test_allocator.free(payload);
            return error.ExpectedReadLimitFailure;
        },
        .failed => |failure| try std.testing.expectEqual(error.AssetTooLarge, failure),
    }
    try std.testing.expectEqual(error.AssetTooLarge, opening.snapshot().asset_read_failure.?);
    try opening.startAssetRead("assets/readme.txt", 12);
    try std.testing.expect(opening.snapshot().asset_read_failure == null);
    try opening.cancelAssetRead();
    try std.testing.expect(opening.assetReadStage() == null);
    try std.testing.expectError(error.AssetReadUnavailable, opening.cancelAssetRead());
    try std.testing.expectEqual(@as(?u16, 0), opening.snapshot().basis_points);
    // Simulate loading each discovered resource
    for (0..discovered.len) |i| try opening.resourceLoaded(i);
    try opening.beginInitialization();
    try opening.editorReady();
    try std.testing.expectEqual(Phase.ready, opening.phase);
    try opening.startAssetRead("assets/readme.txt", 12);
    try std.testing.expectEqual(discovery_mod.AssetReadStage.complete, try awaitAssetRead(&opening));
    switch (try opening.takeAssetRead()) {
        .bytes => |payload| {
            defer test_allocator.free(payload);
            try std.testing.expectEqualStrings("indexed only", payload);
        },
        .failed => return error.AssetReadFailed,
    }
    try std.testing.expectEqual(@as(?u16, 10000), opening.snapshot().basis_points);
}

test "failure reaps an active asset-read worker before releasing discovery" {
    const path = try samplePath();
    defer test_allocator.free(path);
    var opening = try Opening.start(test_allocator, test_io, path);
    defer opening.deinit();
    try awaitDocument(&opening);
    try opening.startDiscovery();
    try awaitDiscovery(&opening);
    try std.testing.expectEqual(Phase.resources, opening.phase);
    try opening.startAssetRead("assets/README.md", 1024 * 1024);
    try std.testing.expect(opening.assetReadStage() != null);
    try opening.fail(error.ExternalFailure);
    try std.testing.expectEqual(Phase.failed, opening.phase);
    try std.testing.expect(opening.assetReadStage() == null);
    try std.testing.expect(opening.discovered() != null);
}

test "discovery failure moves Opening to failed with diagnostic" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // Missing assets directory
    for ([_][]const u8{ "scenes", "scripts/cpp", "scripts/lua" }) |dir| {
        try tmp.dir.createDirPath(test_io, dir);
    }
    const example_path = try samplePath();
    defer test_allocator.free(example_path);
    const bytes = try Io.Dir.cwd().readFileAlloc(test_io, example_path, test_allocator, .limited(1024 * 1024));
    defer test_allocator.free(bytes);
    try tmp.dir.writeFile(test_io, .{ .sub_path = "Broken.proj", .data = bytes });
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(test_io, &buf);
    const proj_path = try std.fs.path.join(test_allocator, &.{ buf[0..n], "Broken.proj" });
    defer test_allocator.free(proj_path);

    var opening = try Opening.start(test_allocator, test_io, proj_path);
    defer opening.deinit();
    try awaitDocument(&opening);
    try opening.startDiscovery();
    try awaitDiscovery(&opening);
    try std.testing.expectEqual(Phase.failed, opening.phase);
    try std.testing.expectEqual(error.FileNotFound, opening.failure.?);
    try std.testing.expectEqualStrings("/assets/root", opening.diagnostic.pointer());
    try std.testing.expect(opening.discovered() == null);
    try std.testing.expectError(error.InvalidPhase, opening.resourceLoaded(0));
}
