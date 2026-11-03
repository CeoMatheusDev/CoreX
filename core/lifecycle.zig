//! Lifecycle states shared by every CoreX application.
//!
//! The machine is deliberately narrow: an instance starts at most once, a
//! failed start still requires teardown, and no state resurrects. Anything that
//! needs to start again has to build a new instance, which keeps resource
//! ownership unambiguous.
const std = @import("std");

pub const State = enum {
    created,
    starting,
    running,
    stopping,
    stopped,
    failed,
};

pub const TransitionError = error{InvalidTransition};

pub const Lifecycle = struct {
    state: State = .created,

    pub fn isRunning(self: *const Lifecycle) bool {
        return self.state == .running;
    }

    /// `created` is the only startable state.
    pub fn beginStart(self: *Lifecycle) TransitionError!void {
        if (self.state != .created) return error.InvalidTransition;
        self.state = .starting;
    }

    /// Only a fully started application runs; a partial start never does.
    pub fn markRunning(self: *Lifecycle) TransitionError!void {
        if (self.state != .starting) return error.InvalidTransition;
        self.state = .running;
    }

    /// A failed start or a failed step still has to release what it acquired,
    /// so `failed` is allowed to move into teardown.
    pub fn beginStop(self: *Lifecycle) TransitionError!void {
        if (self.state != .running and self.state != .failed) return error.InvalidTransition;
        self.state = .stopping;
    }

    pub fn markStopped(self: *Lifecycle) TransitionError!void {
        if (self.state != .stopping) return error.InvalidTransition;
        self.state = .stopped;
    }

    /// Records a start or step failure without skipping teardown.
    pub fn fail(self: *Lifecycle) TransitionError!void {
        if (self.state != .starting and self.state != .running) return error.InvalidTransition;
        self.state = .failed;
    }
};

const testing = std.testing;

test "the only successful path is created to stopped" {
    var lifecycle: Lifecycle = .{};
    try testing.expectEqual(State.created, lifecycle.state);
    try lifecycle.beginStart();
    try testing.expectEqual(State.starting, lifecycle.state);
    try lifecycle.markRunning();
    try testing.expect(lifecycle.isRunning());
    try lifecycle.beginStop();
    try testing.expectEqual(State.stopping, lifecycle.state);
    try lifecycle.markStopped();
    try testing.expectEqual(State.stopped, lifecycle.state);
    try testing.expect(!lifecycle.isRunning());
}

test "starting twice or skipping the start is rejected" {
    var lifecycle: Lifecycle = .{};
    try testing.expectError(error.InvalidTransition, lifecycle.markRunning());
    try testing.expectError(error.InvalidTransition, lifecycle.beginStop());
    try testing.expectError(error.InvalidTransition, lifecycle.markStopped());
    try lifecycle.beginStart();
    try testing.expectError(error.InvalidTransition, lifecycle.beginStart());
    try testing.expectError(error.InvalidTransition, lifecycle.beginStop());
}

test "a failed start still tears down instead of leaking resources" {
    var lifecycle: Lifecycle = .{};
    try lifecycle.beginStart();
    try lifecycle.fail();
    try testing.expectEqual(State.failed, lifecycle.state);
    try lifecycle.beginStop();
    try lifecycle.markStopped();
    try testing.expectEqual(State.stopped, lifecycle.state);
}

test "a running instance can fail and then be torn down exactly once" {
    var lifecycle: Lifecycle = .{};
    try lifecycle.beginStart();
    try lifecycle.markRunning();
    try lifecycle.fail();
    try testing.expect(!lifecycle.isRunning());
    try lifecycle.beginStop();
    try lifecycle.markStopped();
    try testing.expectError(error.InvalidTransition, lifecycle.beginStop());
    try testing.expectError(error.InvalidTransition, lifecycle.beginStart());
    try testing.expectError(error.InvalidTransition, lifecycle.fail());
}

test "a stopped instance is terminal and never restarts" {
    var lifecycle: Lifecycle = .{};
    try lifecycle.beginStart();
    try lifecycle.markRunning();
    try lifecycle.beginStop();
    try lifecycle.markStopped();
    try testing.expectError(error.InvalidTransition, lifecycle.beginStart());
    try testing.expectError(error.InvalidTransition, lifecycle.fail());
    try testing.expectEqual(State.stopped, lifecycle.state);
}
