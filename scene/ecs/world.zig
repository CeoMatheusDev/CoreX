//! Entity/component World generic over a caller-declared struct of SparseSets.
//!
//! There is no type erasure and no hash lookup on the hot path: the set of
//! component types is a comptime property of `Stores`, and every helper is
//! resolved with `inline for` over its fields. The World owns the entity pool,
//! every sparse index, every dense array and the systems that operate on it.
const std = @import("std");
const entity_mod = @import("entity.zig");
const sparse_set = @import("sparse_set.zig");
const Entity = entity_mod.Entity;
const EntityPool = entity_mod.EntityPool;
const SparseSet = sparse_set.SparseSet;

pub fn World(comptime Stores: type) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        pool: EntityPool,
        stores: Stores,

        /// All allocations are owned by the World. If any component set fails
        /// to initialize, the sets already created and the entity pool are
        /// released before the error is returned.
        pub fn init(allocator: std.mem.Allocator, entity_capacity: u32) !Self {
            var pool = try EntityPool.init(allocator, entity_capacity);
            errdefer pool.deinit();

            var stores: Stores = undefined;
            var initialized: usize = 0;
            errdefer {
                var index: usize = 0;
                inline for (@typeInfo(Stores).@"struct".field_names, @typeInfo(Stores).@"struct".field_types) |name, FieldType| {
                    _ = FieldType;
                    if (index < initialized) @field(stores, name).deinit();
                    index += 1;
                }
            }
            inline for (@typeInfo(Stores).@"struct".field_names, @typeInfo(Stores).@"struct".field_types) |name, FieldType| {
                @field(stores, name) = try FieldType.init(allocator, entity_capacity);
                initialized += 1;
            }
            return .{ .allocator = allocator, .pool = pool, .stores = stores };
        }

        pub fn deinit(self: *Self) void {
            inline for (@typeInfo(Stores).@"struct".field_names) |name| {
                @field(self.stores, name).deinit();
            }
            self.pool.deinit();
            self.* = undefined;
        }

        /// Creates a new handle. The entity pool and every sparse index grow by
        /// doubling when needed; OOM is propagated and no existing component is
        /// lost. The new slot only becomes visible after all sparse arrays can
        /// address it.
        pub fn create(self: *Self) !Entity {
            try self.pool.ensureAvailableSlot();
            inline for (@typeInfo(Stores).@"struct".field_names) |name| {
                try @field(self.stores, name).ensureEntityCapacity(self.pool.capacity());
            }
            return self.pool.create();
        }

        /// Destroys a live handle and removes every component through the
        /// comptime field list. No vtable and no allocation are involved.
        pub fn destroy(self: *Self, entity: Entity) !void {
            try self.pool.validate(entity);
            inline for (@typeInfo(Stores).@"struct".field_names) |name| {
                _ = @field(self.stores, name).remove(entity);
            }
            try self.pool.destroy(entity);
        }

        pub fn isAlive(self: *const Self, entity: Entity) bool {
            return self.pool.isAlive(entity);
        }

        pub fn aliveCount(self: *const Self) u32 {
            return self.pool.aliveCount();
        }

        pub fn entityCapacity(self: *const Self) u32 {
            return self.pool.capacity();
        }

        pub fn highWater(self: *const Self) u32 {
            return self.pool.highWater();
        }

        pub fn entityAt(self: *const Self, index: u32) ?Entity {
            return self.pool.entityAt(index);
        }

        pub fn add(self: *Self, comptime T: type, entity: Entity, value: T) !void {
            try self.pool.validate(entity);
            try self.store(T).insert(entity, value);
        }

        pub fn remove(self: *Self, comptime T: type, entity: Entity) !?T {
            try self.pool.validate(entity);
            return self.store(T).remove(entity);
        }

        /// Returns null for a stale/dead handle or a missing component. Use
        /// `add`/`remove`/`destroy` when the caller must distinguish the two.
        pub fn get(self: *Self, comptime T: type, entity: Entity) ?*T {
            if (!self.pool.isAlive(entity)) return null;
            return self.store(T).get(entity);
        }

        pub fn getConst(self: *const Self, comptime T: type, entity: Entity) ?*const T {
            if (!self.pool.isAlive(entity)) return null;
            return self.storeConst(T).getConst(entity);
        }

        pub fn has(self: *const Self, comptime T: type, entity: Entity) bool {
            return self.getConst(T, entity) != null;
        }

        pub fn slice(self: *Self, comptime T: type) []T {
            return self.store(T).slice();
        }

        pub fn sliceConst(self: *const Self, comptime T: type) []const T {
            return self.storeConst(T).sliceConst();
        }

        pub fn entities(self: *const Self, comptime T: type) []const Entity {
            return self.storeConst(T).entities();
        }

        pub fn componentCount(self: *const Self, comptime T: type) usize {
            return self.storeConst(T).count();
        }

        fn store(self: *Self, comptime T: type) *SparseSet(T) {
            inline for (@typeInfo(Stores).@"struct".field_names, @typeInfo(Stores).@"struct".field_types) |name, FieldType| {
                if (FieldType == SparseSet(T)) return &@field(self.stores, name);
            }
            @compileError("component type is not present in the World's Stores struct");
        }

        fn storeConst(self: *const Self, comptime T: type) *const SparseSet(T) {
            inline for (@typeInfo(Stores).@"struct".field_names, @typeInfo(Stores).@"struct".field_types) |name, FieldType| {
                if (FieldType == SparseSet(T)) return &@field(self.stores, name);
            }
            @compileError("component type is not present in the World's Stores struct");
        }
    };
}

const testing = std.testing;
const CountingAllocator = @import("../testing_allocator.zig").CountingAllocator;

const Position = struct { x: i32, y: i32 };
const Velocity = struct { x: i32, y: i32 };
const Health = struct { hp: u32 };
const TestStores = struct {
    position: SparseSet(Position),
    velocity: SparseSet(Velocity),
    health: SparseSet(Health),
};
const TestWorld = World(TestStores);

test "init and deinit own all storage" {
    var world = try TestWorld.init(testing.allocator, 4);
    defer world.deinit();
    try testing.expectEqual(@as(u32, 4), world.entityCapacity());
    try testing.expectEqual(@as(u32, 0), world.aliveCount());
    try testing.expectEqual(@as(usize, 0), world.componentCount(Position));
}

test "multiple component types are stored independently" {
    var world = try TestWorld.init(testing.allocator, 4);
    defer world.deinit();
    const e = try world.create();
    try world.add(Position, e, .{ .x = 1, .y = 2 });
    try world.add(Velocity, e, .{ .x = 3, .y = 4 });
    try world.add(Health, e, .{ .hp = 10 });
    try testing.expectEqual(@as(i32, 1), world.get(Position, e).?.x);
    try testing.expectEqual(@as(i32, 3), world.get(Velocity, e).?.x);
    try testing.expectEqual(@as(u32, 10), world.get(Health, e).?.hp);
    try testing.expectEqual(@as(usize, 1), world.componentCount(Position));
    try testing.expectEqual(@as(usize, 1), world.componentCount(Velocity));
}

test "destroy removes every component and invalidates the handle" {
    var world = try TestWorld.init(testing.allocator, 4);
    defer world.deinit();
    const e = try world.create();
    try world.add(Position, e, .{ .x = 1, .y = 2 });
    try world.add(Velocity, e, .{ .x = 3, .y = 4 });
    try world.add(Health, e, .{ .hp = 10 });
    try world.destroy(e);
    try testing.expect(!world.isAlive(e));
    try testing.expect(world.get(Position, e) == null);
    try testing.expect(world.get(Velocity, e) == null);
    try testing.expect(world.get(Health, e) == null);
    try testing.expectEqual(@as(usize, 0), world.componentCount(Position));
    try testing.expectEqual(@as(usize, 0), world.componentCount(Velocity));
    try testing.expectEqual(@as(usize, 0), world.componentCount(Health));
}

test "stale and invalid handles are rejected by mutating helpers" {
    var world = try TestWorld.init(testing.allocator, 4);
    defer world.deinit();
    const e = try world.create();
    try world.add(Position, e, .{ .x = 1, .y = 2 });
    try world.destroy(e);
    try testing.expectError(error.InvalidEntity, world.add(Position, e, .{ .x = 3, .y = 4 }));
    try testing.expectError(error.InvalidEntity, world.remove(Position, e));
    try testing.expectError(error.InvalidEntity, world.destroy(e));
    try testing.expectError(error.InvalidEntity, world.add(Position, .{ .index = 99, .generation = 0 }, .{ .x = 0, .y = 0 }));
    try testing.expect(world.get(Position, e) == null);
    try testing.expectEqual(@as(u32, 0), world.aliveCount());
}

test "entity growth by doubling preserves all components" {
    var world = try TestWorld.init(testing.allocator, 2);
    defer world.deinit();
    const a = try world.create();
    const b = try world.create();
    try world.add(Position, a, .{ .x = 10, .y = 20 });
    try world.add(Position, b, .{ .x = 30, .y = 40 });
    const c = try world.create();
    try testing.expectEqual(@as(u32, 4), world.entityCapacity());
    try testing.expectEqual(@as(i32, 10), world.get(Position, a).?.x);
    try testing.expectEqual(@as(i32, 30), world.get(Position, b).?.x);
    try world.add(Position, c, .{ .x = 50, .y = 60 });
    try testing.expectEqual(@as(i32, 50), world.get(Position, c).?.x);
}

test "a reused slot does not inherit components from the old generation" {
    var world = try TestWorld.init(testing.allocator, 2);
    defer world.deinit();
    const old = try world.create();
    try world.add(Position, old, .{ .x = 7, .y = 8 });
    try world.destroy(old);
    const fresh = try world.create();
    try testing.expectEqual(old.index, fresh.index);
    try testing.expect(fresh.generation != old.generation);
    try testing.expect(world.get(Position, fresh) == null);
    try world.add(Position, fresh, .{ .x = 9, .y = 10 });
    try testing.expectEqual(@as(i32, 9), world.get(Position, fresh).?.x);
    try testing.expect(world.get(Position, old) == null);
}

test "dense slices and entity lists stay aligned" {
    var world = try TestWorld.init(testing.allocator, 4);
    defer world.deinit();
    const a = try world.create();
    const b = try world.create();
    try world.add(Position, a, .{ .x = 1, .y = 1 });
    try world.add(Position, b, .{ .x = 2, .y = 2 });
    try testing.expectEqual(@as(usize, 2), world.slice(Position).len);
    try testing.expectEqual(@as(usize, 2), world.entities(Position).len);
    try testing.expectEqual(a, world.entities(Position)[0]);
    try testing.expectEqual(b, world.entities(Position)[1]);
    try testing.expectEqual(@as(i32, 1), world.sliceConst(Position)[0].x);
}

test "steady-state access performs no allocation" {
    var counter = CountingAllocator{ .backing = testing.allocator };
    var world = try TestWorld.init(counter.allocator(), 4);
    defer world.deinit();
    const e = try world.create();
    try world.add(Position, e, .{ .x = 0, .y = 0 });
    try world.add(Velocity, e, .{ .x = 1, .y = 1 });
    counter.resetCounters();
    var index: usize = 0;
    while (index < 100) : (index += 1) {
        const position = world.get(Position, e).?;
        const velocity = world.get(Velocity, e).?;
        position.x += velocity.x;
        position.y += velocity.y;
        try world.add(Position, e, position.*);
    }
    try testing.expectEqual(@as(usize, 0), counter.allocations);
    try testing.expectEqual(@as(i32, 100), world.get(Position, e).?.x);
}

test "deinit with live entities releases every allocation" {
    var world = try TestWorld.init(testing.allocator, 2);
    const e = try world.create();
    try world.add(Position, e, .{ .x = 1, .y = 2 });
    try world.add(Velocity, e, .{ .x = 3, .y = 4 });
    world.deinit();
}

test "allocation failures during init create and add leave no leak" {
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn probe(allocator: std.mem.Allocator) !void {
            var world = try TestWorld.init(allocator, 2);
            defer world.deinit();
            const first = try world.create();
            try world.add(Position, first, .{ .x = 1, .y = 2 });
            const second = try world.create();
            try world.add(Velocity, second, .{ .x = 3, .y = 4 });
            try testing.expectEqual(@as(i32, 1), world.get(Position, first).?.x);
        }
    }.probe, .{});
}
