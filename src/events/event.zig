//! Bounded, synchronous, single-threaded event delivery for the legacy core.
//! This is not an asynchronous queue or a Runtime input/replay implementation.
const std = @import("std");

pub const Event = struct {
    id: u32,
    /// Borrowed bytes, valid only for the duration of publish.
    payload: []const u8,
};

pub const Handler = *const fn (context: *anyopaque, event: Event) void;
pub const SubscriptionId = enum(u64) { _ };
const Subscription = struct {
    id: SubscriptionId,
    event_id: u32,
    handler: Handler,
    context: *anyopaque,
};

pub const EventBus = struct {
    allocator: std.mem.Allocator,
    subscriptions: []Subscription,
    count: usize = 0,
    next_id: u64 = 1,
    publishing: bool = false,

    /// Allocate the entire fixed capacity up front, outside event delivery.
    /// A zero-capacity bus can publish but cannot register listeners.
    pub fn init(allocator: std.mem.Allocator, capacity: usize) std.mem.Allocator.Error!EventBus {
        return .{ .allocator = allocator, .subscriptions = try allocator.alloc(Subscription, capacity) };
    }

    /// Do not copy a live bus. Callbacks may not destroy it while publishing.
    pub fn deinit(self: *EventBus) error{Publishing}!void {
        if (self.publishing) return error.Publishing;
        self.allocator.free(self.subscriptions);
        self.* = undefined;
    }

    /// Listeners run in registration order. Each registration is distinct.
    /// The handler/context remain valid until unsubscribed or the bus is destroyed.
    /// IDs are scoped to this bus and must never be used with a different bus.
    pub fn subscribe(self: *EventBus, event_id: u32, handler: Handler, context: *anyopaque) error{ Publishing, CapacityExceeded, SubscriptionIdsExhausted }!SubscriptionId {
        if (self.publishing) return error.Publishing;
        if (self.count == self.subscriptions.len) return error.CapacityExceeded;
        // Do not wrap and accidentally make a stale ID refer to another listener.
        if (self.next_id == std.math.maxInt(u64)) return error.SubscriptionIdsExhausted;
        const id: SubscriptionId = @fromBackingInt(@intCast(self.next_id));
        self.subscriptions[self.count] = .{ .id = id, .event_id = event_id, .handler = handler, .context = context };
        self.next_id += 1;
        self.count += 1;
        return id;
    }

    /// Removes only this registration, preserving the order of the others.
    /// False means the ID is not active on this bus (including stale IDs).
    pub fn unsubscribe(self: *EventBus, id: SubscriptionId) error{Publishing}!bool {
        if (self.publishing) return error.Publishing;
        for (self.subscriptions[0..self.count], 0..) |subscription, index| {
            if (subscription.id == id) {
                std.mem.copyForwards(Subscription, self.subscriptions[index .. self.count - 1], self.subscriptions[index + 1 .. self.count]);
                self.count -= 1;
                return true;
            }
        }
        return false;
    }

    /// Deliver synchronously to listeners for event.id. No allocation or
    /// payload copy occurs. Reentrant publication/mutation is rejected.
    /// No synchronization, retries or callback panic recovery are provided.
    pub fn publish(self: *EventBus, event: Event) error{Publishing}!void {
        if (self.publishing) return error.Publishing;
        self.publishing = true;
        defer self.publishing = false;
        for (self.subscriptions[0..self.count]) |subscription| {
            if (subscription.event_id == event.id) subscription.handler(subscription.context, event);
        }
    }
};

const Recorder = struct {
    order: [16]u8 = undefined,
    len: usize = 0,
    payload: [64]u8 = undefined,
    payload_len: usize = 0,
};
const Listener = struct { recorder: *Recorder, value: u8 };
fn record(ptr: *anyopaque, event: Event) void {
    const listener: *Listener = @ptrCast(@alignCast(ptr));
    const recorder = listener.recorder;
    recorder.order[recorder.len] = listener.value;
    recorder.len += 1;
    recorder.payload_len = @min(event.payload.len, recorder.payload.len);
    @memcpy(recorder.payload[0..recorder.payload_len], event.payload[0..recorder.payload_len]);
}

test "delivery filters by event id and preserves listener order" {
    var bus = try EventBus.init(std.testing.allocator, 4);
    defer bus.deinit() catch unreachable;
    var recorder: Recorder = .{};
    var listeners = [_]Listener{
        .{ .recorder = &recorder, .value = 1 },
        .{ .recorder = &recorder, .value = 2 },
        .{ .recorder = &recorder, .value = 3 },
    };
    _ = try bus.subscribe(42, record, &listeners[0]);
    _ = try bus.subscribe(8, record, &listeners[1]);
    _ = try bus.subscribe(42, record, &listeners[2]);
    try bus.publish(.{ .id = 42, .payload = "hello" });
    try std.testing.expectEqualSlices(u8, &.{ 1, 3 }, recorder.order[0..recorder.len]);
    try std.testing.expectEqualStrings("hello", recorder.payload[0..recorder.payload_len]);
    try bus.publish(.{ .id = 99, .payload = "unused" });
    try std.testing.expectEqual(@as(usize, 2), recorder.len);
}

test "unsubscribe and capacity preserve order and reject stale IDs" {
    var bus = try EventBus.init(std.testing.allocator, 2);
    defer bus.deinit() catch unreachable;
    var recorder: Recorder = .{};
    var a: Listener = .{ .recorder = &recorder, .value = 1 };
    var b: Listener = .{ .recorder = &recorder, .value = 2 };
    var c: Listener = .{ .recorder = &recorder, .value = 3 };
    const first = try bus.subscribe(1, record, &a);
    const second = try bus.subscribe(1, record, &b);
    try std.testing.expectError(error.CapacityExceeded, bus.subscribe(1, record, &c));
    try std.testing.expect(try bus.unsubscribe(first));
    try std.testing.expect(!try bus.unsubscribe(first));
    const third = try bus.subscribe(1, record, &c);
    try std.testing.expect(third != first and third != second);
    try std.testing.expect(!try bus.unsubscribe(first));
    try bus.publish(.{ .id = 1, .payload = "" });
    try std.testing.expectEqualSlices(u8, &.{ 2, 3 }, recorder.order[0..recorder.len]);
}

const MutationProbe = struct {
    bus: *EventBus,
    id: SubscriptionId,
    publish_blocked: bool = false,
    subscribe_blocked: bool = false,
    unsubscribe_blocked: bool = false,
    deinit_blocked: bool = false,
    calls: usize = 0,
};
fn mutate(ptr: *anyopaque, event: Event) void {
    const probe: *MutationProbe = @ptrCast(@alignCast(ptr));
    probe.calls += 1;
    probe.bus.publish(event) catch |err| {
        probe.publish_blocked = err == error.Publishing;
    };
    _ = probe.bus.subscribe(event.id, mutate, probe) catch |err| blk: {
        probe.subscribe_blocked = err == error.Publishing;
        break :blk probe.id;
    };
    _ = probe.bus.unsubscribe(probe.id) catch |err| blk: {
        probe.unsubscribe_blocked = err == error.Publishing;
        break :blk false;
    };
    probe.bus.deinit() catch |err| {
        probe.deinit_blocked = err == error.Publishing;
    };
}

test "reentrancy and mutation fail without changing active listeners" {
    var bus = try EventBus.init(std.testing.allocator, 2);
    defer bus.deinit() catch unreachable;
    var probe: MutationProbe = .{ .bus = &bus, .id = @fromBackingInt(@intCast(0)) };
    probe.id = try bus.subscribe(1, mutate, &probe);
    try bus.publish(.{ .id = 1, .payload = "" });
    try std.testing.expect(probe.publish_blocked and probe.subscribe_blocked and probe.unsubscribe_blocked and probe.deinit_blocked);
    try std.testing.expectEqual(@as(usize, 1), bus.count);
    try bus.publish(.{ .id = 1, .payload = "" });
    try std.testing.expectEqual(@as(usize, 2), probe.calls);
    try std.testing.expect(try bus.unsubscribe(probe.id));
}

test "allocation happens at initialization only, including zero capacity" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 1 });
    var bus = try EventBus.init(failing.allocator(), 1);
    defer bus.deinit() catch unreachable;
    var recorder: Recorder = .{};
    var item: Listener = .{ .recorder = &recorder, .value = 4 };
    const id = try bus.subscribe(1, record, &item);
    try bus.publish(.{ .id = 1, .payload = "no allocation" });
    try std.testing.expect(try bus.unsubscribe(id));
    try std.testing.expect(!failing.has_induced_failure);
    try std.testing.expectEqual(@as(usize, 1), failing.allocations);
    var empty = try EventBus.init(std.testing.allocator, 0);
    defer empty.deinit() catch unreachable;
    try std.testing.expectError(error.CapacityExceeded, empty.subscribe(1, record, &item));
    try empty.publish(.{ .id = 1, .payload = "" });
}

test "allocation and subscription id exhaustion fail without mutation" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, EventBus.init(failing.allocator(), 1));
    var bus = try EventBus.init(std.testing.allocator, 1);
    defer bus.deinit() catch unreachable;
    var recorder: Recorder = .{};
    var item: Listener = .{ .recorder = &recorder, .value = 1 };
    bus.next_id = std.math.maxInt(u64);
    try std.testing.expectError(error.SubscriptionIdsExhausted, bus.subscribe(1, record, &item));
    try std.testing.expectEqual(@as(usize, 0), bus.count);
    try std.testing.expectEqual(std.math.maxInt(u64), bus.next_id);
}

test "duplicate listeners are independent and stale IDs never become valid again" {
    var bus = try EventBus.init(std.testing.allocator, 2);
    defer bus.deinit() catch unreachable;
    var recorder: Recorder = .{};
    var item: Listener = .{ .recorder = &recorder, .value = 7 };
    const first = try bus.subscribe(1, record, &item);
    const second = try bus.subscribe(1, record, &item);
    try bus.publish(.{ .id = 1, .payload = "" });
    try std.testing.expectEqual(@as(usize, 2), recorder.len);
    try std.testing.expect(try bus.unsubscribe(first));
    try std.testing.expect(!try bus.unsubscribe(first));
    try bus.publish(.{ .id = 1, .payload = "" });
    try std.testing.expectEqual(@as(usize, 3), recorder.len);
    try std.testing.expect(try bus.unsubscribe(second));
    try bus.publish(.{ .id = 1, .payload = "" });
    try std.testing.expectEqual(@as(usize, 3), recorder.len);
}

test "last subscription ID does not wrap after unsubscribe" {
    var bus = try EventBus.init(std.testing.allocator, 1);
    defer bus.deinit() catch unreachable;
    var recorder: Recorder = .{};
    var item: Listener = .{ .recorder = &recorder, .value = 1 };
    bus.next_id = std.math.maxInt(u64) - 1;
    const last = try bus.subscribe(1, record, &item);
    try std.testing.expect(try bus.unsubscribe(last));
    try std.testing.expectError(error.SubscriptionIdsExhausted, bus.subscribe(1, record, &item));
    try std.testing.expect(!try bus.unsubscribe(last));
}
