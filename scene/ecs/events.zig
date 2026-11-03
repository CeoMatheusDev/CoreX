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

pub const BusError = error{ CapacityExceeded, DuplicateHandler };

/// Fixed-capacity synchronous event bus. `capacity` handlers max.
pub fn Bus(comptime capacity: usize) type {
    if (capacity == 0) @compileError("Bus capacity must be positive");
    return struct {
        const Self = @This();

        handlers: [capacity]Handler = undefined,
        len: usize = 0,

        pub fn subscribe(self: *Self, handler: Handler) BusError!void {
            if (self.len == capacity) return error.CapacityExceeded;
            self.handlers[self.len] = handler;
            self.len += 1;
        }

        pub fn handlerCount(self: *const Self) usize {
            return self.len;
        }

        /// Dispatches the event to all handlers in registration order.
        /// The first handler error stops dispatch and propagates.
        pub fn emit(self: *const Self, event: Event) anyerror!void {
            for (self.handlers[0..self.len]) |h| {
                try h(event);
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
    try bus.subscribe(&sinkHandler);
    try bus.subscribe(&sinkHandler);
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
    try bus.subscribe(&sinkHandler);

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
    try bus.subscribe(&failingHandler);
    try bus.subscribe(&sinkHandler);
    try testing.expectError(error.HandlerFailed, bus.emit(entityCreated(.{ .index = 0, .generation = 0 })));
    try testing.expectEqual(@as(usize, 0), sink_len);
}

test "capacity is enforced" {
    var bus = Bus(1){};
    try bus.subscribe(&sinkHandler);
    try testing.expectError(error.CapacityExceeded, bus.subscribe(&sinkHandler));
}
