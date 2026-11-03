//! EventfulWorld: a thin wrapper around `World(StoresT)` that automatically
//! emits lifecycle events into an `events.Bus`. Zero overhead when the bus
//! has no subscribers (the emit loop is empty). The World itself is untouched.
const std = @import("std");
const entity_mod = @import("entity.zig");
const Entity = entity_mod.Entity;
const world_mod = @import("world.zig");
const events = @import("events.zig");

pub fn EventfulWorld(comptime StoresT: type, comptime bus_capacity: usize) type {
    return struct {
        const Self = @This();
        pub const WorldT = world_mod.World(StoresT);
        pub const Bus = events.Bus(bus_capacity);

        world: WorldT,
        bus: Bus = .{},

        pub fn init(allocator: std.mem.Allocator, entity_capacity: u32) !Self {
            return .{ .world = try WorldT.init(allocator, entity_capacity) };
        }

        pub fn deinit(self: *Self) void {
            self.world.deinit();
        }

        pub fn subscribe(self: *Self, handler: events.Handler) !void {
            _ = try self.bus.subscribe(handler);
        }

        /// Creates an entity and emits `entity_created`.
        pub fn create(self: *Self) !Entity {
            const entity = try self.world.create();
            self.bus.emit(events.entityCreated(entity)) catch {};
            return entity;
        }

        /// Destroys an entity and emits `entity_destroyed`.
        pub fn destroy(self: *Self, entity: Entity) !void {
            try self.world.destroy(entity);
            self.bus.emit(events.entityDestroyed(entity)) catch {};
        }

        /// Adds a component and emits `component_added<T>`.
        pub fn add(self: *Self, comptime T: type, entity: Entity, value: T) !void {
            try self.world.add(T, entity, value);
            self.bus.emit(events.componentAdded(T, entity, &value)) catch {};
        }

        /// Removes a component and emits `component_removed<T>` if present.
        pub fn remove(self: *Self, comptime T: type, entity: Entity) !?T {
            const old = try self.world.remove(T, entity);
            if (old) |*v| {
                self.bus.emit(events.componentRemoved(T, entity, v)) catch {};
            }
            return old;
        }

        // Pass-through accessors.
        pub fn inner(self: *Self) *WorldT {
            return &self.world;
        }
        pub fn innerConst(self: *const Self) *const WorldT {
            return &self.world;
        }
        pub fn aliveCount(self: *const Self) u32 {
            return self.world.aliveCount();
        }
    };
}

const testing = std.testing;
const sparse_set = @import("sparse_set.zig");

const Position = struct { x: i64, y: i64 };
const Velocity = struct { x: i64, y: i64 };

const Stores = struct {
    position: sparse_set.SparseSet(Position),
    velocity: sparse_set.SparseSet(Velocity),
};

const TestEW = EventfulWorld(Stores, 8);

var log: [32]events.Event = undefined;
var log_len: usize = 0;

fn logHandler(event: events.Event) anyerror!void {
    if (log_len < log.len) {
        log[log_len] = event;
        log_len += 1;
    }
}

test "create emits entity_created" {
    log_len = 0;
    var ew = try TestEW.init(testing.allocator, 8);
    defer ew.deinit();
    try ew.subscribe(&logHandler);

    const e = try ew.create();
    try testing.expectEqual(@as(usize, 1), log_len);
    try testing.expectEqual(events.Kind.entity_created, log[0].kind);
    try testing.expectEqual(e.index, log[0].entity.index);
}

test "add and remove emit component events" {
    log_len = 0;
    var ew = try TestEW.init(testing.allocator, 8);
    defer ew.deinit();
    try ew.subscribe(&logHandler);

    const e = try ew.create();
    try ew.add(Position, e, .{ .x = 1, .y = 2 });
    const removed = try ew.remove(Position, e);

    try testing.expectEqual(@as(usize, 3), log_len);
    try testing.expectEqual(events.Kind.entity_created, log[0].kind);
    try testing.expectEqual(events.Kind.component_added, log[1].kind);
    try testing.expect(std.mem.indexOf(u8, log[1].component_name, "Position") != null);
    try testing.expectEqual(events.Kind.component_removed, log[2].kind);
    try testing.expectEqual(@as(i64, 1), removed.?.x);
}

test "destroy emits entity_destroyed" {
    log_len = 0;
    var ew = try TestEW.init(testing.allocator, 8);
    defer ew.deinit();
    try ew.subscribe(&logHandler);

    const e = try ew.create();
    try ew.destroy(e);

    try testing.expectEqual(@as(usize, 2), log_len);
    try testing.expectEqual(events.Kind.entity_destroyed, log[1].kind);
    try testing.expectEqual(@as(u32, 0), ew.aliveCount());
}

test "no subscribers means no overhead and no crash" {
    var ew = try TestEW.init(testing.allocator, 8);
    defer ew.deinit();
    const e = try ew.create();
    try ew.add(Position, e, .{ .x = 0, .y = 0 });
    try ew.destroy(e);
    try testing.expectEqual(@as(u32, 0), ew.aliveCount());
}
