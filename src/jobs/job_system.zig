//! Minimal single-threaded FIFO, not a parallel job system.
const std = @import("std");
const Job = @import("job.zig").Job;

pub const JobSystem = struct {
    allocator: std.mem.Allocator,
    count: usize = 0,
    capacity: usize = 4,
    items: []Job,
    executing: bool = false,

    pub fn init(allocator: std.mem.Allocator) !JobSystem {
        const cap = 4;
        const arr = try allocator.alloc(Job, cap);
        return .{ .allocator = allocator, .items = arr, .capacity = cap };
    }

    /// The owner must not destroy the queue from a job callback.
    pub fn deinit(self: *JobSystem) void {
        std.debug.assert(!self.executing);
        self.allocator.free(self.items);
    }

    /// Jobs borrow their name and context; the caller keeps both alive until run.
    pub fn submit(self: *JobSystem, job: Job) std.mem.Allocator.Error!void {
        if (self.count >= self.capacity) {
            const new_cap = std.math.mul(usize, self.capacity, 2) catch return error.OutOfMemory;
            const new_arr = try self.allocator.realloc(self.items, new_cap);
            self.items = new_arr;
            self.capacity = new_cap;
        }
        self.items[self.count] = job;
        self.count += 1;
    }

    /// Run the initial batch in FIFO order exactly once. Jobs submitted by a
    /// callback are kept for the next batch, even if submission reallocates.
    /// Recursive execution is rejected, not silently ignored. Not thread-safe.
    pub fn executeAll(self: *JobSystem) error{ReentrantExecution}!void {
        if (self.executing) return error.ReentrantExecution;
        self.executing = true;
        defer self.executing = false;
        const batch_count = self.count;
        for (0..batch_count) |index| {
            // Do not retain a slice or pointer across a callback: submit may realloc.
            const job = self.items[index];
            job.func(job.ctx);
        }
        const remaining = self.count - batch_count;
        std.mem.copyForwards(Job, self.items[0..remaining], self.items[batch_count..self.count]);
        self.count = remaining;
    }
};

const TestContext = struct {
    queue: *JobSystem,
    seen: [16]u8 = undefined,
    len: usize = 0,
    spawned: [6]Item = undefined,
    error_seen: bool = false,
    reentrant_rejected: bool = false,
};
const Item = struct { context: *TestContext, value: u8 };

fn record(ptr: *anyopaque) void {
    const item: *Item = @ptrCast(@alignCast(ptr));
    item.context.seen[item.context.len] = item.value;
    item.context.len += 1;
}

fn spawn(ptr: *anyopaque) void {
    const ctx: *TestContext = @ptrCast(@alignCast(ptr));
    ctx.queue.executeAll() catch |err| {
        ctx.reentrant_rejected = err == error.ReentrantExecution;
    };
    for (&ctx.spawned, 0..) |*item, i| {
        item.* = .{ .context = ctx, .value = @intCast(i + 10) };
        ctx.queue.submit(.{ .name = "spawned", .func = record, .ctx = item }) catch {
            ctx.error_seen = true;
            return;
        };
    }
}

test "completed batches are removed, repeated execution is empty and FIFO is preserved" {
    var queue = try JobSystem.init(std.testing.allocator);
    defer queue.deinit();
    var ctx: TestContext = .{ .queue = &queue };
    var items = [_]Item{ .{ .context = &ctx, .value = 1 }, .{ .context = &ctx, .value = 2 } };
    for (&items) |*item| try queue.submit(.{ .name = "record", .func = record, .ctx = item });
    try queue.executeAll();
    try queue.executeAll();
    try std.testing.expectEqual(@as(usize, 0), queue.count);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2 }, ctx.seen[0..ctx.len]);
    try queue.submit(.{ .name = "again", .func = record, .ctx = &items[1] });
    try queue.executeAll();
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 2 }, ctx.seen[0..ctx.len]);
}

test "callback submissions survive reallocation and run only in the next batch" {
    var queue = try JobSystem.init(std.testing.allocator);
    defer queue.deinit();
    var ctx: TestContext = .{ .queue = &queue };
    var item: Item = .{ .context = &ctx, .value = 1 };
    try queue.submit(.{ .name = "spawn", .func = spawn, .ctx = &ctx });
    try queue.submit(.{ .name = "record", .func = record, .ctx = &item });
    try queue.executeAll();
    try std.testing.expect(ctx.reentrant_rejected);
    try std.testing.expect(!ctx.error_seen);
    try std.testing.expectEqualSlices(u8, &.{1}, ctx.seen[0..ctx.len]);
    try std.testing.expectEqual(@as(usize, 6), queue.count);
    try queue.executeAll();
    try std.testing.expectEqualSlices(u8, &.{ 1, 10, 11, 12, 13, 14, 15 }, ctx.seen[0..ctx.len]);
    try std.testing.expectEqual(@as(usize, 0), queue.count);
}

test "allocation failure when growing leaves existing jobs intact" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 1, .resize_fail_index = 0 });
    var queue = try JobSystem.init(failing.allocator());
    defer queue.deinit();
    var ctx: TestContext = .{ .queue = &queue };
    var item: Item = .{ .context = &ctx, .value = 3 };
    for (0..4) |_| try queue.submit(.{ .name = "record", .func = record, .ctx = &item });
    try std.testing.expectError(error.OutOfMemory, queue.submit(.{ .name = "record", .func = record, .ctx = &item }));
    try std.testing.expectEqual(@as(usize, 4), queue.count);
    try std.testing.expectEqual(@as(usize, 4), queue.capacity);
    try queue.executeAll();
    try std.testing.expectEqualSlices(u8, &.{ 3, 3, 3, 3 }, ctx.seen[0..ctx.len]);
}

test "initial allocation failure is propagated" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, JobSystem.init(failing.allocator()));
}
