//! One dense component set with an O(1) sparse index.
//!
//! `sparse[entity.index]` stores `dense_position + 1`; zero means absent. Dense
//! entities and values stay contiguous. Removal swaps the last element into the
//! hole, so dense order is insertion order modified by swap-remove. The same
//! sequence of operations always produces the same dense order.
const std = @import("std");
const entity_mod = @import("entity.zig");
const Entity = entity_mod.Entity;

pub fn SparseSet(comptime T: type) type {
    return struct {
        const Self = @This();

        pub const Component = T;

        allocator: std.mem.Allocator,
        dense_entities: []Entity,
        dense: []T,
        sparse: []u32,
        len: usize = 0,

        pub fn init(allocator: std.mem.Allocator, entity_capacity: u32) !Self {
            const sparse = try allocator.alloc(u32, entity_capacity);
            errdefer allocator.free(sparse);
            @memset(sparse, 0);
            const dense_entities = try allocator.alloc(Entity, 0);
            errdefer allocator.free(dense_entities);
            const dense = try allocator.alloc(T, 0);
            return .{
                .allocator = allocator,
                .dense_entities = dense_entities,
                .dense = dense,
                .sparse = sparse,
            };
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.dense_entities);
            self.allocator.free(self.dense);
            self.allocator.free(self.sparse);
            self.* = undefined;
        }

        pub fn count(self: *const Self) usize {
            return self.len;
        }

        pub fn capacity(self: *const Self) u32 {
            return @intCast(self.sparse.len);
        }

        pub fn entities(self: *const Self) []const Entity {
            return self.dense_entities[0..self.len];
        }

        pub fn slice(self: *Self) []T {
            return self.dense[0..self.len];
        }

        pub fn sliceConst(self: *const Self) []const T {
            return self.dense[0..self.len];
        }

        pub fn contains(self: *const Self, entity: Entity) bool {
            return self.indexOf(entity) != null;
        }

        pub fn get(self: *Self, entity: Entity) ?*T {
            const position = self.indexOf(entity) orelse return null;
            return &self.dense[position];
        }

        pub fn getConst(self: *const Self, entity: Entity) ?*const T {
            const position = self.indexOf(entity) orelse return null;
            return &self.dense[position];
        }

        /// Inserts or replaces the value for the exact handle. A stale handle
        /// whose index belongs to a newer generation is treated as a new
        /// insertion for that index.
        pub fn insert(self: *Self, entity: Entity, value: T) !void {
            if (entity.index >= self.sparse.len) return error.EntityOutOfRange;
            if (self.sparse[entity.index] != 0) {
                const position = self.sparse[entity.index] - 1;
                if (position < self.len and self.dense_entities[position].index == entity.index) {
                    self.dense_entities[position] = entity;
                    self.dense[position] = value;
                    return;
                }
            }
            if (self.len == std.math.maxInt(u32)) return error.EntityIndexOverflow;
            try self.ensureDenseCapacity(self.len + 1);
            const position = self.len;
            self.dense_entities[position] = entity;
            self.dense[position] = value;
            self.sparse[entity.index] = @intCast(position + 1);
            self.len += 1;
        }

        /// Removes and returns the value. A stale handle returns null and does
        /// not disturb the newer generation's component.
        pub fn remove(self: *Self, entity: Entity) ?T {
            const position = self.indexOf(entity) orelse return null;
            const value = self.dense[position];
            const last = self.len - 1;
            if (position != last) {
                const moved = self.dense_entities[last];
                self.dense_entities[position] = moved;
                self.dense[position] = self.dense[last];
                self.sparse[moved.index] = @intCast(position + 1);
            }
            self.len = last;
            self.sparse[entity.index] = 0;
            return value;
        }

        /// Grows the sparse index when the World grows its entity capacity.
        pub fn ensureEntityCapacity(self: *Self, new_capacity: u32) !void {
            if (new_capacity <= self.sparse.len) return;
            const sparse = try self.allocator.alloc(u32, new_capacity);
            @memcpy(sparse[0..self.sparse.len], self.sparse);
            @memset(sparse[self.sparse.len..], 0);
            self.allocator.free(self.sparse);
            self.sparse = sparse;
        }

        fn indexOf(self: *const Self, entity: Entity) ?usize {
            if (entity.index >= self.sparse.len) return null;
            const encoded = self.sparse[entity.index];
            if (encoded == 0) return null;
            const position = encoded - 1;
            if (position >= self.len) return null;
            if (!self.dense_entities[position].eql(entity)) return null;
            return position;
        }

        fn ensureDenseCapacity(self: *Self, needed: usize) !void {
            if (needed <= self.dense.len) return;
            var new_capacity: usize = if (self.dense.len == 0) 4 else self.dense.len * 2;
            while (new_capacity < needed) new_capacity *= 2;

            const new_entities = try self.allocator.alloc(Entity, new_capacity);
            errdefer self.allocator.free(new_entities);
            const values = try self.allocator.alloc(T, new_capacity);
            @memcpy(new_entities[0..self.len], self.dense_entities[0..self.len]);
            @memcpy(values[0..self.len], self.dense[0..self.len]);

            self.allocator.free(self.dense_entities);
            self.allocator.free(self.dense);
            self.dense_entities = new_entities;
            self.dense = values;
        }
    };
}

const testing = std.testing;
const Position = struct { x: i32, y: i32 };
const Velocity = struct { x: i32, y: i32 };

test "insert get and contains use the exact handle" {
    var set = try SparseSet(Position).init(testing.allocator, 4);
    defer set.deinit();
    const e = Entity{ .index = 2, .generation = 0 };
    try set.insert(e, .{ .x = 10, .y = 20 });
    try testing.expect(set.contains(e));
    try testing.expectEqual(@as(i32, 10), set.get(e).?.x);
    try testing.expectEqual(@as(usize, 1), set.count());
    try testing.expect(!set.contains(.{ .index = 2, .generation = 2 }));
}

test "insert replaces the value of the same handle without growing" {
    var set = try SparseSet(Position).init(testing.allocator, 4);
    defer set.deinit();
    const e = Entity{ .index = 1, .generation = 0 };
    try set.insert(e, .{ .x = 1, .y = 2 });
    try set.insert(e, .{ .x = 3, .y = 4 });
    try testing.expectEqual(@as(usize, 1), set.count());
    try testing.expectEqual(@as(i32, 3), set.get(e).?.x);
    try testing.expectEqual(@as(i32, 4), set.get(e).?.y);
}

test "remove swap-removes and keeps the sparse index consistent" {
    var set = try SparseSet(Position).init(testing.allocator, 8);
    defer set.deinit();
    const a = Entity{ .index = 0, .generation = 0 };
    const b = Entity{ .index = 1, .generation = 0 };
    const c = Entity{ .index = 2, .generation = 0 };
    try set.insert(a, .{ .x = 1, .y = 1 });
    try set.insert(b, .{ .x = 2, .y = 2 });
    try set.insert(c, .{ .x = 3, .y = 3 });
    const removed = set.remove(a).?;
    try testing.expectEqual(@as(i32, 1), removed.x);
    try testing.expect(!set.contains(a));
    try testing.expect(set.contains(b));
    try testing.expect(set.contains(c));
    try testing.expectEqual(@as(i32, 2), set.get(b).?.x);
    try testing.expectEqual(@as(usize, 2), set.count());
    // The last dense element moved into the hole: [c, b].
    try testing.expectEqual(c, set.entities()[0]);
    try testing.expectEqual(b, set.entities()[1]);
}

test "removing an absent or stale handle is a no-op" {
    var set = try SparseSet(Position).init(testing.allocator, 4);
    defer set.deinit();
    const e = Entity{ .index = 1, .generation = 0 };
    try set.insert(e, .{ .x = 7, .y = 8 });
    try testing.expect(set.remove(.{ .index = 1, .generation = 2 }) == null);
    try testing.expect(set.remove(.{ .index = 3, .generation = 0 }) == null);
    try testing.expect(set.get(e) != null);
    try testing.expectEqual(@as(usize, 1), set.count());
}

test "dense iteration exposes aligned entities and values" {
    var set = try SparseSet(Velocity).init(testing.allocator, 8);
    defer set.deinit();
    const handles = [_]Entity{
        .{ .index = 4, .generation = 0 },
        .{ .index = 1, .generation = 0 },
        .{ .index = 7, .generation = 0 },
    };
    for (handles, 0..) |handle, i| {
        try set.insert(handle, .{ .x = @intCast(i), .y = @intCast(i * 2) });
    }
    try testing.expectEqual(@as(usize, 3), set.slice().len);
    try testing.expectEqual(@as(usize, 3), set.entities().len);
    for (set.slice(), 0..) |value, i| {
        try testing.expectEqual(@as(i32, @intCast(i)), value.x);
        try testing.expectEqual(handles[i], set.entities()[i]);
    }
}

test "density after removals and reinsertion is deterministic" {
    var set = try SparseSet(Position).init(testing.allocator, 8);
    defer set.deinit();
    const a = Entity{ .index = 0, .generation = 0 };
    const b = Entity{ .index = 1, .generation = 0 };
    const c = Entity{ .index = 2, .generation = 0 };
    try set.insert(a, .{ .x = 1, .y = 0 });
    try set.insert(b, .{ .x = 2, .y = 0 });
    try set.insert(c, .{ .x = 3, .y = 0 });
    _ = set.remove(b);
    try set.insert(b, .{ .x = 4, .y = 0 });
    try testing.expectEqual(@as(usize, 3), set.count());
    try testing.expectEqual(@as(i32, 1), set.slice()[0].x);
    try testing.expectEqual(@as(i32, 3), set.slice()[1].x);
    try testing.expectEqual(@as(i32, 4), set.slice()[2].x);
}

test "different component types keep independent storage" {
    var positions = try SparseSet(Position).init(testing.allocator, 4);
    defer positions.deinit();
    var velocities = try SparseSet(Velocity).init(testing.allocator, 4);
    defer velocities.deinit();
    const e = Entity{ .index = 0, .generation = 0 };
    try positions.insert(e, .{ .x = 10, .y = 20 });
    try velocities.insert(e, .{ .x = -1, .y = 2 });
    try testing.expectEqual(@as(i32, 10), positions.get(e).?.x);
    try testing.expectEqual(@as(i32, -1), velocities.get(e).?.x);
    _ = positions.remove(e);
    try testing.expect(positions.get(e) == null);
    try testing.expect(velocities.get(e) != null);
}

test "entity capacity growth preserves existing components" {
    var set = try SparseSet(Position).init(testing.allocator, 2);
    defer set.deinit();
    const a = Entity{ .index = 0, .generation = 0 };
    try set.insert(a, .{ .x = 5, .y = 6 });
    try set.ensureEntityCapacity(16);
    try testing.expectEqual(@as(u32, 16), set.capacity());
    try testing.expectEqual(@as(i32, 5), set.get(a).?.x);
    const late = Entity{ .index = 15, .generation = 0 };
    try set.insert(late, .{ .x = 7, .y = 8 });
    try testing.expectEqual(@as(i32, 7), set.get(late).?.x);
}

test "inserting beyond the sparse capacity is rejected" {
    var set = try SparseSet(Position).init(testing.allocator, 2);
    defer set.deinit();
    try testing.expectError(error.EntityOutOfRange, set.insert(.{ .index = 2, .generation = 0 }, .{ .x = 1, .y = 1 }));
}

test "allocation failures during insert and growth do not corrupt the set" {
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn probe(allocator: std.mem.Allocator) !void {
            var set = try SparseSet(Position).init(allocator, 2);
            defer set.deinit();
            const a = Entity{ .index = 0, .generation = 0 };
            try set.insert(a, .{ .x = 1, .y = 2 });
            const b = Entity{ .index = 1, .generation = 0 };
            try set.insert(b, .{ .x = 3, .y = 4 });
            try set.ensureEntityCapacity(8);
            try testing.expectEqual(@as(i32, 1), set.get(a).?.x);
            try testing.expectEqual(@as(i32, 3), set.get(b).?.x);
        }
    }.probe, .{});
}
