//! Filesystem discovery for project resources. This is not a scene loader,
//! asset decoder, or script executor. Discovery verifies project roots and
//! indexes bounded metadata; `openAsset` can return a validated read-only file
//! handle but never reads or interprets the contents.
//!
//! Startup scene and optional script entries are treated as logical
//! tickets. Existing files are real-path checked for containment and regular
//! file type; missing files remain unresolved tickets until real loaders exist
//! (ADR-004).
const std = @import("std");
const app = @import("corex_app");
const Io = std.Io;

pub const ResourceKind = enum {
    scenes_root,
    assets_root,
    lua_root,
    cpp_root,
    startup_scene,
    lua_entry,
    cpp_library,
};

pub const FileMetadata = struct {
    inode: Io.File.INode,
    size_bytes: u64,
    modified_at: Io.Timestamp,
};

pub const Resource = struct {
    kind: ResourceKind,
    /// Borrowed from the discovery arena; relative path as in .proj.
    relative: []const u8,
    /// Absolute path, real-path resolved when the entry exists.
    absolute: []const u8,
    /// True only when the filesystem entry currently exists; not a loaded state.
    exists: bool,
    is_dir: bool,
    file_metadata: ?FileMetadata = null,
};

/// A bounded, sorted metadata index for content-browser discovery. It is not a
/// decoded or loaded asset and is deliberately separate from progress tickets.
pub const AssetEntry = struct {
    relative: []const u8,
    absolute: []const u8,
    size_bytes: u64,
    modified_at: Io.Timestamp,
    inode: Io.File.INode,
};

/// Directory metadata for hierarchical content-browser navigation. The assets
/// root is represented by its project resource and is not repeated here.
pub const AssetDirectory = struct {
    relative: []const u8,
    absolute: []const u8,
    inode: Io.File.INode,
};

pub const AssetChild = union(enum) {
    file: *const AssetEntry,
    directory: *const AssetDirectory,
};

/// Allocation-free, merged lexical iteration over a directory's immediate
/// files and subdirectories. The directory path is borrowed for this iterator.
pub const AssetChildrenIterator = struct {
    files: []const AssetEntry,
    directories: []const AssetDirectory,
    relative_dir: []const u8,
    file_index: usize = 0,
    directory_index: usize = 0,

    fn isDirectChild(self: *const AssetChildrenIterator, path: []const u8) bool {
        if (!std.mem.startsWith(u8, path, self.relative_dir) or path.len <= self.relative_dir.len + 1) return false;
        if (path[self.relative_dir.len] != '/') return false;
        return std.mem.indexOfScalar(u8, path[self.relative_dir.len + 1 ..], '/') == null;
    }

    fn nextFileCandidate(self: *AssetChildrenIterator) ?*const AssetEntry {
        while (self.file_index < self.files.len) : (self.file_index += 1) {
            const entry = &self.files[self.file_index];
            if (self.isDirectChild(entry.relative)) return entry;
        }
        return null;
    }

    fn nextDirectoryCandidate(self: *AssetChildrenIterator) ?*const AssetDirectory {
        while (self.directory_index < self.directories.len) : (self.directory_index += 1) {
            const directory = &self.directories[self.directory_index];
            if (self.isDirectChild(directory.relative)) return directory;
        }
        return null;
    }

    pub fn next(self: *AssetChildrenIterator) ?AssetChild {
        const file = self.nextFileCandidate();
        const directory = self.nextDirectoryCandidate();
        if (file == null and directory == null) return null;
        if (directory == null or (file != null and std.mem.lessThan(u8, file.?.relative, directory.?.relative))) {
            self.file_index += 1;
            return .{ .file = file.? };
        }
        self.directory_index += 1;
        return .{ .directory = directory.? };
    }
};

pub const AssetOpenError = error{ AssetNotIndexed, AssetSnapshotStale } || Io.Dir.OpenError || Io.Dir.StatFileError || Io.Dir.RealPathError || Io.File.OpenError || Io.File.StatError;

fn mapAssetOpenError(err: AssetOpenError) AssetOpenError {
    return switch (err) {
        error.FileNotFound, error.NotDir, error.SymLinkLoop, error.IsDir => error.AssetSnapshotStale,
        else => err,
    };
}

pub const ResourceOpenError = error{ ResourceNotFound, ResourceNotPresent, ResourceSnapshotStale } || Io.Dir.OpenError || Io.Dir.StatFileError || Io.Dir.RealPathError || Io.File.OpenError || Io.File.StatError;

fn mapResourceOpenError(err: ResourceOpenError) ResourceOpenError {
    return switch (err) {
        error.FileNotFound, error.NotDir, error.SymLinkLoop, error.IsDir => error.ResourceSnapshotStale,
        else => err,
    };
}

pub const max_asset_files: usize = 16384;
pub const max_asset_walk_entries: usize = 65536;
pub const max_asset_depth: usize = 64;

pub const Discovery = struct {
    arena: std.heap.ArenaAllocator,
    project_dir: []const u8,
    real_project_dir: []const u8,
    project_root_inode: Io.File.INode,
    resources: []Resource,
    asset_files: []AssetEntry,
    asset_directories: []AssetDirectory,
    asset_root_inode: Io.File.INode,

    pub fn deinit(self: *Discovery) void {
        self.arena.deinit();
    }

    /// Number of logical project-opening tickets, excluding the asset catalog.
    pub fn resourceCount(self: *const Discovery) usize {
        return self.resources.len;
    }

    pub fn assetCount(self: *const Discovery) usize {
        return self.asset_files.len;
    }

    pub fn assetDirectoryCount(self: *const Discovery) usize {
        return self.asset_directories.len;
    }

    pub fn findAssetDirectory(self: *const Discovery, relative: []const u8) ?*const AssetDirectory {
        var low: usize = 0;
        var high = self.asset_directories.len;
        while (low < high) {
            const mid = low + (high - low) / 2;
            const directory = &self.asset_directories[mid];
            switch (std.mem.order(u8, relative, directory.relative)) {
                .lt => high = mid,
                .gt => low = mid + 1,
                .eq => return directory,
            }
        }
        return null;
    }

    /// Iterate immediate children of the assets root or an indexed subdirectory.
    /// The supplied path must remain alive until the iterator is exhausted.
    pub fn assetChildren(self: *const Discovery, relative_dir: []const u8) ?AssetChildrenIterator {
        var is_assets_root = false;
        for (self.resources) |resource| {
            if (resource.kind == .assets_root and std.mem.eql(u8, relative_dir, resource.relative)) {
                is_assets_root = true;
                break;
            }
        }
        if (!is_assets_root and self.findAssetDirectory(relative_dir) == null) return null;
        return .{
            .files = self.asset_files,
            .directories = self.asset_directories,
            .relative_dir = relative_dir,
        };
    }

    /// Exact, allocation-free lookup in the canonical sorted asset index.
    pub fn findAsset(self: *const Discovery, relative: []const u8) ?*const AssetEntry {
        var low: usize = 0;
        var high = self.asset_files.len;
        while (low < high) {
            const mid = low + (high - low) / 2;
            const entry = &self.asset_files[mid];
            switch (std.mem.order(u8, relative, entry.relative)) {
                .lt => high = mid,
                .gt => low = mid + 1,
                .eq => return entry,
            }
        }
        return null;
    }

    /// Open an indexed asset without following symlinks. Every directory
    /// component and the final file are reopened relative to verified handles;
    /// the returned handle belongs to the caller and must be closed.
    pub fn openAsset(self: *const Discovery, io: Io, relative: []const u8) AssetOpenError!Io.File {
        const expected = self.findAsset(relative) orelse return error.AssetNotIndexed;
        const assets_resource = for (self.resources) |resource| {
            if (resource.kind == .assets_root) break resource;
        } else return error.AssetSnapshotStale;
        const root_relative = assets_resource.relative;
        if (expected.relative.len <= root_relative.len + 1 or
            !std.mem.startsWith(u8, expected.relative, root_relative) or
            expected.relative[root_relative.len] != '/') return error.AssetSnapshotStale;

        var root = Io.Dir.cwd().openDir(io, assets_resource.absolute, .{ .iterate = true, .follow_symlinks = false }) catch |err| return mapAssetOpenError(err);
        defer root.close(io);
        const root_stat = root.stat(io) catch |err| return mapAssetOpenError(err);
        var root_path: [std.fs.max_path_bytes]u8 = undefined;
        const root_path_len = root.realPath(io, &root_path) catch |err| return mapAssetOpenError(err);
        if (root_stat.kind != .directory or !std.meta.eql(root_stat.inode, self.asset_root_inode) or
            !std.mem.eql(u8, root_path[0..root_path_len], assets_resource.absolute)) return error.AssetSnapshotStale;

        var current = root;
        var owns_current = false;
        defer if (owns_current) current.close(io);
        var remaining = expected.relative[root_relative.len + 1 ..];
        var relative_prefix_len = root_relative.len;
        while (std.mem.indexOfScalar(u8, remaining, '/')) |separator| {
            const component = remaining[0..separator];
            relative_prefix_len += component.len + 1;
            const indexed_directory = self.findAssetDirectory(expected.relative[0..relative_prefix_len]) orelse return error.AssetSnapshotStale;
            const before = current.statFile(io, component, .{ .follow_symlinks = false }) catch |err| return mapAssetOpenError(err);
            if (before.kind != .directory or !std.meta.eql(before.inode, indexed_directory.inode)) return error.AssetSnapshotStale;
            const child = current.openDir(io, component, .{ .iterate = true, .follow_symlinks = false }) catch |err| return mapAssetOpenError(err);
            errdefer child.close(io);
            const opened_stat = child.stat(io) catch |err| return mapAssetOpenError(err);
            var opened_path: [std.fs.max_path_bytes]u8 = undefined;
            const opened_path_len = child.realPath(io, &opened_path) catch |err| return mapAssetOpenError(err);
            if (opened_stat.kind != .directory or !std.meta.eql(opened_stat.inode, indexed_directory.inode) or
                !std.mem.eql(u8, opened_path[0..opened_path_len], indexed_directory.absolute) or
                !isPrefix(self.real_project_dir, opened_path[0..opened_path_len])) return error.AssetSnapshotStale;
            if (owns_current) current.close(io);
            current = child;
            owns_current = true;
            remaining = remaining[separator + 1 ..];
        }

        const before_file = current.statFile(io, remaining, .{ .follow_symlinks = false }) catch |err| return mapAssetOpenError(err);
        if (before_file.kind != .file or !std.meta.eql(before_file.inode, expected.inode)) return error.AssetSnapshotStale;
        const file = current.openFile(io, remaining, .{ .mode = .read_only, .allow_directory = false, .follow_symlinks = false, .resolve_beneath = true }) catch |err| return mapAssetOpenError(err);
        errdefer file.close(io);
        const opened_file_stat = file.stat(io) catch |err| return mapAssetOpenError(err);
        if (opened_file_stat.kind != .file or !std.meta.eql(opened_file_stat.inode, expected.inode) or
            opened_file_stat.size != expected.size_bytes or !std.meta.eql(opened_file_stat.mtime, expected.modified_at)) return error.AssetSnapshotStale;
        return file;
    }

    /// Open an existing startup/script/library resource without following
    /// symlinks, checking each handle against its discovered canonical path and
    /// file identity. The caller owns and must close the returned handle.
    pub fn openResourceFile(self: *const Discovery, io: Io, kind: ResourceKind) ResourceOpenError!Io.File {
        const resource = for (self.resources) |candidate| {
            if (candidate.kind == kind) break candidate;
        } else return error.ResourceNotFound;
        if (!resource.exists or resource.is_dir) return error.ResourceNotPresent;
        const expected = resource.file_metadata orelse return error.ResourceNotPresent;
        if (!isPrefix(self.real_project_dir, resource.absolute)) return error.ResourceSnapshotStale;
        const relative_offset = self.real_project_dir.len + @intFromBool(self.real_project_dir[self.real_project_dir.len - 1] != std.fs.path.sep);
        if (resource.absolute.len <= relative_offset) return error.ResourceSnapshotStale;

        var root = Io.Dir.cwd().openDir(io, self.real_project_dir, .{ .iterate = true, .follow_symlinks = false }) catch |err| return mapResourceOpenError(err);
        defer root.close(io);
        const root_stat = root.stat(io) catch |err| return mapResourceOpenError(err);
        var root_path: [std.fs.max_path_bytes]u8 = undefined;
        const root_path_len = root.realPath(io, &root_path) catch |err| return mapResourceOpenError(err);
        if (root_stat.kind != .directory or !std.meta.eql(root_stat.inode, self.project_root_inode) or
            !std.mem.eql(u8, root_path[0..root_path_len], self.real_project_dir)) return error.ResourceSnapshotStale;

        var remaining = resource.absolute[relative_offset..];
        var component_start = relative_offset;
        var current = root;
        var owns_current = false;
        defer if (owns_current) current.close(io);
        while (std.mem.indexOfScalar(u8, remaining, std.fs.path.sep)) |separator| {
            const component = remaining[0..separator];
            const before = current.statFile(io, component, .{ .follow_symlinks = false }) catch |err| return mapResourceOpenError(err);
            if (before.kind != .directory) return error.ResourceSnapshotStale;
            const child = current.openDir(io, component, .{ .iterate = true, .follow_symlinks = false }) catch |err| return mapResourceOpenError(err);
            errdefer child.close(io);
            const opened_stat = child.stat(io) catch |err| return mapResourceOpenError(err);
            var opened_path: [std.fs.max_path_bytes]u8 = undefined;
            const opened_path_len = child.realPath(io, &opened_path) catch |err| return mapResourceOpenError(err);
            const expected_prefix_end = component_start + component.len;
            if (opened_stat.kind != .directory or !std.meta.eql(opened_stat.inode, before.inode) or
                !std.mem.eql(u8, opened_path[0..opened_path_len], resource.absolute[0..expected_prefix_end]) or
                !isPrefix(self.real_project_dir, opened_path[0..opened_path_len])) return error.ResourceSnapshotStale;
            if (owns_current) current.close(io);
            current = child;
            owns_current = true;
            remaining = remaining[separator + 1 ..];
            component_start = expected_prefix_end + 1;
        }

        const before_file = current.statFile(io, remaining, .{ .follow_symlinks = false }) catch |err| return mapResourceOpenError(err);
        if (before_file.kind != .file or !std.meta.eql(before_file.inode, expected.inode)) return error.ResourceSnapshotStale;
        const file = current.openFile(io, remaining, .{ .mode = .read_only, .allow_directory = false, .follow_symlinks = false, .resolve_beneath = true }) catch |err| return mapResourceOpenError(err);
        errdefer file.close(io);
        const opened_file_stat = file.stat(io) catch |err| return mapResourceOpenError(err);
        if (opened_file_stat.kind != .file or !std.meta.eql(opened_file_stat.inode, expected.inode) or
            opened_file_stat.size != expected.size_bytes or !std.meta.eql(opened_file_stat.mtime, expected.modified_at)) return error.ResourceSnapshotStale;
        return file;
    }

    /// Read an indexed asset as opaque bytes under a caller-supplied hard limit.
    /// The caller owns the allocation; no format parsing or execution occurs.
    pub fn readAssetAlloc(self: *const Discovery, allocator: std.mem.Allocator, io: Io, relative: []const u8, max_bytes: usize) ![]u8 {
        const expected = self.findAsset(relative) orelse return error.AssetNotIndexed;
        var file = try self.openAsset(io, relative);
        defer file.close(io);
        return readOpenedFileAlloc(allocator, io, file, .{
            .inode = expected.inode,
            .size_bytes = expected.size_bytes,
            .modified_at = expected.modified_at,
        }, max_bytes, .asset);
    }

    /// Bounded opaque read for a discovered startup scene, Lua entry, or library.
    pub fn readResourceAlloc(self: *const Discovery, allocator: std.mem.Allocator, io: Io, kind: ResourceKind, max_bytes: usize) ![]u8 {
        const resource = for (self.resources) |candidate| {
            if (candidate.kind == kind) break candidate;
        } else return error.ResourceNotFound;
        if (!resource.exists or resource.is_dir) return error.ResourceNotPresent;
        const metadata = resource.file_metadata orelse return error.ResourceNotPresent;
        var file = try self.openResourceFile(io, kind);
        defer file.close(io);
        return readOpenedFileAlloc(allocator, io, file, metadata, max_bytes, .resource);
    }

    /// Check whether an indexed directory still resolves to the same directory
    /// object. This is cache invalidation only, not a safe-open guarantee.
    pub fn verifyAssetDirectorySnapshot(self: *const Discovery, allocator: std.mem.Allocator, io: Io, relative: []const u8) error{ AssetDirectoryNotIndexed, AssetDirectorySnapshotStale, OutOfMemory }!void {
        const expected = self.findAssetDirectory(relative) orelse return error.AssetDirectoryNotIndexed;
        const real = Io.Dir.cwd().realPathFileAlloc(io, expected.absolute, allocator) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return error.AssetDirectorySnapshotStale;
        };
        defer allocator.free(real);
        if (!std.mem.eql(u8, real, expected.absolute)) return error.AssetDirectorySnapshotStale;
        const stat = Io.Dir.cwd().statFile(io, real, .{}) catch return error.AssetDirectorySnapshotStale;
        if (stat.kind != .directory or !std.meta.eql(stat.inode, expected.inode)) return error.AssetDirectorySnapshotStale;
    }

    /// Check whether indexed filesystem metadata is still current. This is a
    /// cache-invalidation hint, not authentication or a safe-open guarantee;
    /// callers must revalidate when the eventual loader opens the file.
    pub fn verifyAssetSnapshot(self: *const Discovery, allocator: std.mem.Allocator, io: Io, relative: []const u8) error{ AssetNotIndexed, AssetSnapshotStale, OutOfMemory }!void {
        const expected = self.findAsset(relative) orelse return error.AssetNotIndexed;
        const real = Io.Dir.cwd().realPathFileAlloc(io, expected.absolute, allocator) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return error.AssetSnapshotStale;
        };
        defer allocator.free(real);
        if (!std.mem.eql(u8, real, expected.absolute)) return error.AssetSnapshotStale;
        const stat = Io.Dir.cwd().statFile(io, real, .{}) catch return error.AssetSnapshotStale;
        if (stat.kind != .file or stat.size != expected.size_bytes or !std.meta.eql(stat.mtime, expected.modified_at) or !std.meta.eql(stat.inode, expected.inode)) return error.AssetSnapshotStale;
    }
};

const FileReadKind = enum { asset, resource };

fn staleReadError(kind: FileReadKind) error{ AssetSnapshotStale, ResourceSnapshotStale } {
    return switch (kind) {
        .asset => error.AssetSnapshotStale,
        .resource => error.ResourceSnapshotStale,
    };
}

fn tooLargeReadError(kind: FileReadKind) error{ AssetTooLarge, ResourceTooLarge } {
    return switch (kind) {
        .asset => error.AssetTooLarge,
        .resource => error.ResourceTooLarge,
    };
}

fn readOpenedFileAlloc(allocator: std.mem.Allocator, io: Io, file: Io.File, expected: FileMetadata, max_bytes: usize, kind: FileReadKind) ![]u8 {
    const before = try file.stat(io);
    if (before.kind != .file or !std.meta.eql(before.inode, expected.inode) or
        before.size != expected.size_bytes or !std.meta.eql(before.mtime, expected.modified_at)) return staleReadError(kind);
    if (before.size > max_bytes) return tooLargeReadError(kind);

    var reader = file.reader(io, &.{});
    const bytes = reader.interface.allocRemaining(allocator, .limited(max_bytes)) catch |err| switch (err) {
        error.StreamTooLong => return tooLargeReadError(kind),
        else => return err,
    };
    errdefer allocator.free(bytes);
    const after = try file.stat(io);
    if (@as(u64, @intCast(bytes.len)) != before.size or after.kind != .file or
        !std.meta.eql(after.inode, before.inode) or after.size != before.size or
        !std.meta.eql(after.mtime, before.mtime)) return staleReadError(kind);
    return bytes;
}

pub const Stage = enum(u8) { queued, resolving_project, checking_resources, complete, failed, canceled };
pub const Failure = struct { code: anyerror, diagnostic: app.project.Diagnostic };
pub const Result = union(enum) {
    /// Caller owns the discovery and must call deinit exactly once.
    discovery: Discovery,
    failed: Failure,
};

const Shared = struct {
    allocator: std.mem.Allocator,
    io: Io,
    path: []u8,
    // This shallow snapshot borrows strings from the caller's immutable project
    // document. The caller must keep that document alive until task completion.
    project: app.project.Project,
    stage: std.atomic.Value(Stage) = .init(.queued),
};

fn discoveryWorker(shared: *Shared) Result {
    shared.stage.store(.resolving_project, .release);
    const real_path = Io.Dir.cwd().realPathFileAlloc(shared.io, shared.path, shared.allocator) catch |err| {
        shared.stage.store(if (err == error.Canceled) .canceled else .failed, .release);
        return .{ .failed = .{ .code = err, .diagnostic = .{} } };
    };
    defer shared.allocator.free(real_path);
    shared.stage.store(.checking_resources, .release);
    var diagnostic: app.project.Diagnostic = .{};
    const result = discover(shared.allocator, shared.io, real_path, shared.project, &diagnostic) catch |err| {
        shared.stage.store(if (err == error.Canceled) .canceled else .failed, .release);
        return .{ .failed = .{ .code = err, .diagnostic = diagnostic } };
    };
    shared.stage.store(.complete, .release);
    return .{ .discovery = result };
}

/// Single-owner async filesystem discovery task. The project document and its
/// strings must outlive this task; `take` or `deinit` joins the worker before
/// shared state is released. Deinit may block on OS filesystem I/O.
pub const Task = struct {
    shared: ?*Shared,
    future: ?Io.Future(Result),

    pub fn start(allocator: std.mem.Allocator, io: Io, project_path: []const u8, project: app.project.Project) !Task {
        try app.cli.validatePath(project_path);
        const shared = try allocator.create(Shared);
        errdefer allocator.destroy(shared);
        const owned_path = try allocator.dupe(u8, project_path);
        errdefer allocator.free(owned_path);
        shared.* = .{ .allocator = allocator, .io = io, .path = owned_path, .project = project };
        const future = try Io.concurrent(io, discoveryWorker, .{shared});
        return .{ .shared = shared, .future = future };
    }

    pub fn stage(self: *const Task) ?Stage {
        const shared = self.shared orelse return null;
        return shared.stage.load(.acquire);
    }

    fn releaseShared(self: *Task) void {
        const shared = self.shared orelse return;
        const allocator = shared.allocator;
        allocator.free(shared.path);
        allocator.destroy(shared);
        self.shared = null;
    }

    pub fn take(self: *Task) error{TaskConsumed}!Result {
        var future = self.future orelse return error.TaskConsumed;
        self.future = null;
        const result = future.await(self.shared.?.io);
        self.releaseShared();
        return result;
    }

    pub fn deinit(self: *Task) void {
        if (self.future) |*future| {
            var result = future.cancel(self.shared.?.io);
            switch (result) {
                .discovery => |*discovery| discovery.deinit(),
                .failed => {},
            }
            self.future = null;
        }
        self.releaseShared();
    }
};

pub const AssetReadStage = enum(u8) { queued, reading, complete, failed, canceled };
pub const AssetReadResult = union(enum) {
    /// Caller owns bytes and must free them with the allocator passed to start.
    bytes: []u8,
    failed: anyerror,
};

const AssetReadShared = struct {
    allocator: std.mem.Allocator,
    io: Io,
    discovery: *const Discovery,
    relative: []u8,
    max_bytes: usize,
    stage: std.atomic.Value(AssetReadStage) = .init(.queued),
};

fn assetReadWorker(shared: *AssetReadShared) AssetReadResult {
    shared.stage.store(.reading, .release);
    const bytes = shared.discovery.readAssetAlloc(shared.allocator, shared.io, shared.relative, shared.max_bytes) catch |err| {
        shared.stage.store(if (err == error.Canceled) .canceled else .failed, .release);
        return .{ .failed = err };
    };
    shared.stage.store(.complete, .release);
    return .{ .bytes = bytes };
}

/// One-shot bounded asset read on a worker thread. The Discovery and a
/// thread-safe allocator must outlive this task. `take` transfers the byte
/// allocation; `deinit` cancels/joins and frees an uncollected result. Both
/// operations may wait on filesystem I/O.
pub const AssetReadTask = struct {
    shared: ?*AssetReadShared,
    future: ?Io.Future(AssetReadResult),

    pub fn start(allocator: std.mem.Allocator, io: Io, discovery: *const Discovery, relative: []const u8, max_bytes: usize) !AssetReadTask {
        if (discovery.findAsset(relative) == null) return error.AssetNotIndexed;
        const shared = try allocator.create(AssetReadShared);
        errdefer allocator.destroy(shared);
        const owned_relative = try allocator.dupe(u8, relative);
        errdefer allocator.free(owned_relative);
        shared.* = .{
            .allocator = allocator,
            .io = io,
            .discovery = discovery,
            .relative = owned_relative,
            .max_bytes = max_bytes,
        };
        const future = try Io.concurrent(io, assetReadWorker, .{shared});
        return .{ .shared = shared, .future = future };
    }

    pub fn stage(self: *const AssetReadTask) ?AssetReadStage {
        const shared = self.shared orelse return null;
        return shared.stage.load(.acquire);
    }

    fn releaseShared(self: *AssetReadTask) void {
        const shared = self.shared orelse return;
        const allocator = shared.allocator;
        allocator.free(shared.relative);
        allocator.destroy(shared);
        self.shared = null;
    }

    pub fn take(self: *AssetReadTask) error{TaskConsumed}!AssetReadResult {
        var future = self.future orelse return error.TaskConsumed;
        self.future = null;
        const result = future.await(self.shared.?.io);
        self.releaseShared();
        return result;
    }

    pub fn deinit(self: *AssetReadTask) void {
        if (self.future) |*future| {
            const shared = self.shared.?;
            const allocator = shared.allocator;
            const result = future.cancel(shared.io);
            switch (result) {
                .bytes => |payload| allocator.free(payload),
                .failed => {},
            }
            self.future = null;
        }
        self.releaseShared();
    }
};

fn diagnosticSet(d: *app.project.Diagnostic, pointer: []const u8) void {
    d.* = .{};
    var n = @min(pointer.len, d.storage.len);
    while (n > 0 and !std.unicode.utf8ValidateSlice(pointer[0..n])) n -= 1;
    @memcpy(d.storage[0..n], pointer[0..n]);
    d.len = n;
}

fn isPrefix(prefix: []const u8, path: []const u8) bool {
    if (path.len < prefix.len) return false;
    if (!std.mem.startsWith(u8, path, prefix)) return false;
    if (path.len == prefix.len) return true;
    // A filesystem root already ends at a component boundary (`/`, `C:\\`).
    if (prefix.len > 0 and prefix[prefix.len - 1] == std.fs.path.sep) return true;
    return path[prefix.len] == std.fs.path.sep;
}

/// Verify that `absolute` (already real-pathed) is contained in `realProjectDir`.
/// Returns error.ContainmentBreach if it escapes.
fn ensureContained(realProjectDir: []const u8, absolute: []const u8) !void {
    if (!isPrefix(realProjectDir, absolute)) return error.ContainmentBreach;
}

fn statIsDir(io: Io, path: []const u8) !bool {
    const stat = try Io.Dir.cwd().statFile(io, path, .{});
    return stat.kind == .directory;
}

const ResolvedFile = struct {
    absolute: []const u8,
    metadata: FileMetadata,
};

/// Resolve an optional file path. Missing files remain logical resources, but
/// existing targets are contained and must be regular files.
fn resolveOptionalFile(
    allocator: std.mem.Allocator,
    io: Io,
    realProjectDir: []const u8,
    path: []const u8,
    pointer: []const u8,
    diagnostic: *app.project.Diagnostic,
) !?ResolvedFile {
    const real = Io.Dir.cwd().realPathFileAlloc(io, path, allocator) catch |err| {
        if (err == error.FileNotFound) return null;
        diagnosticSet(diagnostic, pointer);
        return err;
    };
    errdefer allocator.free(real);
    ensureContained(realProjectDir, real) catch |err| {
        diagnosticSet(diagnostic, pointer);
        return err;
    };
    const stat = Io.Dir.cwd().statFile(io, real, .{}) catch |err| {
        diagnosticSet(diagnostic, pointer);
        return err;
    };
    if (stat.kind != .file) {
        diagnosticSet(diagnostic, pointer);
        return error.NotFile;
    }
    return .{
        .absolute = real,
        .metadata = .{ .inode = stat.inode, .size_bytes = stat.size, .modified_at = stat.mtime },
    };
}

fn assetLessThan(_: void, lhs: AssetEntry, rhs: AssetEntry) bool {
    return std.mem.lessThan(u8, lhs.relative, rhs.relative);
}

fn assetDirectoryLessThan(_: void, lhs: AssetDirectory, rhs: AssetDirectory) bool {
    return std.mem.lessThan(u8, lhs.relative, rhs.relative);
}

const AssetInventory = struct {
    files: []AssetEntry,
    directories: []AssetDirectory,
    root_inode: Io.File.INode,
};

/// Enumerate asset metadata only. The explicit handle-based walk never follows
/// symlinks; opened directory/file identities are checked against no-follow
/// metadata to detect observed replacement races. File contents are never
/// opened. Bounded file and directory indexes are sorted independently of
/// filesystem iteration.
fn scanAssets(
    allocator: std.mem.Allocator,
    io: Io,
    realProjectDir: []const u8,
    realAssetsDir: []const u8,
    assetRootRelative: []const u8,
    diagnostic: *app.project.Diagnostic,
) !AssetInventory {
    var root = Io.Dir.cwd().openDir(io, realAssetsDir, .{ .iterate = true, .follow_symlinks = false }) catch |err| {
        diagnosticSet(diagnostic, "/assets/root");
        return err;
    };
    defer root.close(io);
    const root_stat = root.stat(io) catch |err| {
        diagnosticSet(diagnostic, "/assets/root");
        return err;
    };
    var root_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_path_len = root.realPath(io, &root_path_buf) catch |err| {
        diagnosticSet(diagnostic, "/assets/root");
        return err;
    };
    if (root_stat.kind != .directory or !std.mem.eql(u8, root_path_buf[0..root_path_len], realAssetsDir)) {
        diagnosticSet(diagnostic, "/assets/root");
        return error.AssetEntryChanged;
    }
    const Frame = struct {
        dir: Io.Dir,
        relative: []const u8,
        owns_relative: bool,
        iterator: Io.Dir.Iterator,
    };
    var stack: std.ArrayList(Frame) = .empty;
    defer {
        var i = stack.items.len;
        while (i > 1) {
            i -= 1;
            const frame = stack.items[i];
            frame.dir.close(io);
            if (frame.owns_relative) allocator.free(frame.relative);
        }
        stack.deinit(allocator);
    }
    try stack.append(allocator, .{ .dir = root, .relative = "", .owns_relative = false, .iterator = root.iterateAssumeFirstIteration() });

    var entries: std.ArrayList(AssetEntry) = .empty;
    defer entries.deinit(allocator);
    var directories: std.ArrayList(AssetDirectory) = .empty;
    defer directories.deinit(allocator);
    var visited: usize = 0;
    while (stack.items.len > 0) {
        const top_index = stack.items.len - 1;
        const maybe_entry = stack.items[top_index].iterator.next(io) catch |err| {
            diagnosticSet(diagnostic, "/assets/root");
            return err;
        };
        const entry = maybe_entry orelse {
            if (stack.items.len == 1) break;
            const finished = stack.pop().?;
            finished.dir.close(io);
            if (finished.owns_relative) allocator.free(finished.relative);
            continue;
        };
        visited += 1;
        if (visited > max_asset_walk_entries) {
            diagnosticSet(diagnostic, "/assets/root");
            return error.AssetInventoryLimitExceeded;
        }
        const depth = stack.items.len;
        if (depth > max_asset_depth) {
            diagnosticSet(diagnostic, "/assets/root");
            return error.AssetDepthExceeded;
        }

        const parent_dir = stack.items[top_index].dir;
        const inside = if (stack.items[top_index].relative.len == 0)
            try allocator.dupe(u8, entry.name)
        else
            try std.fs.path.join(allocator, &.{ stack.items[top_index].relative, entry.name });
        const relative = try validateAssetRelative(allocator, assetRootRelative, inside, diagnostic);
        const nofollow = parent_dir.statFile(io, entry.name, .{ .follow_symlinks = false }) catch |err| {
            diagnosticSet(diagnostic, "/assets/root");
            return err;
        };
        if (entry.kind == .sym_link or nofollow.kind == .sym_link) {
            diagnosticSet(diagnostic, "/assets/root");
            return error.AssetSymlinkNotAllowed;
        }
        if (entry.kind != nofollow.kind) {
            diagnosticSet(diagnostic, "/assets/root");
            return error.AssetEntryChanged;
        }

        switch (entry.kind) {
            .directory => {
                const expected_path = parent_dir.realPathFileAlloc(io, entry.name, allocator) catch |err| {
                    diagnosticSet(diagnostic, "/assets/root");
                    return err;
                };
                ensureContained(realProjectDir, expected_path) catch |err| {
                    diagnosticSet(diagnostic, "/assets/root");
                    return err;
                };
                const child_dir = parent_dir.openDir(io, entry.name, .{ .iterate = true, .follow_symlinks = false }) catch |err| {
                    diagnosticSet(diagnostic, "/assets/root");
                    return err;
                };
                errdefer child_dir.close(io);
                const opened_stat = child_dir.stat(io) catch |err| {
                    diagnosticSet(diagnostic, "/assets/root");
                    return err;
                };
                if (opened_stat.kind != .directory or !std.meta.eql(opened_stat.inode, nofollow.inode)) {
                    diagnosticSet(diagnostic, "/assets/root");
                    return error.AssetEntryChanged;
                }
                var opened_path_buf: [std.fs.max_path_bytes]u8 = undefined;
                const opened_path_len = child_dir.realPath(io, &opened_path_buf) catch |err| {
                    diagnosticSet(diagnostic, "/assets/root");
                    return err;
                };
                if (!std.mem.eql(u8, opened_path_buf[0..opened_path_len], expected_path)) {
                    diagnosticSet(diagnostic, "/assets/root");
                    return error.AssetEntryChanged;
                }
                ensureContained(realProjectDir, opened_path_buf[0..opened_path_len]) catch |err| {
                    diagnosticSet(diagnostic, "/assets/root");
                    return err;
                };
                try directories.append(allocator, .{
                    .relative = relative,
                    .absolute = try allocator.dupe(u8, opened_path_buf[0..opened_path_len]),
                    .inode = opened_stat.inode,
                });
                try stack.append(allocator, .{ .dir = child_dir, .relative = inside, .owns_relative = true, .iterator = child_dir.iterateAssumeFirstIteration() });
            },
            .file => {
                if (entries.items.len == max_asset_files) {
                    diagnosticSet(diagnostic, "/assets/root");
                    return error.AssetInventoryLimitExceeded;
                }
                const real = parent_dir.realPathFileAlloc(io, entry.name, allocator) catch |err| {
                    diagnosticSet(diagnostic, "/assets/root");
                    return err;
                };
                ensureContained(realProjectDir, real) catch |err| {
                    diagnosticSet(diagnostic, "/assets/root");
                    return err;
                };
                const stat = parent_dir.statFile(io, entry.name, .{}) catch |err| {
                    diagnosticSet(diagnostic, "/assets/root");
                    return err;
                };
                const after = parent_dir.statFile(io, entry.name, .{ .follow_symlinks = false }) catch |err| {
                    diagnosticSet(diagnostic, "/assets/root");
                    return err;
                };
                if (stat.kind != .file or after.kind != .file or !std.meta.eql(after.inode, nofollow.inode)) {
                    diagnosticSet(diagnostic, "/assets/root");
                    return error.AssetEntryChanged;
                }
                try entries.append(allocator, .{ .relative = relative, .absolute = real, .size_bytes = stat.size, .modified_at = stat.mtime, .inode = stat.inode });
            },
            else => {
                diagnosticSet(diagnostic, "/assets/root");
                return error.UnsupportedAssetEntry;
            },
        }
    }
    std.mem.sortUnstable(AssetEntry, entries.items, {}, assetLessThan);
    std.mem.sortUnstable(AssetDirectory, directories.items, {}, assetDirectoryLessThan);
    return .{
        .files = try allocator.dupe(AssetEntry, entries.items),
        .directories = try allocator.dupe(AssetDirectory, directories.items),
        .root_inode = root_stat.inode,
    };
}

fn validateAssetRelative(allocator: std.mem.Allocator, root: []const u8, inside: []const u8, diagnostic: *app.project.Diagnostic) ![]const u8 {
    const normalized_inside = try aNormalizePath(allocator, inside);
    const relative = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ root, normalized_inside });
    app.validation.relativePath(relative) catch {
        diagnosticSet(diagnostic, "/assets/root");
        return error.UnsupportedAssetPath;
    };
    return relative;
}

fn aNormalizePath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const normalized = try allocator.dupe(u8, path);
    if (std.fs.path.sep != '/') for (normalized) |*c| {
        if (c.* == std.fs.path.sep) c.* = '/';
    };
    return normalized;
}

/// Discover required project directories. `projectFilePath` must be an absolute,
/// already-resolved path to the .proj file (as produced by realPathFileAlloc
/// in preflight/bootstrap). `diagnostic` is set to the JSON Pointer of the
/// failing field on error. The caller owns `Discovery` and must call `deinit`.
pub fn discover(
    allocator: std.mem.Allocator,
    io: Io,
    projectFilePath: []const u8,
    doc: app.project.Project,
    diagnostic: *app.project.Diagnostic,
) !Discovery {
    diagnostic.* = .{};
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();

    const dir = std.fs.path.dirname(projectFilePath) orelse return error.InvalidProjectPath;
    const project_dir = try a.dupe(u8, dir);
    const real_project_dir = try Io.Dir.cwd().realPathFileAlloc(io, project_dir, a);
    // realProjectDir must be absolute and resolved; ensure containment checks use it.
    if (!std.unicode.utf8ValidateSlice(real_project_dir)) return error.UnsupportedProjectPathEncoding;
    const project_root_stat = try Io.Dir.cwd().statFile(io, real_project_dir, .{});
    if (project_root_stat.kind != .directory) return error.NotDir;

    // Helper to resolve and validate a directory field.
    const DirField = struct { relative: []const u8, pointer: []const u8, kind: ResourceKind };
    var fields: std.ArrayList(DirField) = .empty;
    defer fields.deinit(a);
    try fields.append(a, .{ .relative = doc.scenes.root, .pointer = "/scenes/root", .kind = .scenes_root });
    try fields.append(a, .{ .relative = doc.assets.root, .pointer = "/assets/root", .kind = .assets_root });
    try fields.append(a, .{ .relative = doc.scripts.lua_root, .pointer = "/scripts/lua_root", .kind = .lua_root });
    try fields.append(a, .{ .relative = doc.scripts.cpp_root, .pointer = "/scripts/cpp_root", .kind = .cpp_root });

    var resources: std.ArrayList(Resource) = .empty;
    defer resources.deinit(a);

    for (fields.items) |field| {
        const joined = try std.fs.path.join(a, &.{ project_dir, field.relative });
        const real = Io.Dir.cwd().realPathFileAlloc(io, joined, a) catch |err| {
            diagnosticSet(diagnostic, field.pointer);
            return err;
        };
        ensureContained(real_project_dir, real) catch |err| {
            diagnosticSet(diagnostic, field.pointer);
            return err;
        };
        const is_dir = statIsDir(io, real) catch |err| {
            diagnosticSet(diagnostic, field.pointer);
            return err;
        };
        if (!is_dir) {
            diagnosticSet(diagnostic, field.pointer);
            return error.NotDir;
        }
        try resources.append(a, .{
            .kind = field.kind,
            .relative = field.relative,
            .absolute = real,
            .exists = true,
            .is_dir = true,
        });
    }

    // Startup scene: logical ticket, validated lexically inside scenes.root.
    // Verify its parent exists; if the file exists, resolve and contain it.
    {
        const joined = try std.fs.path.join(a, &.{ project_dir, doc.scenes.startup });
        const startup_dir = std.fs.path.dirname(joined) orelse project_dir;
        const real_dir = Io.Dir.cwd().realPathFileAlloc(io, startup_dir, a) catch |err| {
            diagnosticSet(diagnostic, "/scenes/startup");
            return err;
        };
        ensureContained(real_project_dir, real_dir) catch |err| {
            diagnosticSet(diagnostic, "/scenes/startup");
            return err;
        };
        const real_file = try resolveOptionalFile(a, io, real_project_dir, joined, "/scenes/startup", diagnostic);
        try resources.append(a, .{
            .kind = .startup_scene,
            .relative = doc.scenes.startup,
            .absolute = if (real_file) |file| file.absolute else joined,
            .exists = real_file != null,
            .is_dir = false,
            .file_metadata = if (real_file) |file| file.metadata else null,
        });
    }

    if (doc.scripts.lua_entry) |entry| {
        const joined = try std.fs.path.join(a, &.{ project_dir, entry });
        const entry_dir = std.fs.path.dirname(joined) orelse project_dir;
        const real_dir = Io.Dir.cwd().realPathFileAlloc(io, entry_dir, a) catch |err| {
            diagnosticSet(diagnostic, "/scripts/lua_entry");
            return err;
        };
        ensureContained(real_project_dir, real_dir) catch |err| {
            diagnosticSet(diagnostic, "/scripts/lua_entry");
            return err;
        };
        const real_file = try resolveOptionalFile(a, io, real_project_dir, joined, "/scripts/lua_entry", diagnostic);
        try resources.append(a, .{
            .kind = .lua_entry,
            .relative = entry,
            .absolute = if (real_file) |file| file.absolute else joined,
            .exists = real_file != null,
            .is_dir = false,
            .file_metadata = if (real_file) |file| file.metadata else null,
        });
    }

    if (doc.scripts.cpp_library) |lib| {
        // The schema stores a platform-neutral base; the product targets only
        // Windows (.dll) and Linux (.so), with no `lib` prefix inference.
        const suffix = switch (@import("builtin").os.tag) {
            .windows => ".dll",
            .linux => ".so",
            else => return error.UnsupportedHostPlatform,
        };
        const joined_base = try std.fs.path.join(a, &.{ project_dir, lib });
        const lib_dir = std.fs.path.dirname(joined_base) orelse project_dir;
        const real_dir = Io.Dir.cwd().realPathFileAlloc(io, lib_dir, a) catch |err| {
            diagnosticSet(diagnostic, "/scripts/cpp_library");
            return err;
        };
        ensureContained(real_project_dir, real_dir) catch |err| {
            diagnosticSet(diagnostic, "/scripts/cpp_library");
            return err;
        };
        const candidate = try std.fmt.allocPrint(a, "{s}{s}", .{ joined_base, suffix });
        const real_file = try resolveOptionalFile(a, io, real_project_dir, candidate, "/scripts/cpp_library", diagnostic);
        try resources.append(a, .{
            .kind = .cpp_library,
            .relative = lib,
            .absolute = if (real_file) |file| file.absolute else candidate,
            .exists = real_file != null,
            .is_dir = false,
            .file_metadata = if (real_file) |file| file.metadata else null,
        });
    }

    const owned_resources = try a.dupe(Resource, resources.items);
    // The second root is assets.root by the fixed field order above. Its files
    // are indexed for future content-browser use but are not load-progress tickets.
    const asset_inventory = try scanAssets(a, io, real_project_dir, resources.items[1].absolute, doc.assets.root, diagnostic);

    return Discovery{
        .arena = arena,
        .project_dir = project_dir,
        .real_project_dir = real_project_dir,
        .project_root_inode = project_root_stat.inode,
        .resources = owned_resources,
        .asset_files = asset_inventory.files,
        .asset_directories = asset_inventory.directories,
        .asset_root_inode = asset_inventory.root_inode,
    };
}

const test_allocator = std.testing.allocator;
const test_io = std.testing.io;

fn waitUntilAssetReadTerminal(task: *const AssetReadTask) !AssetReadStage {
    const deadline = Io.Clock.awake.now(test_io).nanoseconds + 5 * std.time.ns_per_s;
    while (true) {
        const current = task.stage() orelse return error.TaskConsumed;
        switch (current) {
            .complete, .failed, .canceled => return current,
            .queued, .reading => {},
        }
        if (Io.Clock.awake.now(test_io).nanoseconds >= deadline) return error.WorkerTimeout;
        try Io.sleep(test_io, .fromMilliseconds(2), .awake);
    }
}

const NoResizeAllocator = struct {
    backing: std.mem.Allocator,

    fn allocator(self: *NoResizeAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = alloc,
            .resize = std.mem.Allocator.noResize,
            .remap = std.mem.Allocator.noRemap,
            .free = free,
        } };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *NoResizeAllocator = @ptrCast(@alignCast(ctx));
        return self.backing.rawAlloc(len, alignment, ra);
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *NoResizeAllocator = @ptrCast(@alignCast(ctx));
        self.backing.rawFree(memory, alignment, ra);
    }
};

const AllocationContext = struct {
    io: Io,
    project_path: []const u8,
    project: app.project.Project,
};

fn allocationProbe(a: std.mem.Allocator, context: AllocationContext) !void {
    var diagnostic: app.project.Diagnostic = .{};
    var discovery = try discover(a, context.io, context.project_path, context.project, &diagnostic);
    defer discovery.deinit();
}

fn writeExampleProject(tmp: *std.testing.TmpDir, content: []const u8) ![]u8 {
    const a = test_allocator;
    try tmp.dir.writeFile(test_io, .{ .sub_path = "Example.proj", .data = content });
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(test_io, &buf);
    return std.fs.path.join(a, &.{ buf[0..n], "Example.proj" });
}

fn setupFullLayout(tmp: *std.testing.TmpDir) !void {
    // Create directories expected by Example.proj
    for ([_][]const u8{ "scenes", "assets", "scripts/cpp", "scripts/lua" }) |dir| {
        try tmp.dir.createDirPath(test_io, dir);
    }
    // Create dummy files that discovery does NOT require but we use for containment checks
    try tmp.dir.writeFile(test_io, .{ .sub_path = "scenes/README.md", .data = "scene placeholder" });
}

fn createAssetDepth(tmp: *std.testing.TmpDir, depth: usize) !void {
    var relative: std.ArrayList(u8) = .empty;
    defer relative.deinit(test_allocator);
    for (0..depth) |i| {
        if (i != 0) try relative.append(test_allocator, '/');
        try relative.appendSlice(test_allocator, "d");
    }
    const path = try std.fs.path.join(test_allocator, &.{ "assets", relative.items });
    defer test_allocator.free(path);
    try tmp.dir.createDirPath(test_io, path);
}

test "discovery succeeds for exemploproject layout" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try setupFullLayout(&tmp);
    try tmp.dir.createDirPath(test_io, "assets/nested");
    try tmp.dir.createDirPath(test_io, "assets/z-empty");
    try tmp.dir.createDirPath(test_io, "assets/a-empty");
    try tmp.dir.writeFile(test_io, .{ .sub_path = "assets/z-last.bin", .data = "z" });
    try tmp.dir.writeFile(test_io, .{ .sub_path = "assets/nested/a-first.bin", .data = "abc" });
    // Copy Example.proj content
    const example_path = try std.fs.path.join(test_allocator, &.{ @import("preflight_options").repository_root, "exemploproject", "Example.proj" });
    defer test_allocator.free(example_path);
    const bytes = try Io.Dir.cwd().readFileAlloc(test_io, example_path, test_allocator, .limited(1024 * 1024));
    defer test_allocator.free(bytes);
    const proj_path = try writeExampleProject(&tmp, bytes);
    defer test_allocator.free(proj_path);

    var diagnostic: app.project.Diagnostic = .{};
    var doc = try app.project.parse(test_allocator, bytes, &diagnostic);
    defer doc.deinit();

    var discovery = try discover(test_allocator, test_io, proj_path, doc.value, &diagnostic);
    defer discovery.deinit();

    // 4 dirs + startup = 5 resources (no optional)
    try std.testing.expectEqual(@as(usize, 5), discovery.resources.len);
    try std.testing.expectEqualStrings("scenes", discovery.resources[0].relative);
    try std.testing.expect(discovery.resources[0].is_dir);
    try std.testing.expectEqualStrings("scenes/Main.scene", discovery.resources[4].relative);
    try std.testing.expect(!discovery.resources[4].exists);
    try std.testing.expectError(error.ResourceNotPresent, discovery.openResourceFile(test_io, .startup_scene));
    try std.testing.expectEqual(@as(usize, 2), discovery.asset_files.len);
    try std.testing.expectEqualStrings("assets/nested/a-first.bin", discovery.asset_files[0].relative);
    try std.testing.expectEqual(@as(u64, 3), discovery.asset_files[0].size_bytes);
    try std.testing.expectEqualStrings("assets/z-last.bin", discovery.asset_files[1].relative);
    try std.testing.expectEqual(@as(usize, 5), discovery.resourceCount());
    try std.testing.expectEqual(@as(usize, 2), discovery.assetCount());
    try std.testing.expectEqual(@as(usize, 3), discovery.assetDirectoryCount());
    try std.testing.expectEqualStrings("assets/a-empty", discovery.asset_directories[0].relative);
    try std.testing.expectEqualStrings("assets/nested", discovery.asset_directories[1].relative);
    try std.testing.expectEqualStrings("assets/z-empty", discovery.asset_directories[2].relative);
    try std.testing.expect(discovery.findAssetDirectory("assets/nested") != null);
    try std.testing.expect(discovery.findAssetDirectory("assets/missing") == null);
    var root_children = discovery.assetChildren("assets").?;
    for ([_][]const u8{ "assets/a-empty", "assets/nested", "assets/z-empty", "assets/z-last.bin" }) |expected_path| {
        const child = root_children.next().?;
        const actual_path = switch (child) {
            .file => |entry| entry.relative,
            .directory => |directory| directory.relative,
        };
        try std.testing.expectEqualStrings(expected_path, actual_path);
    }
    try std.testing.expect(root_children.next() == null);
    var nested_children = discovery.assetChildren("assets/nested").?;
    const nested_child = nested_children.next().?;
    try std.testing.expectEqualStrings("assets/nested/a-first.bin", nested_child.file.relative);
    try std.testing.expect(nested_children.next() == null);
    var empty_children = discovery.assetChildren("assets/a-empty").?;
    try std.testing.expect(empty_children.next() == null);
    try std.testing.expect(discovery.assetChildren("assets/not-indexed") == null);
    try discovery.verifyAssetDirectorySnapshot(test_allocator, test_io, "assets/nested");
    try std.testing.expectError(error.OutOfMemory, discovery.verifyAssetDirectorySnapshot(std.testing.failing_allocator, test_io, "assets/nested"));
    try std.testing.expectError(error.AssetDirectoryNotIndexed, discovery.verifyAssetDirectorySnapshot(test_allocator, test_io, "assets/not-indexed"));
    try std.testing.expectEqual(@as(u64, 3), discovery.findAsset("assets/nested/a-first.bin").?.size_bytes);
    try std.testing.expect(discovery.findAsset("assets/missing.bin") == null);
    try discovery.verifyAssetSnapshot(test_allocator, test_io, "assets/nested/a-first.bin");
    {
        var opened = try discovery.openAsset(test_io, "assets/nested/a-first.bin");
        defer opened.close(test_io);
        const opened_stat = try opened.stat(test_io);
        try std.testing.expectEqual(@as(u64, 3), opened_stat.size);
    }
    const asset_bytes = try discovery.readAssetAlloc(test_allocator, test_io, "assets/nested/a-first.bin", 3);
    defer test_allocator.free(asset_bytes);
    try std.testing.expectEqualStrings("abc", asset_bytes);
    try std.testing.expectError(error.OutOfMemory, discovery.readAssetAlloc(std.testing.failing_allocator, test_io, "assets/nested/a-first.bin", 3));
    try std.testing.expectError(error.AssetTooLarge, discovery.readAssetAlloc(test_allocator, test_io, "assets/nested/a-first.bin", 2));
    var async_read = try AssetReadTask.start(test_allocator, test_io, &discovery, "assets/nested/a-first.bin", 3);
    defer async_read.deinit();
    try std.testing.expectEqual(AssetReadStage.complete, try waitUntilAssetReadTerminal(&async_read));
    const async_result = try async_read.take();
    switch (async_result) {
        .bytes => |payload| {
            defer test_allocator.free(payload);
            try std.testing.expectEqualStrings("abc", payload);
        },
        .failed => return error.AssetReadFailed,
    }
    try std.testing.expectError(error.TaskConsumed, async_read.take());
    var abandoned_read = try AssetReadTask.start(test_allocator, test_io, &discovery, "assets/nested/a-first.bin", 3);
    defer abandoned_read.deinit();
    try std.testing.expectEqual(AssetReadStage.complete, try waitUntilAssetReadTerminal(&abandoned_read));
    abandoned_read.deinit();
    try std.testing.expect(abandoned_read.stage() == null);
    var limited_read = try AssetReadTask.start(test_allocator, test_io, &discovery, "assets/nested/a-first.bin", 2);
    defer limited_read.deinit();
    try std.testing.expectEqual(AssetReadStage.failed, try waitUntilAssetReadTerminal(&limited_read));
    switch (try limited_read.take()) {
        .bytes => |payload| {
            test_allocator.free(payload);
            return error.ExpectedReadLimitFailure;
        },
        .failed => |failure| try std.testing.expectEqual(error.AssetTooLarge, failure),
    }
    try std.testing.expectError(error.AssetNotIndexed, AssetReadTask.start(test_allocator, test_io, &discovery, "assets/not-indexed.bin", 1));
    try tmp.dir.writeFile(test_io, .{ .sub_path = "assets/replacement.bin", .data = "xyz" });
    try tmp.dir.deleteFile(test_io, "assets/nested/a-first.bin");
    try tmp.dir.rename("assets/replacement.bin", tmp.dir, "assets/nested/a-first.bin", test_io);
    try std.testing.expectError(error.AssetSnapshotStale, discovery.verifyAssetSnapshot(test_allocator, test_io, "assets/nested/a-first.bin"));
    try std.testing.expectError(error.AssetSnapshotStale, discovery.openAsset(test_io, "assets/nested/a-first.bin"));
    try std.testing.expectError(error.AssetSnapshotStale, discovery.readAssetAlloc(test_allocator, test_io, "assets/nested/a-first.bin", 3));
    try std.testing.expectError(error.OutOfMemory, discovery.verifyAssetSnapshot(std.testing.failing_allocator, test_io, "assets/nested/a-first.bin"));
    try std.testing.expectError(error.AssetNotIndexed, discovery.verifyAssetSnapshot(test_allocator, test_io, "assets/not-indexed.bin"));
    try tmp.dir.writeFile(test_io, .{ .sub_path = "assets/nested/a-first.bin", .data = "changed-size" });
    try std.testing.expectError(error.AssetSnapshotStale, discovery.verifyAssetSnapshot(test_allocator, test_io, "assets/nested/a-first.bin"));
    try tmp.dir.rename("assets/nested", tmp.dir, "assets/nested-old", test_io);
    try tmp.dir.createDirPath(test_io, "assets/nested");
    try std.testing.expectError(error.AssetDirectorySnapshotStale, discovery.verifyAssetDirectorySnapshot(test_allocator, test_io, "assets/nested"));
    var outside = std.testing.tmpDir(.{});
    defer outside.cleanup();
    try outside.dir.createDirPath(test_io, "linked");
    var outside_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const outside_path_len = try outside.dir.realPath(test_io, &outside_path_buf);
    const linked_path = try std.fs.path.join(test_allocator, &.{ outside_path_buf[0..outside_path_len], "linked" });
    defer test_allocator.free(linked_path);
    try tmp.dir.deleteTree(test_io, "assets/nested");
    try tmp.dir.symLink(test_io, linked_path, "assets/nested", .{});
    try std.testing.expectError(error.AssetSnapshotStale, discovery.openAsset(test_io, "assets/nested/a-first.bin"));
}

test "discovery fails when required directory missing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // Only create 3 of 4 required dirs, leave assets missing
    for ([_][]const u8{ "scenes", "scripts/cpp", "scripts/lua" }) |dir| try tmp.dir.createDirPath(test_io, dir);

    const example_path = try std.fs.path.join(test_allocator, &.{ @import("preflight_options").repository_root, "exemploproject", "Example.proj" });
    defer test_allocator.free(example_path);
    const bytes = try Io.Dir.cwd().readFileAlloc(test_io, example_path, test_allocator, .limited(1024 * 1024));
    defer test_allocator.free(bytes);
    const proj_path = try writeExampleProject(&tmp, bytes);
    defer test_allocator.free(proj_path);

    var diagnostic: app.project.Diagnostic = .{};
    var doc = try app.project.parse(test_allocator, bytes, &diagnostic);
    defer doc.deinit();

    try std.testing.expectError(error.FileNotFound, discover(test_allocator, test_io, proj_path, doc.value, &diagnostic));
    try std.testing.expectEqualStrings("/assets/root", diagnostic.pointer());
}

test "asset inventory accepts depth limit and rejects deeper entries" {
    const example_path = try std.fs.path.join(test_allocator, &.{ @import("preflight_options").repository_root, "exemploproject", "Example.proj" });
    defer test_allocator.free(example_path);
    const bytes = try Io.Dir.cwd().readFileAlloc(test_io, example_path, test_allocator, .limited(1024 * 1024));
    defer test_allocator.free(bytes);
    var diagnostic: app.project.Diagnostic = .{};
    var doc = try app.project.parse(test_allocator, bytes, &diagnostic);
    defer doc.deinit();

    var at_limit = std.testing.tmpDir(.{});
    defer at_limit.cleanup();
    try setupFullLayout(&at_limit);
    try createAssetDepth(&at_limit, max_asset_depth);
    const valid_path = try writeExampleProject(&at_limit, bytes);
    defer test_allocator.free(valid_path);
    var valid = try discover(test_allocator, test_io, valid_path, doc.value, &diagnostic);
    defer valid.deinit();
    try std.testing.expectEqual(@as(usize, 0), valid.assetCount());

    var too_deep = std.testing.tmpDir(.{});
    defer too_deep.cleanup();
    try setupFullLayout(&too_deep);
    try createAssetDepth(&too_deep, max_asset_depth + 1);
    const invalid_path = try writeExampleProject(&too_deep, bytes);
    defer test_allocator.free(invalid_path);
    try std.testing.expectError(error.AssetDepthExceeded, discover(test_allocator, test_io, invalid_path, doc.value, &diagnostic));
    try std.testing.expectEqualStrings("/assets/root", diagnostic.pointer());
}

test "asset inventory refuses linked directories without traversing them" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try setupFullLayout(&tmp);
    var outside = std.testing.tmpDir(.{});
    defer outside.cleanup();
    try outside.dir.createDirPath(test_io, "nested");
    try outside.dir.writeFile(test_io, .{ .sub_path = "nested/secret.bin", .data = "outside" });
    var target_buf: [std.fs.max_path_bytes]u8 = undefined;
    const target_len = try outside.dir.realPath(test_io, &target_buf);
    const target = try std.fs.path.join(test_allocator, &.{ target_buf[0..target_len], "nested" });
    defer test_allocator.free(target);
    try tmp.dir.symLink(test_io, target, "assets/linked-dir", .{});

    const example_path = try std.fs.path.join(test_allocator, &.{ @import("preflight_options").repository_root, "exemploproject", "Example.proj" });
    defer test_allocator.free(example_path);
    const bytes = try Io.Dir.cwd().readFileAlloc(test_io, example_path, test_allocator, .limited(1024 * 1024));
    defer test_allocator.free(bytes);
    const proj_path = try writeExampleProject(&tmp, bytes);
    defer test_allocator.free(proj_path);
    var diagnostic: app.project.Diagnostic = .{};
    var doc = try app.project.parse(test_allocator, bytes, &diagnostic);
    defer doc.deinit();

    try std.testing.expectError(error.AssetSymlinkNotAllowed, discover(test_allocator, test_io, proj_path, doc.value, &diagnostic));
    try std.testing.expectEqualStrings("/assets/root", diagnostic.pointer());
}

test "asset inventory fails closed on nonportable Unicode paths" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try setupFullLayout(&tmp);
    try tmp.dir.writeFile(test_io, .{ .sub_path = "assets/ação.bin", .data = "asset" });

    const example_path = try std.fs.path.join(test_allocator, &.{ @import("preflight_options").repository_root, "exemploproject", "Example.proj" });
    defer test_allocator.free(example_path);
    const bytes = try Io.Dir.cwd().readFileAlloc(test_io, example_path, test_allocator, .limited(1024 * 1024));
    defer test_allocator.free(bytes);
    const proj_path = try writeExampleProject(&tmp, bytes);
    defer test_allocator.free(proj_path);
    var diagnostic: app.project.Diagnostic = .{};
    var doc = try app.project.parse(test_allocator, bytes, &diagnostic);
    defer doc.deinit();

    try std.testing.expectError(error.UnsupportedAssetPath, discover(test_allocator, test_io, proj_path, doc.value, &diagnostic));
    try std.testing.expectEqualStrings("/assets/root", diagnostic.pointer());
}

test "asset inventory refuses symlinks instead of following them" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try setupFullLayout(&tmp);
    var outside = std.testing.tmpDir(.{});
    defer outside.cleanup();
    try outside.dir.writeFile(test_io, .{ .sub_path = "outside.bin", .data = "outside" });
    var target_buf: [std.fs.max_path_bytes]u8 = undefined;
    const target_len = try outside.dir.realPath(test_io, &target_buf);
    const target = try std.fs.path.join(test_allocator, &.{ target_buf[0..target_len], "outside.bin" });
    defer test_allocator.free(target);
    try tmp.dir.symLink(test_io, target, "assets/link.bin", .{});

    const example_path = try std.fs.path.join(test_allocator, &.{ @import("preflight_options").repository_root, "exemploproject", "Example.proj" });
    defer test_allocator.free(example_path);
    const bytes = try Io.Dir.cwd().readFileAlloc(test_io, example_path, test_allocator, .limited(1024 * 1024));
    defer test_allocator.free(bytes);
    const proj_path = try writeExampleProject(&tmp, bytes);
    defer test_allocator.free(proj_path);
    var diagnostic: app.project.Diagnostic = .{};
    var doc = try app.project.parse(test_allocator, bytes, &diagnostic);
    defer doc.deinit();

    try std.testing.expectError(error.AssetSymlinkNotAllowed, discover(test_allocator, test_io, proj_path, doc.value, &diagnostic));
    try std.testing.expectEqualStrings("/assets/root", diagnostic.pointer());
}

test "discovery rejects path traversal via symlink escape" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try setupFullLayout(&tmp);
    // Create outside dir that will be symlink target
    var outside = std.testing.tmpDir(.{});
    defer outside.cleanup();
    try outside.dir.createDirPath(test_io, "evil");
    var buf_out: [std.fs.max_path_bytes]u8 = undefined;
    const n_out = try outside.dir.realPath(test_io, &buf_out);
    const outside_path = buf_out[0..n_out];

    // Create symlink inside tmp pointing outside: tmp/scenes -> outside/evil
    // Use symlink in the tmp dir: replace scenes dir with symlink
    // First remove scenes dir and create symlink
    try tmp.dir.deleteTree(test_io, "scenes");
    const target = try std.fs.path.join(test_allocator, &.{ outside_path, "evil" });
    defer test_allocator.free(target);
    try tmp.dir.symLink(test_io, target, "scenes", .{});

    const example_path = try std.fs.path.join(test_allocator, &.{ @import("preflight_options").repository_root, "exemploproject", "Example.proj" });
    defer test_allocator.free(example_path);
    const bytes = try Io.Dir.cwd().readFileAlloc(test_io, example_path, test_allocator, .limited(1024 * 1024));
    defer test_allocator.free(bytes);
    const proj_path = try writeExampleProject(&tmp, bytes);
    defer test_allocator.free(proj_path);

    var diagnostic: app.project.Diagnostic = .{};
    var doc = try app.project.parse(test_allocator, bytes, &diagnostic);
    defer doc.deinit();

    // Should fail containment check with a field-level diagnostic.
    try std.testing.expectError(error.ContainmentBreach, discover(test_allocator, test_io, proj_path, doc.value, &diagnostic));
    try std.testing.expectEqualStrings("/scenes/root", diagnostic.pointer());
}

test "existing startup scene must be regular and cannot escape through a symlink" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try setupFullLayout(&tmp);
    var outside = std.testing.tmpDir(.{});
    defer outside.cleanup();
    try outside.dir.writeFile(test_io, .{ .sub_path = "Evil.scene", .data = "not a real scene" });
    var outside_buf: [std.fs.max_path_bytes]u8 = undefined;
    const outside_len = try outside.dir.realPath(test_io, &outside_buf);
    const outside_file = try std.fs.path.join(test_allocator, &.{ outside_buf[0..outside_len], "Evil.scene" });
    defer test_allocator.free(outside_file);
    try tmp.dir.symLink(test_io, outside_file, "scenes/Main.scene", .{});

    const example_path = try std.fs.path.join(test_allocator, &.{ @import("preflight_options").repository_root, "exemploproject", "Example.proj" });
    defer test_allocator.free(example_path);
    const bytes = try Io.Dir.cwd().readFileAlloc(test_io, example_path, test_allocator, .limited(1024 * 1024));
    defer test_allocator.free(bytes);
    const proj_path = try writeExampleProject(&tmp, bytes);
    defer test_allocator.free(proj_path);
    var diagnostic: app.project.Diagnostic = .{};
    var doc = try app.project.parse(test_allocator, bytes, &diagnostic);
    defer doc.deinit();

    try std.testing.expectError(error.ContainmentBreach, discover(test_allocator, test_io, proj_path, doc.value, &diagnostic));
    try std.testing.expectEqualStrings("/scenes/startup", diagnostic.pointer());
}

test "a directory cannot stand in for the startup scene file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try setupFullLayout(&tmp);
    try tmp.dir.createDirPath(test_io, "scenes/Main.scene");

    const example_path = try std.fs.path.join(test_allocator, &.{ @import("preflight_options").repository_root, "exemploproject", "Example.proj" });
    defer test_allocator.free(example_path);
    const bytes = try Io.Dir.cwd().readFileAlloc(test_io, example_path, test_allocator, .limited(1024 * 1024));
    defer test_allocator.free(bytes);
    const proj_path = try writeExampleProject(&tmp, bytes);
    defer test_allocator.free(proj_path);
    var diagnostic: app.project.Diagnostic = .{};
    var doc = try app.project.parse(test_allocator, bytes, &diagnostic);
    defer doc.deinit();

    try std.testing.expectError(error.NotFile, discover(test_allocator, test_io, proj_path, doc.value, &diagnostic));
    try std.testing.expectEqualStrings("/scenes/startup", diagnostic.pointer());
}

test "existing startup scene is reported but never claimed as loaded" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try setupFullLayout(&tmp);
    try tmp.dir.writeFile(test_io, .{ .sub_path = "scenes/Main.scene", .data = "test-only placeholder" });

    const example_path = try std.fs.path.join(test_allocator, &.{ @import("preflight_options").repository_root, "exemploproject", "Example.proj" });
    defer test_allocator.free(example_path);
    const bytes = try Io.Dir.cwd().readFileAlloc(test_io, example_path, test_allocator, .limited(1024 * 1024));
    defer test_allocator.free(bytes);
    const proj_path = try writeExampleProject(&tmp, bytes);
    defer test_allocator.free(proj_path);
    var diagnostic: app.project.Diagnostic = .{};
    var doc = try app.project.parse(test_allocator, bytes, &diagnostic);
    defer doc.deinit();

    var discovery = try discover(test_allocator, test_io, proj_path, doc.value, &diagnostic);
    defer discovery.deinit();
    const startup = discovery.resources[4];
    try std.testing.expect(startup.exists);
    try std.testing.expect(!startup.is_dir);
    try std.testing.expectEqual(ResourceKind.startup_scene, startup.kind);
    {
        var opened = try discovery.openResourceFile(test_io, .startup_scene);
        defer opened.close(test_io);
        try std.testing.expectEqual(@as(u64, "test-only placeholder".len), (try opened.stat(test_io)).size);
    }
    const startup_bytes = try discovery.readResourceAlloc(test_allocator, test_io, .startup_scene, "test-only placeholder".len);
    defer test_allocator.free(startup_bytes);
    try std.testing.expectEqualStrings("test-only placeholder", startup_bytes);
    try std.testing.expectError(error.ResourceTooLarge, discovery.readResourceAlloc(test_allocator, test_io, .startup_scene, "test-only placeholder".len - 1));
    var outside = std.testing.tmpDir(.{});
    defer outside.cleanup();
    try outside.dir.writeFile(test_io, .{ .sub_path = "replacement.scene", .data = "external scene" });
    var outside_buf: [std.fs.max_path_bytes]u8 = undefined;
    const outside_len = try outside.dir.realPath(test_io, &outside_buf);
    const outside_file = try std.fs.path.join(test_allocator, &.{ outside_buf[0..outside_len], "replacement.scene" });
    defer test_allocator.free(outside_file);
    try tmp.dir.deleteFile(test_io, "scenes/Main.scene");
    try tmp.dir.symLink(test_io, outside_file, "scenes/Main.scene", .{});
    try std.testing.expectError(error.ResourceSnapshotStale, discovery.openResourceFile(test_io, .startup_scene));
    try std.testing.expectError(error.ResourceSnapshotStale, discovery.readResourceAlloc(test_allocator, test_io, .startup_scene, 1024));
}

test "discovery rejects a required directory path that names a regular file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(test_io, "scenes");
    try tmp.dir.writeFile(test_io, .{ .sub_path = "assets", .data = "not a directory" });
    try tmp.dir.createDirPath(test_io, "scripts/cpp");
    try tmp.dir.createDirPath(test_io, "scripts/lua");

    const example_path = try std.fs.path.join(test_allocator, &.{ @import("preflight_options").repository_root, "exemploproject", "Example.proj" });
    defer test_allocator.free(example_path);
    const bytes = try Io.Dir.cwd().readFileAlloc(test_io, example_path, test_allocator, .limited(1024 * 1024));
    defer test_allocator.free(bytes);
    const proj_path = try writeExampleProject(&tmp, bytes);
    defer test_allocator.free(proj_path);

    var diagnostic: app.project.Diagnostic = .{};
    var doc = try app.project.parse(test_allocator, bytes, &diagnostic);
    defer doc.deinit();

    try std.testing.expectError(error.NotDir, discover(test_allocator, test_io, proj_path, doc.value, &diagnostic));
    try std.testing.expectEqualStrings("/assets/root", diagnostic.pointer());
}

test "discovery includes optional lua entry and cpp library when present" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try setupFullLayout(&tmp);

    const example_path = try std.fs.path.join(test_allocator, &.{ @import("preflight_options").repository_root, "exemploproject", "Example.proj" });
    defer test_allocator.free(example_path);
    const bytes = try Io.Dir.cwd().readFileAlloc(test_io, example_path, test_allocator, .limited(1024 * 1024));
    defer test_allocator.free(bytes);

    // Modify document to include optional fields
    var diagnostic: app.project.Diagnostic = .{};
    var doc = try app.project.parse(test_allocator, bytes, &diagnostic);
    defer doc.deinit();
    doc.value.scripts.lua_entry = "scripts/lua/main.lua";
    doc.value.scripts.cpp_module = .dynamic;
    doc.value.scripts.cpp_library = "scripts/cpp/gameplay";
    // Ensure parent dirs exist already
    try tmp.dir.writeFile(test_io, .{ .sub_path = "scripts/lua/main.lua", .data = "-- lua" });
    try tmp.dir.writeFile(test_io, .{ .sub_path = "scripts/cpp/gameplay.so", .data = "test-only library placeholder" });

    const proj_path = try writeExampleProject(&tmp, bytes);
    defer test_allocator.free(proj_path);
    // Need to re-parse with overrides? Instead directly call discover with modified doc
    var d2: app.project.Diagnostic = .{};
    var discovery = try discover(test_allocator, test_io, proj_path, doc.value, &d2);
    defer discovery.deinit();
    // 4 dirs + startup + lua_entry + cpp_library = 7
    try std.testing.expectEqual(@as(usize, 7), discovery.resources.len);
    try std.testing.expectEqual(ResourceKind.lua_entry, discovery.resources[5].kind);
    try std.testing.expect(discovery.resources[5].exists);
    var opened_lua = try discovery.openResourceFile(test_io, .lua_entry);
    defer opened_lua.close(test_io);
    try std.testing.expectEqual(@as(u64, "-- lua".len), (try opened_lua.stat(test_io)).size);
    try std.testing.expectEqual(ResourceKind.cpp_library, discovery.resources[6].kind);
    try std.testing.expect(discovery.resources[6].exists);
    try std.testing.expect(std.mem.endsWith(u8, discovery.resources[6].absolute, "gameplay.so"));
    var opened_library = try discovery.openResourceFile(test_io, .cpp_library);
    defer opened_library.close(test_io);
    try std.testing.expectEqual(@as(u64, "test-only library placeholder".len), (try opened_library.stat(test_io)).size);
}

test "discovery allocation failures are clean" {
    const example_path = try std.fs.path.join(test_allocator, &.{ @import("preflight_options").repository_root, "exemploproject", "Example.proj" });
    defer test_allocator.free(example_path);
    const real_project = try Io.Dir.cwd().realPathFileAlloc(test_io, example_path, test_allocator);
    defer test_allocator.free(real_project);
    const bytes = try Io.Dir.cwd().readFileAlloc(test_io, real_project, test_allocator, .limited(1024 * 1024));
    defer test_allocator.free(bytes);
    var diagnostic: app.project.Diagnostic = .{};
    var doc = try app.project.parse(test_allocator, bytes, &diagnostic);
    defer doc.deinit();

    // The repository example has the required directory layout and exercises
    // every allocation point in discovery under the no-resize failure matrix.
    var backing: NoResizeAllocator = .{ .backing = test_allocator };
    try std.testing.checkAllAllocationFailures(backing.allocator(), allocationProbe, .{
        .{ .io = test_io, .project_path = real_project, .project = doc.value },
    });
}

test "containment compares path components and handles filesystem roots" {
    try std.testing.expect(isPrefix("/project", "/project/assets"));
    try std.testing.expect(!isPrefix("/project", "/project-other/assets"));
    if (std.fs.path.sep == '/') {
        try std.testing.expect(isPrefix("/", "/project/assets"));
    }
}
