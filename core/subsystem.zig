//! Explicit subsystem ownership for Editor and Runtime.
//!
//! Registration order is start order; teardown is the exact reverse order. The
//! registry owns no allocator, so capacity is fixed at compile time and the hot
//! step path performs no allocation. Subsystem state stays owned by the caller:
//! adopt a value that lives in a stable location (a local in a `run` function or
//! a heap allocation held for the whole lifetime), never a temporary copy.
const std = @import("std");
const lifecycle = @import("lifecycle.zig");

pub const Lifecycle = lifecycle.Lifecycle;
pub const State = lifecycle.State;

/// One fixed simulation step. `index` is zero-based and strictly sequential
/// within a run; `dt_ns` never changes during a run.
pub const Step = struct {
    index: u64,
    dt_ns: u64,
};

pub const RegisterError = error{ CapacityExceeded, DuplicateName, AlreadyStarted };
pub const StepError = error{NotRunning};
pub const StopError = error{InvalidTransition};

/// One owned subsystem, type-erased so the registry stays allocation-free.
/// `start` may fail; `stop` never fails, because teardown must complete.
pub const Subsystem = struct {
    name: []const u8,
    context: *anyopaque,
    start_fn: *const fn (*anyopaque) anyerror!void,
    step_fn: *const fn (*anyopaque, Step) anyerror!void,
    stop_fn: *const fn (*anyopaque) void,

    /// Adapts `T`, which must expose `start()`, `step(Step)` and `stop()`.
    pub fn adopt(comptime T: type, name: []const u8, context: *T) Subsystem {
        const Bridge = struct {
            fn start(pointer: *anyopaque) anyerror!void {
                return @as(*T, @ptrCast(@alignCast(pointer))).start();
            }

            fn step(pointer: *anyopaque, descriptor: Step) anyerror!void {
                return @as(*T, @ptrCast(@alignCast(pointer))).step(descriptor);
            }

            fn stop(pointer: *anyopaque) void {
                @as(*T, @ptrCast(@alignCast(pointer))).stop();
            }
        };
        return .{
            .name = name,
            .context = @ptrCast(context),
            .start_fn = Bridge.start,
            .step_fn = Bridge.step,
            .stop_fn = Bridge.stop,
        };
    }
};

pub fn Registry(comptime capacity: usize) type {
    if (capacity == 0) @compileError("Registry capacity must be positive");
    return struct {
        const Self = @This();

        entries: [capacity]Subsystem = undefined,
        len: usize = 0,
        started: usize = 0,
        lifecycle: Lifecycle = .{},

        pub fn systemCount(self: *const Self) usize {
            return self.len;
        }

        pub fn state(self: *const Self) State {
            return self.lifecycle.state;
        }

        /// Names must be unique and stable for the registry's lifetime; they
        /// identify subsystems in diagnostics and in tests.
        pub fn register(self: *Self, entry: Subsystem) RegisterError!void {
            if (self.lifecycle.state != .created) return error.AlreadyStarted;
            // Duplicates are reported before capacity: a name clash is a
            // diagnostic mistake, not a sizing problem.
            for (self.entries[0..self.len]) |existing| {
                if (std.mem.eql(u8, existing.name, entry.name)) return error.DuplicateName;
            }
            if (self.len == capacity) return error.CapacityExceeded;
            self.entries[self.len] = entry;
            self.len += 1;
        }

        /// Starts every subsystem in registration order. If one fails, the ones
        /// already started are stopped in reverse order, the instance is marked
        /// failed and the original error propagates unchanged. There is no retry
        /// and no partially started state observed by callers.
        pub fn start(self: *Self) anyerror!void {
            try self.lifecycle.beginStart();
            while (self.started < self.len) : (self.started += 1) {
                const entry = &self.entries[self.started];
                entry.start_fn(entry.context) catch |err| {
                    self.teardown();
                    try self.lifecycle.fail();
                    return err;
                };
            }
            self.started = self.len;
            try self.lifecycle.markRunning();
        }

        /// Runs one fixed step across all subsystems in registration order.
        /// The first failure marks the instance failed; teardown stays the
        /// caller's responsibility and must still run.
        pub fn step(self: *Self, descriptor: Step) anyerror!void {
            if (!self.lifecycle.isRunning()) return error.NotRunning;
            for (self.entries[0..self.len]) |*entry| {
                entry.step_fn(entry.context, descriptor) catch |err| {
                    try self.lifecycle.fail();
                    return err;
                };
            }
        }

        /// Stops subsystems in reverse registration order. Safe to call after a
        /// failed start (nothing is then running) and exactly once.
        pub fn stop(self: *Self) StopError!void {
            try self.lifecycle.beginStop();
            self.teardown();
            try self.lifecycle.markStopped();
        }

        fn teardown(self: *Self) void {
            while (self.started > 0) {
                self.started -= 1;
                const entry = &self.entries[self.started];
                entry.stop_fn(entry.context);
            }
        }
    };
}

const testing = std.testing;

/// Records call order across subsystems so ordering contracts are observable.
const OrderLog = struct {
    events: [16][]const u8 = undefined,
    len: usize = 0,

    fn push(self: *OrderLog, event: []const u8) void {
        self.events[self.len] = event;
        self.len += 1;
    }

    fn slice(self: *const OrderLog) []const []const u8 {
        return self.events[0..self.len];
    }
};

const Probe = struct {
    log: *OrderLog,
    label: []const u8,
    steps: usize = 0,
    fail_start: bool = false,
    fail_step: bool = false,

    fn start(self: *Probe) anyerror!void {
        self.log.push(self.label);
        if (self.fail_start) return error.StartRejected;
    }

    fn step(self: *Probe, descriptor: Step) anyerror!void {
        if (self.fail_step) return error.StepRejected;
        self.steps += 1;
        _ = descriptor;
    }

    fn stop(self: *Probe) void {
        self.log.push(self.label);
    }
};

test "start runs in registration order and stop runs in reverse" {
    var log: OrderLog = .{};
    var first: Probe = .{ .log = &log, .label = "a" };
    var second: Probe = .{ .log = &log, .label = "b" };
    var registry = Registry(2){};
    try registry.register(Subsystem.adopt(Probe, "first", &first));
    try registry.register(Subsystem.adopt(Probe, "second", &second));
    try testing.expectEqual(@as(usize, 2), registry.systemCount());
    try registry.start();
    try testing.expectEqual(State.running, registry.state());
    try registry.step(.{ .index = 0, .dt_ns = 1 });
    try testing.expectEqual(@as(usize, 1), first.steps);
    try testing.expectEqual(@as(usize, 1), second.steps);
    try registry.stop();
    try testing.expectEqual(State.stopped, registry.state());
    try testing.expectEqualSlices([]const u8, &.{ "a", "b", "b", "a" }, log.slice());
}

test "a failed start rolls back only the subsystems already started" {
    var log: OrderLog = .{};
    var first: Probe = .{ .log = &log, .label = "a" };
    var second: Probe = .{ .log = &log, .label = "b", .fail_start = true };
    var third: Probe = .{ .log = &log, .label = "c" };
    var registry = Registry(3){};
    try registry.register(Subsystem.adopt(Probe, "first", &first));
    try registry.register(Subsystem.adopt(Probe, "second", &second));
    try registry.register(Subsystem.adopt(Probe, "third", &third));
    try testing.expectError(error.StartRejected, registry.start());
    try testing.expectEqual(State.failed, registry.state());
    // "c" never started, so it is never stopped; "a" is stopped exactly once.
    try testing.expectEqualSlices([]const u8, &.{ "a", "b", "a" }, log.slice());
    // Teardown after a failed start must be allowed and must not double-stop.
    try registry.stop();
    try testing.expectEqual(State.stopped, registry.state());
    try testing.expectEqualSlices([]const u8, &.{ "a", "b", "a" }, log.slice());
    try testing.expectError(error.InvalidTransition, registry.stop());
}

test "step is rejected before start and after a failure" {
    var log: OrderLog = .{};
    var probe: Probe = .{ .log = &log, .label = "a", .fail_step = true };
    var registry = Registry(1){};
    try registry.register(Subsystem.adopt(Probe, "probe", &probe));
    try testing.expectError(error.NotRunning, registry.step(.{ .index = 0, .dt_ns = 1 }));
    try registry.start();
    try testing.expectError(error.StepRejected, registry.step(.{ .index = 0, .dt_ns = 1 }));
    try testing.expectEqual(State.failed, registry.state());
    try testing.expectError(error.NotRunning, registry.step(.{ .index = 0, .dt_ns = 1 }));
    try registry.stop();
    try testing.expectEqual(State.stopped, registry.state());
}

test "capacity, duplicate names and late registration are rejected" {
    var log: OrderLog = .{};
    var first: Probe = .{ .log = &log, .label = "a" };
    var second: Probe = .{ .log = &log, .label = "b" };
    var registry = Registry(1){};
    try registry.register(Subsystem.adopt(Probe, "first", &first));
    try testing.expectError(error.CapacityExceeded, registry.register(Subsystem.adopt(Probe, "second", &second)));
    try testing.expectError(error.DuplicateName, registry.register(Subsystem.adopt(Probe, "first", &second)));
    try registry.start();
    try testing.expectError(error.AlreadyStarted, registry.register(Subsystem.adopt(Probe, "second", &second)));
    try testing.expectEqual(@as(usize, 1), registry.systemCount());
    try registry.stop();
}

test "an empty registry still completes the lifecycle" {
    var registry = Registry(1){};
    try registry.start();
    try registry.step(.{ .index = 0, .dt_ns = 1 });
    try registry.stop();
    try testing.expectEqual(State.stopped, registry.state());
}
