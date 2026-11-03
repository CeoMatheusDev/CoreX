//! Editor session subsystem: the first concrete Core consumer in the Editor.
//!
//! This bridges the Editor's project-opening coordinator to the shared Core
//! lifecycle. It owns a `core.subsystem.Registry` and exposes the concrete
//! editor phase (document loaded, scope policy, distribution) as a subsystem
//! named `editor.session`. It is not a GUI, scene editor, or GPU consumer.
const std = @import("std");
const core = @import("corex_core");
const app = @import("corex_app");
const opening = @import("project_opening.zig");
const workspace = @import("workspace.zig");

pub const SessionError = error{
    DocumentNotLoaded,
    ScopePolicyViolation,
    DistributionMismatch,
};

/// Concrete editor phase tracked by the session subsystem.
pub const Phase = enum {
    created,
    document_loaded,
    scope_applied,
    distribution_verified,
    ready,
};

/// The editor session subsystem. Registered into a `core.subsystem.Registry`
/// via `Subsystem.adopt`; `start`/`step`/`stop` follow the Core contract.
pub const Session = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    project_path: ?[]const u8 = null,
    opening: ?opening.Opening = null,
    workspace: workspace.State = .{},
    phase: Phase = .created,
    scope_profile: []const u8 = app.scope.profile_id,
    distribution_compatibility: ?app.distribution.Compatibility = null,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) Session {
        return .{ .allocator = allocator, .io = io };
    }

    /// Core subsystem contract: starts the session by loading the project
    /// document. On success the phase becomes `document_loaded`.
    pub fn start(self: *Session) anyerror!void {
        const path = self.project_path orelse return error.DocumentNotLoaded;
        self.opening = try opening.Opening.start(self.allocator, self.io, path);
        // Poll until the document phase resolves (bounded in tests by the
        // caller's deadline; in production the Editor loop drives it).
        while (self.opening.?.phase == .document) {
            try self.opening.?.pollDocument();
            if (self.opening.?.phase != .document) break;
            try std.Io.sleep(self.io, .fromMilliseconds(2), .awake);
        }
        switch (self.opening.?.phase) {
            .discovery => {
                self.phase = .document_loaded;
            },
            .failed => return self.opening.?.failure orelse error.DocumentNotLoaded,
            .canceled => return error.Canceled,
            else => return error.DocumentNotLoaded,
        }
    }

    /// Core subsystem contract: one editor step. Applies scope policy and
    /// verifies distribution on the first step after document load.
    pub fn step(self: *Session, descriptor: core.subsystem.Step) anyerror!void {
        _ = descriptor;
        switch (self.phase) {
            .document_loaded => {
                try self.applyScopePolicy();
                self.phase = .scope_applied;
            },
            .scope_applied => {
                try self.verifyDistribution();
                self.phase = .distribution_verified;
            },
            .distribution_verified => {
                self.phase = .ready;
            },
            else => {},
        }
    }

    /// Core subsystem contract: teardown. Always succeeds.
    pub fn stop(self: *Session) void {
        if (self.opening) |*op| {
            op.deinit();
            self.opening = null;
        }
        self.phase = .created;
    }

    fn applyScopePolicy(self: *Session) SessionError!void {
        if (self.opening == null) return error.DocumentNotLoaded;
        if (self.opening.?.project() == null) return error.DocumentNotLoaded;
        // The scope profile must match the product policy.
        if (!std.mem.eql(u8, self.scope_profile, app.scope.profile_id)) {
            return error.ScopePolicyViolation;
        }
        // The workspace authoring domain must be a valid product domain.
        _ = app.scope.parseDomain(@tagName(self.workspace.domain)) catch return error.ScopePolicyViolation;
    }

    fn verifyDistribution(self: *Session) SessionError!void {
        const proj = if (self.opening) |*op| op.project() orelse return error.DocumentNotLoaded else return error.DocumentNotLoaded;
        const compatibility = app.distribution.classify(proj.*.engine.version);
        self.distribution_compatibility = compatibility;
        if (compatibility == .incompatible) return error.DistributionMismatch;
    }

    pub fn snapshot(self: *const Session) Snapshot {
        return .{
            .phase = self.phase,
            .workspace_domain = self.workspace.domain,
            .workspace_tool = self.workspace.tool,
            .compatibility = self.distribution_compatibility,
            .scope_profile = self.scope_profile,
        };
    }
};

pub const Snapshot = struct {
    phase: Phase,
    workspace_domain: workspace.Domain,
    workspace_tool: workspace.Tool,
    compatibility: ?app.distribution.Compatibility,
    scope_profile: []const u8,
};

/// A `core.subsystem.Registry` preconfigured for the Editor with capacity for
/// the session subsystem plus room for future editor subsystems.
pub const EditorRegistry = core.subsystem.Registry(4);

const testing = std.testing;
const test_allocator = testing.allocator;
const test_io = testing.io;

fn examplePath() ![]u8 {
    return std.fs.path.join(test_allocator, &.{ @import("preflight_options").repository_root, "exemploproject", "Example.proj" });
}

test "session starts, steps through phases and stops cleanly" {
    const path = try examplePath();
    defer test_allocator.free(path);

    var session = Session.init(test_allocator, test_io);
    session.project_path = path;

    try session.start();
    try testing.expectEqual(Phase.document_loaded, session.phase);

    try session.step(.{ .index = 0, .dt_ns = 16_666_666 });
    try testing.expectEqual(Phase.scope_applied, session.phase);

    try session.step(.{ .index = 1, .dt_ns = 16_666_666 });
    try testing.expectEqual(Phase.distribution_verified, session.phase);
    try testing.expect(session.snapshot().compatibility != null);

    try session.step(.{ .index = 2, .dt_ns = 16_666_666 });
    try testing.expectEqual(Phase.ready, session.phase);

    session.stop();
    try testing.expectEqual(Phase.created, session.phase);
    try testing.expect(session.opening == null);
}

test "session works inside a core Registry with deterministic ordering" {
    const path = try examplePath();
    defer test_allocator.free(path);

    var session = Session.init(test_allocator, test_io);
    session.project_path = path;

    var registry = EditorRegistry{};
    try registry.register(core.subsystem.Subsystem.adopt(Session, "editor.session", &session));
    try testing.expectEqual(@as(usize, 1), registry.systemCount());

    try registry.start();
    try testing.expectEqual(core.subsystem.State.running, registry.state());
    try testing.expectEqual(Phase.document_loaded, session.phase);

    try registry.step(.{ .index = 0, .dt_ns = 16_666_666 });
    try registry.step(.{ .index = 1, .dt_ns = 16_666_666 });
    try registry.step(.{ .index = 2, .dt_ns = 16_666_666 });
    try testing.expectEqual(Phase.ready, session.phase);

    try registry.stop();
    try testing.expectEqual(core.subsystem.State.stopped, registry.state());
    try testing.expectEqual(Phase.created, session.phase);
}

test "start without a project path fails with DocumentNotLoaded" {
    var session = Session.init(test_allocator, test_io);
    try testing.expectError(error.DocumentNotLoaded, session.start());
}
