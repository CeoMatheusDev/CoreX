//! Bounded input staging; independent of platform and gameplay representation.
//! Not a Zigway adapter, persistent replay format, or concurrent input queue.
const std = @import("std");

pub fn Buffer(comptime T: type) type {
    return struct {
        const Self = @This();
        pub const Entry = struct { tick: u64, value: T };

        storage: []Entry,
        len: usize = 0,
        next_tick: u64,
        tick_open: bool = false,
        open_count: usize = 0,

        /// The caller supplies exclusive storage, valid for the buffer's lifetime.
        pub fn init(storage: []Entry, first_tick: u64) Self {
            return .{ .storage = storage, .next_tick = first_tick };
        }

        /// Shallow-copy one input. T's references remain the caller's responsibility.
        pub fn enqueue(self: *Self, tick: u64, value: T) error{ TickInProgress, PastTick, OutOfOrder, CapacityExceeded, TickCounterOverflow }!void {
            const entry = Entry{ .tick = tick, .value = value };
            return self.enqueueBatch(&.{entry});
        }

        /// Append an entire batch or none of it, in nondecreasing tick order.
        /// Input must not alias this buffer's storage. Empty batches are allowed.
        /// Values are shallow copies; no allocation or silent dropping occurs.
        pub fn enqueueBatch(self: *Self, entries: []const Entry) error{ TickInProgress, PastTick, OutOfOrder, CapacityExceeded, TickCounterOverflow }!void {
            if (self.tick_open) return error.TickInProgress;
            if (entries.len > self.storage.len - self.len) return error.CapacityExceeded;
            var last: ?u64 = if (self.len == 0) null else self.storage[self.len - 1].tick;
            for (entries) |entry| {
                if (entry.tick < self.next_tick) return error.PastTick;
                if (entry.tick == std.math.maxInt(u64)) return error.TickCounterOverflow;
                if (last) |previous| if (entry.tick < previous) return error.OutOfOrder;
                last = entry.tick;
            }
            @memcpy(self.storage[self.len..][0..entries.len], entries);
            self.len += entries.len;
        }

        /// Open exactly the next tick, including ticks without input. Returned
        /// storage is borrowed until commit/abort. Never mutate it directly.
        /// Check counter exhaustion before allowing side effects for this tick.
        pub fn beginTick(self: *Self, tick: u64) error{ TickInProgress, UnexpectedTick, TickCounterOverflow }![]const Entry {
            if (self.tick_open) return error.TickInProgress;
            if (tick != self.next_tick) return error.UnexpectedTick;
            if (tick == std.math.maxInt(u64)) return error.TickCounterOverflow;
            var count: usize = 0;
            while (count < self.len and self.storage[count].tick == tick) : (count += 1) {}
            self.tick_open = true;
            self.open_count = count;
            return self.storage[0..count];
        }

        /// Remove this tick's inputs only after all fallible tick work succeeds.
        pub fn commitTick(self: *Self) error{NoTickInProgress}!void {
            if (!self.tick_open) return error.NoTickInProgress;
            const remaining = self.len - self.open_count;
            std.mem.copyForwards(Entry, self.storage[0..remaining], self.storage[self.open_count..self.len]);
            self.len = remaining;
            self.next_tick += 1;
            self.open_count = 0;
            self.tick_open = false;
        }

        /// Preserve staged inputs; this cannot undo side effects of tick work.
        pub fn abortTick(self: *Self) error{NoTickInProgress}!void {
            if (!self.tick_open) return error.NoTickInProgress;
            self.open_count = 0;
            self.tick_open = false;
        }
    };
}

const TestBuffer = Buffer(u32);

test "stable input order and empty ticks advance sequentially" {
    var storage: [4]TestBuffer.Entry = undefined;
    var buffer = TestBuffer.init(&storage, 0);
    try buffer.enqueue(0, 10);
    try buffer.enqueue(0, 11);
    try buffer.enqueue(2, 20);
    const first = try buffer.beginTick(0);
    try std.testing.expectEqual(@as(usize, 2), first.len);
    try std.testing.expectEqual(@as(u32, 10), first[0].value);
    try std.testing.expectEqual(@as(u32, 11), first[1].value);
    try buffer.commitTick();
    try std.testing.expectEqual(@as(usize, 0), (try buffer.beginTick(1)).len);
    try buffer.commitTick();
    const third = try buffer.beginTick(2);
    try std.testing.expectEqual(@as(usize, 1), third.len);
    try std.testing.expectEqual(@as(u32, 20), third[0].value);
    try buffer.commitTick();
    try std.testing.expectEqual(@as(u64, 3), buffer.next_tick);
    try std.testing.expectEqual(@as(usize, 0), buffer.len);
}

test "past and out-of-order inputs and full buffers leave state unchanged" {
    var storage: [2]TestBuffer.Entry = undefined;
    var buffer = TestBuffer.init(&storage, 5);
    try std.testing.expectError(error.PastTick, buffer.enqueue(4, 1));
    try buffer.enqueue(6, 2);
    try std.testing.expectError(error.OutOfOrder, buffer.enqueue(5, 3));
    try buffer.enqueue(6, 4);
    try std.testing.expectError(error.CapacityExceeded, buffer.enqueue(7, 5));
    try std.testing.expectEqual(@as(usize, 2), buffer.len);
    try std.testing.expectEqual(@as(u32, 2), buffer.storage[0].value);
    try std.testing.expectEqual(@as(u32, 4), buffer.storage[1].value);
}

test "batch insertion is atomic for capacity, order and old ticks" {
    var storage: [4]TestBuffer.Entry = undefined;
    var buffer = TestBuffer.init(&storage, 5);
    try buffer.enqueue(6, 10);
    try std.testing.expectError(error.CapacityExceeded, buffer.enqueueBatch(&.{ .{ .tick = 6, .value = 11 }, .{ .tick = 6, .value = 12 }, .{ .tick = 7, .value = 13 }, .{ .tick = 7, .value = 14 } }));
    try std.testing.expectError(error.OutOfOrder, buffer.enqueueBatch(&.{ .{ .tick = 7, .value = 15 }, .{ .tick = 6, .value = 16 } }));
    try std.testing.expectError(error.PastTick, buffer.enqueueBatch(&.{ .{ .tick = 7, .value = 17 }, .{ .tick = 4, .value = 18 } }));
    try std.testing.expectError(error.TickCounterOverflow, buffer.enqueueBatch(&.{ .{ .tick = 7, .value = 17 }, .{ .tick = std.math.maxInt(u64), .value = 18 } }));
    try std.testing.expectEqual(@as(usize, 1), buffer.len);
    try std.testing.expectEqual(@as(u32, 10), buffer.storage[0].value);
    try buffer.enqueueBatch(&.{ .{ .tick = 6, .value = 11 }, .{ .tick = 7, .value = 12 } });
    try buffer.enqueueBatch(&.{});
    try std.testing.expectEqual(@as(usize, 3), buffer.len);
    try std.testing.expectEqual(@as(usize, 0), (try buffer.beginTick(5)).len);
    try buffer.commitTick();
    const entries = try buffer.beginTick(6);
    try std.testing.expectEqual(@as(usize, 2), entries.len);
    try std.testing.expectEqual(@as(u32, 10), entries[0].value);
    try std.testing.expectEqual(@as(u32, 11), entries[1].value);
    try buffer.commitTick();
    try std.testing.expectEqual(@as(u32, 12), (try buffer.beginTick(7))[0].value);
    try buffer.commitTick();
}

test "abort preserves input and mutations during a tick are refused" {
    var storage: [2]TestBuffer.Entry = undefined;
    var buffer = TestBuffer.init(&storage, 0);
    try buffer.enqueue(0, 7);
    try std.testing.expectError(error.NoTickInProgress, buffer.abortTick());
    try std.testing.expectError(error.NoTickInProgress, buffer.commitTick());
    try std.testing.expectError(error.UnexpectedTick, buffer.beginTick(1));
    _ = try buffer.beginTick(0);
    try std.testing.expectError(error.TickInProgress, buffer.beginTick(0));
    try std.testing.expectError(error.TickInProgress, buffer.enqueue(1, 8));
    try std.testing.expectError(error.TickInProgress, buffer.enqueueBatch(&.{}));
    try buffer.abortTick();
    try std.testing.expectEqual(@as(u64, 0), buffer.next_tick);
    try std.testing.expectEqual(@as(u32, 7), (try buffer.beginTick(0))[0].value);
    try buffer.commitTick();
    try std.testing.expectError(error.PastTick, buffer.enqueue(0, 8));
}

test "zero capacity and tick counter exhaustion" {
    var storage: [0]TestBuffer.Entry = undefined;
    var buffer = TestBuffer.init(&storage, std.math.maxInt(u64) - 1);
    try std.testing.expectError(error.CapacityExceeded, buffer.enqueue(std.math.maxInt(u64) - 1, 1));
    try std.testing.expectEqual(@as(usize, 0), (try buffer.beginTick(std.math.maxInt(u64) - 1)).len);
    try buffer.commitTick();
    try std.testing.expectError(error.TickCounterOverflow, buffer.beginTick(std.math.maxInt(u64)));
    try std.testing.expectEqual(std.math.maxInt(u64), buffer.next_tick);
}

const TestHarness = struct {
    buffer: *TestBuffer,
    output: [4]u32 = undefined,
    len: usize = 0,
    fail_tick: ?u64 = null,
};
fn applyTick(harness: *TestHarness, tick: u64) !void {
    const entries = try harness.buffer.beginTick(tick);
    errdefer harness.buffer.abortTick() catch unreachable;
    if (harness.fail_tick == tick) return error.SimulatedFailure;
    for (entries) |entry| {
        harness.output[harness.len] = entry.value;
        harness.len += 1;
    }
    try harness.buffer.commitTick();
}

test "scheduler and input agree on successful ticks and failure before side effects" {
    const Scheduler = @import("timing.zig").Scheduler;
    var storage: [4]TestBuffer.Entry = undefined;
    var buffer = TestBuffer.init(&storage, 0);
    try buffer.enqueueBatch(&.{ .{ .tick = 0, .value = 1 }, .{ .tick = 1, .value = 2 }, .{ .tick = 1, .value = 3 } });
    var timer = try Scheduler.init(10);
    try timer.addElapsed(250_000_000);
    var harness: TestHarness = .{ .buffer = &buffer, .fail_tick = 1 };
    try std.testing.expectError(error.SimulatedFailure, timer.runDue(2, &harness, applyTick));
    try std.testing.expectEqual(@as(u64, 1), timer.completed_ticks);
    try std.testing.expectEqual(timer.completed_ticks, buffer.next_tick);
    try std.testing.expectEqual(@as(u32, 1), timer.pending(10));
    try std.testing.expectEqual(@as(usize, 2), buffer.len);
    try std.testing.expectEqualSlices(u32, &.{1}, harness.output[0..harness.len]);
    harness.fail_tick = null;
    try std.testing.expectEqual(@as(u32, 1), try timer.runDue(1, &harness, applyTick));
    try std.testing.expectEqual(timer.completed_ticks, buffer.next_tick);
    try std.testing.expectEqualSlices(u32, &.{ 1, 2, 3 }, harness.output[0..harness.len]);
}
