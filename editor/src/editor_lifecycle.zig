//! Editor lifecycle bridge: the Editor adopts the shared Core lifecycle.
//!
//! The concrete `editor.session` subsystem (see `editor_session.zig`) drives
//! project document loading, scope policy, and distribution verification
//! through a `core.subsystem.Registry`. Not a GUI, scene editor, or GPU path.
const std = @import("std");
const core = @import("corex_core");
const session_mod = @import("editor_session.zig");

pub const Session = session_mod.Session;
pub const EditorRegistry = session_mod.EditorRegistry;
pub const Phase = session_mod.Phase;

/// Convenience wrapper that owns a session and its registry, matching the
/// Runtime integration pattern. The Editor currently runs as a validation
/// bootstrap; this type is the concrete Core consumer for a future Editor.
pub const EditorLifecycle = struct {
    registry: EditorRegistry = .{},
    session: Session,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) EditorLifecycle {
        return .{ .session = Session.init(allocator, io) };
    }

    pub fn registerSession(self: *EditorLifecycle, project_path: []const u8) !void {
        self.session.project_path = project_path;
        try self.registry.register(core.subsystem.Subsystem.adopt(Session, "editor.session", &self.session));
    }
};

test "EditorLifecycle registers and runs the session subsystem" {
    const path = try std.fs.path.join(std.testing.allocator, &.{ @import("preflight_options").repository_root, "exemploproject", "Example.proj" });
    defer std.testing.allocator.free(path);

    var lifecycle = EditorLifecycle.init(std.testing.allocator, std.testing.io);
    try lifecycle.registerSession(path);
    try std.testing.expectEqual(@as(usize, 1), lifecycle.registry.systemCount());
    try lifecycle.registry.start();
    try std.testing.expectEqual(Phase.document_loaded, lifecycle.session.phase);
    try lifecycle.registry.stop();
}
