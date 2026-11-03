//! Multi-component queries with optional NOT exclusions.
//!
//! Usage:
//!   query.each(WorldT, world, .{ .all = .{Position, Velocity}, .not = .{Age} }, cb)
//!
//! The first type in `.all` drives iteration (rarest first). Entities in
//! `.not` are excluded. Allocation-free hot path.
const std = @import("std");
const entity_mod = @import("entity.zig");
const Entity = entity_mod.Entity;

fn matches(comptime WorldT: type, world: *const WorldT, comptime All: anytype, comptime NotT: anytype, entity: Entity) bool {
    inline for (All) |T| {
        if (world.getConst(T, entity) == null) return false;
    }
    inline for (NotT) |T| {
        if (world.getConst(T, entity) != null) return false;
    }
    return true;
}

/// Iterates entities having all `All` and none of `NotT`.
/// `All[0]` drives iteration — put the rarest component first.
pub fn each(comptime WorldT: type, world: *const WorldT, comptime All: anytype, comptime NotT: anytype, callback: *const fn (*const WorldT, Entity) void) void {
    comptime {
        if (All.len == 0) @compileError("query requires at least one required component");
        if (All.len > 8) @compileError("query supports at most 8 required components");
    }
    const Driver = All[0];
    for (world.entities(Driver)) |entity| {
        if (!matches(WorldT, world, All, NotT, entity)) continue;
        callback(world, entity);
    }
}

/// Overload without exclusions: `NotT` defaults to empty.
pub fn eachAll(comptime WorldT: type, world: *const WorldT, comptime All: anytype, callback: *const fn (*const WorldT, Entity) void) void {
    each(WorldT, world, All, .{}, callback);
}

/// Counts entities matching `All` and not `NotT`.
pub fn count(comptime WorldT: type, world: *const WorldT, comptime All: anytype, comptime NotT: anytype) usize {
    var n: usize = 0;
    const Driver = All[0];
    for (world.entities(Driver)) |entity| {
        if (matches(WorldT, world, All, NotT, entity)) n += 1;
    }
    return n;
}

/// Iterator-style API.
pub fn Iterator(comptime WorldT: type, comptime All: anytype, comptime NotT: anytype) type {
    return struct {
        const Self = @This();
        world: *const WorldT,
        driver_entities: []const Entity,
        pos: usize = 0,

        pub fn init(world: *const WorldT) Self {
            const Driver = All[0];
            return .{ .world = world, .driver_entities = world.entities(Driver) };
        }

        pub fn next(self: *Self) ?Entity {
            while (self.pos < self.driver_entities.len) {
                const entity = self.driver_entities[self.pos];
                self.pos += 1;
                if (matches(WorldT, self.world, All, NotT, entity)) return entity;
            }
            return null;
        }
    };
}

const testing = std.testing;
const sparse_set = @import("sparse_set.zig");
const world_mod = @import("world.zig");

const Position = struct { x: i64, y: i64 };
const Velocity = struct { x: i64, y: i64 };
const Age = struct { ticks: u64 };

const QueryStores = struct {
    position: sparse_set.SparseSet(Position),
    velocity: sparse_set.SparseSet(Velocity),
    age: sparse_set.SparseSet(Age),
};

const TestWorld = world_mod.World(QueryStores);

var global_count: usize = 0;

fn countCb(world: *const TestWorld, entity: Entity) void {
    _ = world;
    _ = entity;
    global_count += 1;
}

test "each finds entities with all required components" {
    var world = try TestWorld.init(testing.allocator, 8);
    defer world.deinit();

    const e0 = try world.create();
    try world.add(Position, e0, .{ .x = 1, .y = 2 });
    try world.add(Velocity, e0, .{ .x = 1, .y = 1 });

    const e1 = try world.create();
    try world.add(Position, e1, .{ .x = 3, .y = 4 });

    const e2 = try world.create();
    try world.add(Position, e2, .{ .x = 5, .y = 6 });
    try world.add(Velocity, e2, .{ .x = -1, .y = 1 });
    try world.add(Age, e2, .{ .ticks = 10 });

    global_count = 0;
    each(TestWorld, &world, .{ Position, Velocity }, .{}, &countCb);
    try testing.expectEqual(@as(usize, 2), global_count);

    try testing.expectEqual(@as(usize, 3), count(TestWorld, &world, .{Position}, .{}));
    try testing.expectEqual(@as(usize, 2), count(TestWorld, &world, .{ Position, Velocity }, .{}));
    try testing.expectEqual(@as(usize, 1), count(TestWorld, &world, .{ Position, Velocity, Age }, .{}));
}

test "not query excludes entities with the excluded component" {
    var world = try TestWorld.init(testing.allocator, 8);
    defer world.deinit();

    const e0 = try world.create();
    try world.add(Position, e0, .{ .x = 1, .y = 2 });
    try world.add(Velocity, e0, .{ .x = 1, .y = 1 });

    const e1 = try world.create();
    try world.add(Position, e1, .{ .x = 3, .y = 4 });

    const e2 = try world.create();
    try world.add(Position, e2, .{ .x = 5, .y = 6 });
    try world.add(Velocity, e2, .{ .x = 1, .y = 1 });
    try world.add(Age, e2, .{ .ticks = 1 });

    // Position AND NOT Velocity → only e1.
    try testing.expectEqual(@as(usize, 1), count(TestWorld, &world, .{Position}, .{Velocity}));

    // Position AND NOT Age → e0, e1.
    try testing.expectEqual(@as(usize, 2), count(TestWorld, &world, .{Position}, .{Age}));

    global_count = 0;
    each(TestWorld, &world, .{Position}, .{Velocity}, &countCb);
    try testing.expectEqual(@as(usize, 1), global_count);
}

test "iterator with not support" {
    var world = try TestWorld.init(testing.allocator, 8);
    defer world.deinit();

    const e0 = try world.create();
    try world.add(Position, e0, .{ .x = 0, .y = 0 });
    try world.add(Velocity, e0, .{ .x = 1, .y = 1 });

    const e1 = try world.create();
    try world.add(Position, e1, .{ .x = 0, .y = 0 });

    var it = Iterator(TestWorld, .{Position}, .{Velocity}).init(&world);
    var found: usize = 0;
    while (it.next()) |_| found += 1;
    try testing.expectEqual(@as(usize, 1), found);
}

test "query with empty world returns nothing" {
    var world = try TestWorld.init(testing.allocator, 4);
    defer world.deinit();
    try testing.expectEqual(@as(usize, 0), count(TestWorld, &world, .{ Position, Velocity }, .{}));
}

test "plain iterator still works" {
    var world = try TestWorld.init(testing.allocator, 8);
    defer world.deinit();

    const e0 = try world.create();
    try world.add(Position, e0, .{ .x = 0, .y = 0 });
    try world.add(Velocity, e0, .{ .x = 1, .y = 1 });

    const e1 = try world.create();
    try world.add(Position, e1, .{ .x = 0, .y = 0 });

    var it = Iterator(TestWorld, .{ Position, Velocity }, .{}).init(&world);
    var found: usize = 0;
    while (it.next()) |_| found += 1;
    try testing.expectEqual(@as(usize, 1), found);
}
