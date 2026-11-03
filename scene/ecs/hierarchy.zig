//! Entity hierarchy: parent/child relationships managed as components.
//!
//! Design: hierarchy is not baked into the World — it lives in regular
//! `SparseSet` components (`Parent` and `Children`), so any `World(Stores)`
//! that declares them gets hierarchy for free. This module provides the
//! operations (setParent, removeParent, children iteration, root detection,
//! cycle prevention) on top of those two components.
//!
//! Safety: reparenting rejects cycles (an entity cannot become its own
//! ancestor). Destroying an entity detaches it from its parent and reparents
//! its children to the destroyed entity's parent (or root).
const std = @import("std");
const entity_mod = @import("entity.zig");
const Entity = entity_mod.Entity;

/// Component stored on a child: points to its parent entity.
pub const Parent = struct {
    entity: Entity,
};

/// Component stored on a parent: list of child entities.
pub const Children = struct {
    entities: []Entity,
};

pub const HierarchyError = error{
    CycleDetected,
    NotAlive,
    NotAChild,
} || anyerror;

/// Returns true if `ancestor` is `entity` itself or any of its ancestors.
pub fn isAncestor(comptime WorldT: type, world: *const WorldT, entity: Entity, ancestor: Entity) bool {
    if (!world.isAlive(entity) or !world.isAlive(ancestor)) return false;
    var current = entity;
    var depth: u32 = 0;
    while (depth < world.highWater()) : (depth += 1) {
        if (current.eql(ancestor)) return true;
        const p = world.getConst(Parent, current) orelse return false;
        if (!world.isAlive(p.entity)) return false;
        current = p.entity;
    }
    return false;
}

/// Sets `child`'s parent to `parent_entity`, rejecting cycles.
pub fn setParent(comptime WorldT: type, allocator: std.mem.Allocator, world: *WorldT, parent_entity: Entity, child: Entity) HierarchyError!void {
    if (!world.isAlive(parent_entity) or !world.isAlive(child)) return error.NotAlive;
    if (parent_entity.eql(child)) return error.CycleDetected;
    if (isAncestor(WorldT, world, parent_entity, child)) return error.CycleDetected;

    // Detach from current parent if any.
    if (world.getConst(Parent, child)) |old| {
        detachChild(WorldT, allocator, world, old.entity, child) catch {};
    }

    try world.add(Parent, child, .{ .entity = parent_entity });
    try appendChild(WorldT, allocator, world, parent_entity, child);
}

/// Removes `child` from its parent. The child becomes a root.
pub fn removeParent(comptime WorldT: type, allocator: std.mem.Allocator, world: *WorldT, child: Entity) HierarchyError!void {
    const pc = world.getConst(Parent, child) orelse return;
    try detachChild(WorldT, allocator, world, pc.entity, child);
    _ = try world.remove(Parent, child);
}

/// Returns the children of `entity`, or an empty slice if none.
pub fn getChildren(comptime WorldT: type, world: *const WorldT, entity: Entity) []const Entity {
    const c = world.getConst(Children, entity) orelse return &.{};
    return c.entities;
}

/// Returns the parent of `entity`, or null if it is a root.
pub fn getParent(comptime WorldT: type, world: *const WorldT, entity: Entity) ?Entity {
    const p = world.getConst(Parent, entity) orelse return null;
    return p.entity;
}

/// Returns true if `entity` has no parent (is a root).
pub fn isRoot(comptime WorldT: type, world: *const WorldT, entity: Entity) bool {
    return world.getConst(Parent, entity) == null;
}

/// Detaches `entity` from its parent and reparents its children to `entity`'s
/// parent (or makes them roots). Call before `world.destroy(entity)`.
pub fn onDestroy(comptime WorldT: type, allocator: std.mem.Allocator, world: *WorldT, entity: Entity) !void {
    const parent_entity = getParent(WorldT, world, entity);
    const kids = getChildren(WorldT, world, entity);
    for (kids) |kid| {
        _ = try world.remove(Parent, kid);
        if (parent_entity) |p| {
            if (!p.eql(entity)) {
                try world.add(Parent, kid, .{ .entity = p });
                try appendChild(WorldT, allocator, world, p, kid);
            }
        }
    }
    if (parent_entity) |p| {
        try detachChild(WorldT, allocator, world, p, entity);
    }
    if (world.remove(Children, entity) catch null) |old| {
        allocator.free(old.entities);
    }
}

fn detachChild(comptime WorldT: type, allocator: std.mem.Allocator, world: *WorldT, parent_entity: Entity, child: Entity) !void {
    const c = world.get(Children, parent_entity) orelse return;
    var i: usize = 0;
    while (i < c.entities.len) : (i += 1) {
        if (c.entities[i].eql(child)) {
            // Swap-remove.
            c.entities[i] = c.entities[c.entities.len - 1];
            const new_len = c.entities.len - 1;
            if (new_len == 0) {
                _ = try world.remove(Children, parent_entity);
                allocator.free(c.entities);
            } else {
                c.entities = try allocator.realloc(c.entities, new_len);
            }
            return;
        }
    }
}

fn appendChild(comptime WorldT: type, allocator: std.mem.Allocator, world: *WorldT, parent_entity: Entity, child: Entity) !void {
    if (world.get(Children, parent_entity)) |c| {
        const new_list = try allocator.alloc(Entity, c.entities.len + 1);
        @memcpy(new_list[0..c.entities.len], c.entities);
        new_list[c.entities.len] = child;
        allocator.free(c.entities);
        c.entities = new_list;
    } else {
        const list = try allocator.alloc(Entity, 1);
        list[0] = child;
        try world.add(Children, parent_entity, .{ .entities = list });
    }
}

const testing = std.testing;
const sparse_set = @import("sparse_set.zig");
const world_mod = @import("world.zig");

const Position = struct { x: i64, y: i64 };

const HierStores = struct {
    position: sparse_set.SparseSet(Position),
    parent: sparse_set.SparseSet(Parent),
    children: sparse_set.SparseSet(Children),
};

const TestWorld = world_mod.World(HierStores);

test "setParent and getParent/getChildren queries" {
    var world = try TestWorld.init(testing.allocator, 8);
    defer world.deinit();

    const p = try world.create();
    const c1 = try world.create();
    const c2 = try world.create();

    try setParent(TestWorld, testing.allocator, &world, p, c1);
    try setParent(TestWorld, testing.allocator, &world, p, c2);

    try testing.expectEqual(p, getParent(TestWorld, &world, c1).?);
    try testing.expectEqual(@as(usize, 2), getChildren(TestWorld, &world, p).len);
    try testing.expect(isRoot(TestWorld, &world, p));
    try testing.expect(!isRoot(TestWorld, &world, c1));
}

test "reparenting detaches from the old parent" {
    var world = try TestWorld.init(testing.allocator, 8);
    defer world.deinit();

    const p1 = try world.create();
    const p2 = try world.create();
    const c = try world.create();

    try setParent(TestWorld, testing.allocator, &world, p1, c);
    try setParent(TestWorld, testing.allocator, &world, p2, c);

    try testing.expectEqual(@as(usize, 0), getChildren(TestWorld, &world, p1).len);
    try testing.expectEqual(@as(usize, 1), getChildren(TestWorld, &world, p2).len);
    try testing.expectEqual(p2, getParent(TestWorld, &world, c).?);
}

test "cycle detection rejects self and ancestor reparenting" {
    var world = try TestWorld.init(testing.allocator, 8);
    defer world.deinit();

    const a = try world.create();
    const b = try world.create();
    const c = try world.create();

    try setParent(TestWorld, testing.allocator, &world, a, b);
    try setParent(TestWorld, testing.allocator, &world, b, c);

    try testing.expectError(error.CycleDetected, setParent(TestWorld, testing.allocator, &world, c, a));
    try testing.expectError(error.CycleDetected, setParent(TestWorld, testing.allocator, &world, a, a));
}

test "removeParent makes the entity a root" {
    var world = try TestWorld.init(testing.allocator, 8);
    defer world.deinit();

    const p = try world.create();
    const c = try world.create();
    try setParent(TestWorld, testing.allocator, &world, p, c);
    try removeParent(TestWorld, testing.allocator, &world, c);

    try testing.expect(isRoot(TestWorld, &world, c));
    try testing.expectEqual(@as(usize, 0), getChildren(TestWorld, &world, p).len);
}

test "onDestroy reparents children to the grandparent" {
    var world = try TestWorld.init(testing.allocator, 8);
    defer world.deinit();

    const grandparent = try world.create();
    const parent_e = try world.create();
    const child = try world.create();

    try setParent(TestWorld, testing.allocator, &world, grandparent, parent_e);
    try setParent(TestWorld, testing.allocator, &world, parent_e, child);

    try onDestroy(TestWorld, testing.allocator, &world, parent_e);
    try world.destroy(parent_e);

    try testing.expectEqual(grandparent, getParent(TestWorld, &world, child).?);
    try testing.expectEqual(@as(usize, 1), getChildren(TestWorld, &world, grandparent).len);
}
