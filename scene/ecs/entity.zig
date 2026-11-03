//! Entity handles and the generation-aware slot pool owned by a World.
//!
//! A handle is a value, never a pointer: `{ index, generation }` is exactly
//! eight bytes. A slot is alive when its generation is even and its index is
//! below the high-water mark. Destroying a slot increments the generation
//! (making it odd/dead) and pushes the index onto a LIFO free list; reusing it
//! increments the generation again (making it even/alive). No bitset or
//! per-entity object is stored separately.
const std = @import("std");

pub const Entity = struct {
    index: u32 = 0,
    generation: u32 = 0,

    pub fn eql(self: Entity, other: Entity) bool {
        return self.index == other.index and self.generation == other.generation;
    }
};

pub const Error = error{ InvalidEntity, EntityIndexOverflow };

/// Owns the generation array and the free-list array. `World` embeds one pool
/// and is its only owner; the pool never keeps pointers into component storage.
pub const EntityPool = struct {
    allocator: std.mem.Allocator,
    generations: []u32,
    free_list: []u32,
    high_water: u32 = 0,
    free_len: usize = 0,
    alive: u32 = 0,
    retired: u32 = 0,

    /// `capacity` is the initial number of slots. Zero is accepted and grows
    /// lazily on the first create.
    pub fn init(allocator: std.mem.Allocator, initial_capacity: u32) !EntityPool {
        const generations = try allocator.alloc(u32, initial_capacity);
        errdefer allocator.free(generations);
        const free_list = try allocator.alloc(u32, initial_capacity);
        @memset(generations, 0);
        return .{
            .allocator = allocator,
            .generations = generations,
            .free_list = free_list,
        };
    }

    pub fn deinit(self: *EntityPool) void {
        self.allocator.free(self.generations);
        self.allocator.free(self.free_list);
        self.* = undefined;
    }

    pub fn capacity(self: *const EntityPool) u32 {
        return @intCast(self.generations.len);
    }

    pub fn highWater(self: *const EntityPool) u32 {
        return self.high_water;
    }

    pub fn aliveCount(self: *const EntityPool) u32 {
        return self.alive;
    }

    pub fn freeCount(self: *const EntityPool) usize {
        return self.free_len;
    }

    pub fn retiredCount(self: *const EntityPool) u32 {
        return self.retired;
    }

    pub fn generationAt(self: *const EntityPool, index: u32) ?u32 {
        if (index >= self.high_water) return null;
        return self.generations[index];
    }

    /// Alive means index below the high-water mark and an even generation.
    pub fn isAlive(self: *const EntityPool, entity: Entity) bool {
        if (entity.index >= self.high_water) return false;
        if (self.generations[entity.index] != entity.generation) return false;
        return (entity.generation & 1) == 0;
    }

    pub fn validate(self: *const EntityPool, entity: Entity) Error!void {
        if (!self.isAlive(entity)) return error.InvalidEntity;
    }

    pub fn entityAt(self: *const EntityPool, index: u32) ?Entity {
        if (index >= self.high_water) return null;
        const generation = self.generations[index];
        if ((generation & 1) != 0) return null;
        return .{ .index = index, .generation = generation };
    }

    /// Makes sure the next `create` can return without growing. Growing is a
    /// separate step so `World` can grow every sparse array before a new slot
    /// becomes visible.
    pub fn ensureAvailableSlot(self: *EntityPool) !void {
        if (self.free_len != 0) return;
        if (self.high_water < self.generations.len) return;
        try self.grow();
    }

    pub fn create(self: *EntityPool) !Entity {
        try self.ensureAvailableSlot();
        if (self.free_len != 0) {
            self.free_len -= 1;
            const index = self.free_list[self.free_len];
            const generation = self.generations[index] + 1;
            std.debug.assert((generation & 1) == 0);
            self.generations[index] = generation;
            self.alive += 1;
            return .{ .index = index, .generation = generation };
        }
        const index = self.high_water;
        self.high_water += 1;
        self.alive += 1;
        return .{ .index = index, .generation = self.generations[index] };
    }

    /// Destroys a live handle. A slot whose generation reaches `maxInt(u32)`
    /// is retired permanently instead of returning to the free list.
    pub fn destroy(self: *EntityPool, entity: Entity) Error!void {
        try self.validate(entity);
        const generation = self.generations[entity.index] + 1;
        self.generations[entity.index] = generation;
        self.alive -= 1;
        if (generation == std.math.maxInt(u32)) {
            self.retired += 1;
        } else {
            self.free_list[self.free_len] = entity.index;
            self.free_len += 1;
        }
    }

    fn grow(self: *EntityPool) !void {
        const old_capacity = self.generations.len;
        var new_capacity: usize = if (old_capacity == 0) 4 else old_capacity * 2;
        if (new_capacity > std.math.maxInt(u32)) new_capacity = std.math.maxInt(u32);
        if (new_capacity <= old_capacity) return error.EntityIndexOverflow;

        const generations = try self.allocator.alloc(u32, new_capacity);
        errdefer self.allocator.free(generations);
        const free_list = try self.allocator.alloc(u32, new_capacity);
        @memcpy(generations[0..old_capacity], self.generations);
        @memset(generations[old_capacity..], 0);
        @memcpy(free_list[0..self.free_len], self.free_list[0..self.free_len]);

        self.allocator.free(self.generations);
        self.allocator.free(self.free_list);
        self.generations = generations;
        self.free_list = free_list;
    }
};

const testing = std.testing;

test "create assigns sequential indices with generation zero" {
    var pool = try EntityPool.init(testing.allocator, 4);
    defer pool.deinit();
    const first = try pool.create();
    const second = try pool.create();
    try testing.expectEqual(@as(u32, 0), first.index);
    try testing.expectEqual(@as(u32, 0), first.generation);
    try testing.expectEqual(@as(u32, 1), second.index);
    try testing.expectEqual(@as(u32, 0), second.generation);
    try testing.expect(pool.isAlive(first));
    try testing.expect(pool.isAlive(second));
    try testing.expectEqual(@as(u32, 2), pool.aliveCount());
    try testing.expectEqual(@as(u32, 2), pool.highWater());
}

test "destroy invalidates the old handle and reuses the slot LIFO" {
    var pool = try EntityPool.init(testing.allocator, 4);
    defer pool.deinit();
    const first = try pool.create();
    const second = try pool.create();
    try pool.destroy(first);
    try testing.expect(!pool.isAlive(first));
    try testing.expectEqual(@as(u32, 1), pool.aliveCount());
    try testing.expectEqual(@as(usize, 1), pool.freeCount());
    const reused = try pool.create();
    try testing.expectEqual(first.index, reused.index);
    try testing.expectEqual(first.generation + 2, reused.generation);
    try testing.expect((reused.generation & 1) == 0);
    try testing.expect(!pool.isAlive(first));
    try testing.expect(pool.isAlive(reused));
    // The second slot was never destroyed, so it is untouched.
    try testing.expect(pool.isAlive(second));
}

test "the free list is LIFO across several destroyed slots" {
    var pool = try EntityPool.init(testing.allocator, 4);
    defer pool.deinit();
    const a = try pool.create();
    const b = try pool.create();
    const c = try pool.create();
    try pool.destroy(a);
    try pool.destroy(c);
    try testing.expectEqual(c.index, (try pool.create()).index);
    try testing.expectEqual(a.index, (try pool.create()).index);
    try testing.expect(pool.isAlive(b));
}

test "invalid and stale handles are rejected without changing the pool" {
    var pool = try EntityPool.init(testing.allocator, 2);
    defer pool.deinit();
    const first = try pool.create();
    try testing.expectError(error.InvalidEntity, pool.destroy(.{ .index = 99, .generation = 0 }));
    try testing.expectError(error.InvalidEntity, pool.destroy(.{ .index = first.index, .generation = 2 }));
    try testing.expectEqual(@as(u32, 1), pool.aliveCount());
    try pool.destroy(first);
    try testing.expectError(error.InvalidEntity, pool.destroy(first));
    try testing.expectEqual(@as(u32, 0), pool.aliveCount());
}

test "growth by doubling preserves live slots and the free list" {
    var pool = try EntityPool.init(testing.allocator, 2);
    defer pool.deinit();
    const a = try pool.create();
    const b = try pool.create();
    try pool.destroy(a);
    const c = try pool.create();
    const d = try pool.create();
    try testing.expectEqual(@as(u32, 4), pool.capacity());
    try testing.expect(pool.isAlive(b));
    try testing.expect(pool.isAlive(c));
    try testing.expect(pool.isAlive(d));
    try testing.expectEqual(@as(u32, 3), pool.aliveCount());
}

test "a slot that reaches maxInt generation is retired" {
    var pool = try EntityPool.init(testing.allocator, 2);
    defer pool.deinit();
    const first = try pool.create();
    pool.generations[first.index] = std.math.maxInt(u32) - 1;
    const almost_retired = Entity{ .index = first.index, .generation = std.math.maxInt(u32) - 1 };
    try testing.expect(pool.isAlive(almost_retired));
    try pool.destroy(almost_retired);
    try testing.expectEqual(@as(u32, 1), pool.retiredCount());
    try testing.expectEqual(@as(usize, 0), pool.freeCount());
    // The retired slot is never handed out again; the pool grows or uses a
    // fresh slot instead.
    const next = try pool.create();
    try testing.expect(next.index != first.index);
    try testing.expect(pool.isAlive(next));
}

test "a zero-capacity pool grows lazily" {
    var pool = try EntityPool.init(testing.allocator, 0);
    defer pool.deinit();
    const first = try pool.create();
    try testing.expectEqual(@as(u32, 4), pool.capacity());
    try testing.expect(pool.isAlive(first));
}

test "allocation failure during growth leaves the pool usable" {
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn probe(allocator: std.mem.Allocator) !void {
            var pool = try EntityPool.init(allocator, 2);
            defer pool.deinit();
            const first = try pool.create();
            const second = try pool.create();
            try testing.expect(pool.isAlive(first));
            try testing.expect(pool.isAlive(second));
            _ = try pool.create();
        }
    }.probe, .{});
}
