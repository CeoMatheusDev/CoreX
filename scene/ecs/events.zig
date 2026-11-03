//! Scene event bus: synchronous callbacks for entity/component lifecycle.
//!
//! Design: the bus is a separate, optional component — it does NOT modify
//! `World`. Callers register handlers and then forward events from their own
//! create/destroy/add/remove wrappers. Fixed capacity (no allocation in the
//! hot path), registration-order dispatch, first-error stops dispatch.
//!
//! Event kinds: entity_created, entity_destroyed, component_added<T>,
//! component_removed<T>. Component events carry the entity handle; typed
//! handlers receive the component value via a type-erased pointer.
const std = @import("std");
const entity_mod = @import("entity.zig");
const Entity = entity_mod.Entity;

pub const Kind = enum {
    entity_created,
    entity_destroyed,
    component_added,
    component_removed,
};

pub const Event = struct {
    kind: Kind,
    entity: Entity,
    /// Type name of the component for component_* events; empty otherwise.
    component_name: []const u8 = "",
    /// Opaque pointer to the component value for component_* events.
    component_ptr: ?*const anyopaque = null,
};

pub const Handler = *const fn (Event) anyerror!void;

pub const BusError = error{ CapacityExceeded, DuplicateHandler, NotSubscribed };

/// Handle returned by `subscribe`; pass to `unsubscribe` to remove.
pub const Subscription = struct {
    index: usize,
    handler: Handler,
};

/// Fixed-capacity synchronous event bus. `capacity` handlers max.
pub fn Bus(comptime capacity: usize) type {
    if (capacity == 0) @compileError("Bus capacity must be positive");
    return struct {
        const Self = @This();

        handlers: [capacity]?Handler = @splat(null),
        len: usize = 0,

        /// Subscribes a handler and returns a token for later removal.
        pub fn subscribe(self: *Self, handler: Handler) BusError!Subscription {
            // Find a free slot (null) or append.
            for (&self.handlers, 0..) |*slot, i| {
                if (slot.* == null) {
                    slot.* = handler;
                    self.len += 1;
                    return .{ .index = i, .handler = handler };
                }
            }
            if (self.len == capacity) return error.CapacityExceeded;
            const idx = self.len;
            self.handlers[idx] = handler;
            self.len += 1;
            return .{ .index = idx, .handler = handler };
        }

        /// Removes a previously subscribed handler. Swap-removes to keep the
        /// array dense; returns error if the subscription is stale.
        pub fn unsubscribe(self: *Self, sub: Subscription) BusError!void {
            const slot = &self.handlers[sub.index];
            if (slot.* == null or @intFromPtr(slot.*.?) != @intFromPtr(sub.handler)) {
                return error.NotSubscribed;
            }
            slot.* = null;
            self.len -= 1;
        }

        /// Removes all handlers.
        pub fn clear(self: *Self) void {
            @memset(&self.handlers, null);
            self.len = 0;
        }

        pub fn handlerCount(self: *const Self) usize {
            return self.len;
        }

        /// Dispatches the event to all handlers in slot order.
        /// The first handler error stops dispatch and propagates.
        pub fn emit(self: *const Self, event: Event) anyerror!void {
            for (self.handlers) |slot| {
                if (slot) |h| try h(event);
            }
        }
    };
}

/// Helper: builds an entity_created event.
pub fn entityCreated(entity: Entity) Event {
    return .{ .kind = .entity_created, .entity = entity };
}

/// Helper: builds an entity_destroyed event.
pub fn entityDestroyed(entity: Entity) Event {
    return .{ .kind = .entity_destroyed, .entity = entity };
}

/// Helper: builds a component_added event for component type T.
pub fn componentAdded(comptime T: type, entity: Entity, value: *const T) Event {
    return .{
        .kind = .component_added,
        .entity = entity,
        .component_name = @typeName(T),
        .component_ptr = @ptrCast(value),
    };
}

/// Helper: builds a component_removed event for component type T.
pub fn componentRemoved(comptime T: type, entity: Entity, value: *const T) Event {
    return .{
        .kind = .component_removed,
        .entity = entity,
        .component_name = @typeName(T),
        .component_ptr = @ptrCast(value),
    };
}

const testing = std.testing;

var sink: [16]Event = undefined;
var sink_len: usize = 0;

fn sinkHandler(event: Event) anyerror!void {
    if (sink_len < sink.len) {
        sink[sink_len] = event;
        sink_len += 1;
    }
}

fn failingHandler(event: Event) anyerror!void {
    _ = event;
    return error.HandlerFailed;
}

test "bus dispatches events in registration order" {
    sink_len = 0;
    var bus = Bus(4){};
    _ = try bus.subscribe(&sinkHandler);
    _ = try bus.subscribe(&sinkHandler);
    try testing.expectEqual(@as(usize, 2), bus.handlerCount());

    const e: Entity = .{ .index = 5, .generation = 0 };
    try bus.emit(entityCreated(e));
    try bus.emit(entityDestroyed(e));

    // Each emit calls both subscribed handlers.
    try testing.expectEqual(@as(usize, 4), sink_len);
    try testing.expectEqual(Kind.entity_created, sink[0].kind);
    try testing.expectEqual(@as(u32, 5), sink[0].entity.index);
    try testing.expectEqual(Kind.entity_destroyed, sink[2].kind);
}

test "component events carry type name and pointer" {
    sink_len = 0;
    var bus = Bus(2){};
    _ = try bus.subscribe(&sinkHandler);

    const Position = struct { x: i32, y: i32 };
    const pos: Position = .{ .x = 10, .y = 20 };
    const e: Entity = .{ .index = 1, .generation = 0 };
    try bus.emit(componentAdded(Position, e, &pos));

    try testing.expectEqual(@as(usize, 1), sink_len);
    try testing.expectEqual(Kind.component_added, sink[0].kind);
    try testing.expect(std.mem.indexOf(u8, sink[0].component_name, "Position") != null);
    const ptr: *const Position = @ptrCast(@alignCast(sink[0].component_ptr.?));
    try testing.expectEqual(@as(i32, 10), ptr.x);
}

test "first handler error stops dispatch" {
    sink_len = 0;
    var bus = Bus(4){};
    _ = try bus.subscribe(&failingHandler);
    _ = try bus.subscribe(&sinkHandler);
    try testing.expectError(error.HandlerFailed, bus.emit(entityCreated(.{ .index = 0, .generation = 0 })));
    try testing.expectEqual(@as(usize, 0), sink_len);
}

test "capacity is enforced" {
    var bus = Bus(1){};
    _ = try bus.subscribe(&sinkHandler);
    try testing.expectError(error.CapacityExceeded, bus.subscribe(&sinkHandler));
}

test "unsubscribe removes the handler and frees the slot" {
    sink_len = 0;
    var bus = Bus(4){};
    const sub_a = try bus.subscribe(&sinkHandler);
    const sub_b = try bus.subscribe(&failingHandler);
    try testing.expectEqual(@as(usize, 2), bus.handlerCount());

    try bus.unsubscribe(sub_a);
    try testing.expectEqual(@as(usize, 1), bus.handlerCount());

    // Only failingHandler remains — emit must fail.
    try testing.expectError(error.HandlerFailed, bus.emit(entityCreated(.{ .index = 0, .generation = 0 })));

    // Re-subscribe reuses the freed slot.
    const sub_c = try bus.subscribe(&sinkHandler);
    _ = try bus.unsubscribe(sub_b);
    _ = sub_c;
    try testing.expectEqual(@as(usize, 1), bus.handlerCount());
    sink_len = 0;
    try bus.emit(entityCreated(.{ .index = 9, .generation = 0 }));
    try testing.expectEqual(@as(usize, 1), sink_len);
}

test "unsubscribe with stale subscription fails" {
    var bus = Bus(2){};
    const sub = try bus.subscribe(&sinkHandler);
    try bus.unsubscribe(sub);
    try testing.expectError(error.NotSubscribed, bus.unsubscribe(sub));
}

test "clear removes all handlers" {
    var bus = Bus(4){};
    _ = try bus.subscribe(&sinkHandler);
    _ = try bus.subscribe(&failingHandler);
    try testing.expectEqual(@as(usize, 2), bus.handlerCount());
    bus.clear();
    try testing.expectEqual(@as(usize, 0), bus.handlerCount());
    sink_len = 0;
    try bus.emit(entityCreated(.{ .index = 0, .generation = 0 }));
    try testing.expectEqual(@as(usize, 0), sink_len);
}
