//! Fixed-step accounting only. This does not run simulation, input, jobs or a clock.
//! One tick costs 1e9 phase units; elapsed nanoseconds contribute elapsed * Hz.
//! A tick is debited only after the caller successfully completes the actual work.
const std = @import("std");

const units_per_tick: u128 = std.time.ns_per_s;

pub const Scheduler = struct {
    hz: u32,
    phase: u128 = 0,
    completed_ticks: u64 = 0,
    tick_in_progress: bool = false,

    /// The schema accepts rates from 1 to 1000 Hz. There is no implicit default.
    pub fn init(hz: u32) error{InvalidTickRate}!Scheduler {
        if (hz < 1 or hz > 1000) return error.InvalidTickRate;
        return .{ .hz = hz };
    }

    /// Call with a nonnegative monotonic elapsed interval supplied by the caller.
    /// Overflow is reported without changing state; time is never silently lost.
    pub fn addElapsed(self: *Scheduler, elapsed_ns: u64) error{ ElapsedOverflow, TickInProgress }!void {
        if (self.tick_in_progress) return error.TickInProgress;
        const increment = @as(u128, elapsed_ns) * self.hz;
        const sum = @addWithOverflow(self.phase, increment);
        if (sum[1] != 0) return error.ElapsedOverflow;
        self.phase = sum[0];
    }

    /// Number of whole ticks ready, capped by the caller's per-iteration budget.
    /// This only plans; uncommitted ticks remain in the accumulator.
    pub fn pending(self: *const Scheduler, budget: u32) u32 {
        return @intCast(@min(self.phase / units_per_tick, budget));
    }

    /// Preflight before doing tick work: returns its zero-based index, or null
    /// if no tick is due. Avoid side effects if the counter cannot be advanced.
    pub fn nextTick(self: *const Scheduler) error{TickCounterOverflow}!?u64 {
        if (self.phase < units_per_tick) return null;
        if (self.completed_ticks == std.math.maxInt(u64)) return error.TickCounterOverflow;
        return self.completed_ticks;
    }

    /// Commit exactly one successfully executed tick. Do not call on failure.
    /// Manual users must preflight nextTick before performing side effects.
    pub fn commitTick(self: *Scheduler) error{ NoTickDue, TickCounterOverflow, TickInProgress }!void {
        if (self.tick_in_progress) return error.TickInProgress;
        _ = (try self.nextTick()) orelse return error.NoTickDue;
        self.commitUnchecked();
    }

    fn commitUnchecked(self: *Scheduler) void {
        self.phase -= units_per_tick;
        self.completed_ticks += 1;
    }

    /// Run at most budget ticks, in order, and commit only successful calls.
    /// A failure preserves that tick and the backlog, but cannot roll back any
    /// side effects performed by the callback; earlier successes stay committed.
    /// The callback must not access this scheduler concurrently or mutate fields.
    pub fn runDue(self: *Scheduler, budget: u32, context: anytype, comptime tick: anytype) !u32 {
        if (self.tick_in_progress) return error.TickInProgress;
        self.tick_in_progress = true;
        defer self.tick_in_progress = false;
        const count = self.pending(budget);
        for (0..count) |_| {
            const index = (try self.nextTick()).?;
            try tick(context, index);
            self.commitUnchecked();
        }
        return count;
    }

    /// While whole ticks are overdue, skip interpolation/render instead of
    /// pretending the simulation is caught up. Otherwise alpha is in [0, 1).
    pub fn interpolationAlpha(self: *const Scheduler) ?f64 {
        if (self.phase >= units_per_tick) return null;
        return @as(f64, @floatFromInt(self.phase)) / @as(f64, @floatFromInt(units_per_tick));
    }
};

test "rates follow the project schema and empty state rejects commit" {
    try std.testing.expectError(error.InvalidTickRate, Scheduler.init(0));
    try std.testing.expectError(error.InvalidTickRate, Scheduler.init(1001));
    _ = try Scheduler.init(1);
    _ = try Scheduler.init(1000);
    var timer = try Scheduler.init(60);
    try std.testing.expectEqual(@as(u32, 0), timer.pending(5));
    try std.testing.expectError(error.NoTickDue, timer.commitTick());
    try std.testing.expectEqual(@as(u64, 0), timer.completed_ticks);
    try std.testing.expectEqual(@as(f64, 0), timer.interpolationAlpha().?);
}

test "rational 60 Hz accumulates without nanosecond rounding drift" {
    var timer = try Scheduler.init(60);
    // Different frame partitions sum to exactly one second.
    try timer.addElapsed(16_666_666);
    try std.testing.expectEqual(@as(u32, 0), timer.pending(100));
    try timer.addElapsed(1);
    try std.testing.expectEqual(@as(u32, 1), timer.pending(100));
    try timer.commitTick();
    try timer.addElapsed(983_333_333);
    try std.testing.expectEqual(@as(u32, 59), timer.pending(100));
    for (0..59) |_| try timer.commitTick();
    try std.testing.expectEqual(@as(u64, 60), timer.completed_ticks);
    try std.testing.expectEqual(@as(f64, 0), timer.interpolationAlpha().?);
}

test "catch-up is capped without discarding backlog or failed ticks" {
    var timer = try Scheduler.init(10);
    try timer.addElapsed(550_000_000);
    try std.testing.expectEqual(@as(u32, 2), timer.pending(2));
    try std.testing.expectEqual(@as(u32, 0), timer.pending(0));
    try std.testing.expect(timer.interpolationAlpha() == null);
    try timer.commitTick();
    try timer.commitTick();
    try std.testing.expectEqual(@as(u32, 3), timer.pending(100));
    // A failed tick is not committed; repeated planning yields the same backlog.
    try std.testing.expectEqual(@as(u32, 3), timer.pending(100));
    for (0..3) |_| try timer.commitTick();
    try std.testing.expectEqual(@as(u64, 5), timer.completed_ticks);
    try std.testing.expectEqual(@as(f64, 0.5), timer.interpolationAlpha().?);
}

test "overflows fail without changing state" {
    var timer = try Scheduler.init(1000);
    timer.phase = std.math.maxInt(u128) - 5;
    try std.testing.expectError(error.ElapsedOverflow, timer.addElapsed(1));
    try std.testing.expectEqual(std.math.maxInt(u128) - 5, timer.phase);
    timer.phase = units_per_tick;
    timer.completed_ticks = std.math.maxInt(u64);
    try std.testing.expectError(error.TickCounterOverflow, timer.commitTick());
    try std.testing.expectEqual(units_per_tick, timer.phase);
    try std.testing.expectEqual(std.math.maxInt(u64), timer.completed_ticks);
}

test "partitioned elapsed intervals produce the same exact phase" {
    for ([_]u32{ 1, 3, 60, 144, 1000 }) |hz| {
        var whole = try Scheduler.init(hz);
        var parts = try Scheduler.init(hz);
        try whole.addElapsed(1_234_567_890);
        for (0..1000) |_| try parts.addElapsed(1_234_567);
        try parts.addElapsed(890);
        try std.testing.expectEqual(whole.phase, parts.phase);
        const count = whole.pending(2000);
        try std.testing.expectEqual(count, parts.pending(2000));
        for (0..count) |_| {
            try whole.commitTick();
            try parts.commitTick();
        }
        try std.testing.expectEqual(whole.phase, parts.phase);
        try std.testing.expectEqual(whole.completed_ticks, parts.completed_ticks);
        try std.testing.expectEqual(whole.interpolationAlpha().?, parts.interpolationAlpha().?);
    }
}

test "large elapsed intervals are bounded by budget without narrowing the backlog" {
    var timer = try Scheduler.init(1000);
    try timer.addElapsed(std.math.maxInt(u64));
    try std.testing.expectEqual(std.math.maxInt(u32), timer.pending(std.math.maxInt(u32)));
    try timer.commitTick();
    try std.testing.expectEqual(std.math.maxInt(u32), timer.pending(std.math.maxInt(u32)));
    try std.testing.expect(timer.interpolationAlpha() == null);
}

test "fractional boundaries remain exact at the maximum rate" {
    var timer = try Scheduler.init(1000);
    try timer.addElapsed(999_999);
    try std.testing.expectEqual(@as(u32, 0), timer.pending(1));
    try timer.addElapsed(1);
    try std.testing.expectEqual(@as(u32, 1), timer.pending(1));
    try timer.commitTick();
    try std.testing.expectEqual(@as(f64, 0), timer.interpolationAlpha().?);
}

const TickProbe = struct {
    scheduler: *Scheduler,
    calls: u32 = 0,
    fail_at: ?u64 = null,
    reentry_rejected: bool = false,
    mutation_rejected: bool = false,
    driver_reentry_rejected: bool = false,
};

fn unreachableTick(_: *TickProbe, _: u64) !void {
    return error.UnexpectedTick;
}

fn probeTick(probe: *TickProbe, index: u64) !void {
    if (index != probe.scheduler.completed_ticks) return error.UnexpectedTick;
    probe.calls += 1;
    probe.scheduler.addElapsed(1) catch |err| {
        probe.mutation_rejected = err == error.TickInProgress;
    };
    probe.scheduler.commitTick() catch |err| {
        probe.reentry_rejected = err == error.TickInProgress;
    };
    _ = probe.scheduler.runDue(1, probe, unreachableTick) catch |err| blk: {
        probe.driver_reentry_rejected = err == error.TickInProgress;
        break :blk 0;
    };
    if (probe.fail_at == index) return error.SimulatedFailure;
}

test "bounded tick driver commits successful work and preserves failure backlog" {
    var timer = try Scheduler.init(10);
    try timer.addElapsed(350_000_000);
    var probe: TickProbe = .{ .scheduler = &timer, .fail_at = 1 };
    try std.testing.expectError(error.SimulatedFailure, timer.runDue(3, &probe, probeTick));
    try std.testing.expectEqual(@as(u64, 1), timer.completed_ticks);
    try std.testing.expectEqual(@as(u32, 2), timer.pending(10));
    try std.testing.expectEqual(@as(u32, 2), probe.calls);
    try std.testing.expect(probe.reentry_rejected and probe.mutation_rejected and probe.driver_reentry_rejected);
    probe.fail_at = null;
    try std.testing.expectEqual(@as(u32, 1), try timer.runDue(1, &probe, probeTick));
    try std.testing.expectEqual(@as(u32, 1), timer.pending(10));
    try std.testing.expectEqual(@as(u32, 1), try timer.runDue(10, &probe, probeTick));
    try std.testing.expectEqual(@as(u64, 3), timer.completed_ticks);
    try std.testing.expectEqual(@as(f64, 0.5), timer.interpolationAlpha().?);
}

test "driver rejects exhausted counter before invoking callback" {
    var timer = try Scheduler.init(10);
    try timer.addElapsed(100_000_000);
    timer.completed_ticks = std.math.maxInt(u64);
    var probe: TickProbe = .{ .scheduler = &timer };
    try std.testing.expectError(error.TickCounterOverflow, timer.nextTick());
    try std.testing.expectEqual(@as(u32, 0), try timer.runDue(0, &probe, probeTick));
    try std.testing.expectError(error.TickCounterOverflow, timer.runDue(1, &probe, probeTick));
    try std.testing.expectEqual(@as(u32, 0), probe.calls);
    try std.testing.expectEqual(@as(u32, 1), timer.pending(1));
}
