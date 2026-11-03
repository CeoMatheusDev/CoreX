//! Multi-component queries: iterate entities that have ALL of a set of
//! component types. The first type in `Types` drives iteration; put the
//! rarest component first for best performance. Remaining types are probed
//! with O(1) sparse-set lookups. Allocation-free on the hot path.
const std = @import("std");
const entity_mod = @import("entity.zig");
const Entity = entity_mod.Entity;

/// Iterates entities having all `Types`, calling `callback(world, entity)`.
/// `Types[0]` drives iteration — order the rarest component first.
pub fn each(comptime WorldT: type, world: *const WorldT, comptime Types: anytype, callback: *const fn (*const WorldT, Entity) void) void {
    comptime {
        if (Types.len == 0) @compileError("query requires at least one component type");
        if (Types.len > 8) @compileError("query supports at most 8 component types");
    }
    const Driver = Types[0];
    const driver_entities = world.entities(Driver);
    for (driver_entities) |entity| {
        if (!hasAllRest(WorldT, world, Types, entity)) continue;
        callback(world, entity);
    }
}

/// Iterator-style API: returns the next matching entity or null.
pub fn Iterator(comptime WorldT: type, comptime Types: anytype) type {
    return struct {
        const Self = @This();
        world: *const WorldT,
        driver_entities: []const Entity,
        pos: usize = 0,

        pub fn init(world: *const WorldT) Self {
            const Driver = Types[0];
            return .{
                .world = world,
                .driver_entities = world.entities(Driver),
            };
        }

        pub fn next(self: *Self) ?Entity {
            while (self.pos < self.driver_entities.len) {
                const entity = self.driver_entities[self.pos];
                self.pos += 1;
                if (hasAllRest(WorldT, self.world, Types, entity)) {
                    return entity;
                }
            }
            return null;
        }
    };
}

/// Counts entities matching all `Types` without calling a callback.
pub fn count(comptime WorldT: type, world: *const WorldT, comptime Types: anytype) usize {
    var n: usize = 0;
    const Driver = Types[0];
    const driver_entities = world.entities(Driver);
    for (driver_entities) |entity| {
        if (hasAllRest(WorldT, world, Types, entity)) n += 1;
    }
    return n;
}

fn hasAllRest(comptime WorldT: type, world: *const WorldT, comptime Types: anytype, entity: Entity) bool {
    inline for (Types, 0..) |T, i| {
        if (i == 0) continue; // driver already iterated
        if (world.getConst(T, entity) == null) return false;
    }
    return true;
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

test "each finds entities with all queried components" {
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
    each(TestWorld, &world, .{ Position, Velocity }, &countCb);
    try testing.expectEqual(@as(usize, 2), global_count);

    // Velocity first (smaller set) as driver.
    global_count = 0;
    each(TestWorld, &world, .{ Velocity, Position, Age }, &countCb);
    try testing.expectEqual(@as(usize, 1), global_count);

    try testing.expectEqual(@as(usize, 3), count(TestWorld, &world, .{Position}));
    try testing.expectEqual(@as(usize, 2), count(TestWorld, &world, .{ Position, Velocity }));
    try testing.expectEqual(@as(usize, 1), count(TestWorld, &world, .{ Velocity, Position, Age }));
}

test "query with empty world returns nothing" {
    var world = try TestWorld.init(testing.allocator, 4);
    defer world.deinit();
    try testing.expectEqual(@as(usize, 0), count(TestWorld, &world, .{ Position, Velocity }));
}

test "iterator walks matching entities" {
    var world = try TestWorld.init(testing.allocator, 8);
    defer world.deinit();

    const e0 = try world.create();
    try world.add(Position, e0, .{ .x = 0, .y = 0 });
    try world.add(Velocity, e0, .{ .x = 1, .y = 1 });

    const e1 = try world.create();
    try world.add(Position, e1, .{ .x = 0, .y = 0 });

    const e2 = try world.create();
    try world.add(Position, e2, .{ .x = 0, .y = 0 });
    try world.add(Velocity, e2, .{ .x = 2, .y = 2 });

    var it = Iterator(TestWorld, .{ Position, Velocity }).init(&world);
    var found: usize = 0;
    while (it.next()) |_| found += 1;
    try testing.expectEqual(@as(usize, 2), found);
}
