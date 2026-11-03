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
const sparse_set = @import("sparse_set.zig");

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

/// True when the World's Stores struct contains a sparse set for `Component`.
/// Detection is by type, not by a particular field name.
pub fn hasStore(comptime Stores: type, comptime Component: type) bool {
    inline for (@typeInfo(Stores).@"struct".field_types) |Field| {
        if (Field == sparse_set.SparseSet(Component)) return true;
    }
    return false;
}

/// Validate a parent forest whose indices refer to positions in `parents`.
/// Every node is visited a constant number of times; no recursion is used.
pub fn validateParentIndices(allocator: std.mem.Allocator, parents: []const ?u32) !void {
    var has_parent = false;
    for (parents) |parent| {
        if (parent) |p| {
            if (p >= parents.len) return error.InvalidParentIndex;
            has_parent = true;
        }
    }
    if (!has_parent) return;

    const marks = try allocator.alloc(u8, parents.len);
    defer allocator.free(marks);
    @memset(marks, 0); // 0 = unseen, 1 = current path, 2 = complete
    for (parents, 0..) |_, start| {
        var current: ?usize = start;
        while (current) |index| {
            if (marks[index] == 2) break;
            if (marks[index] == 1) return error.CycleDetected;
            marks[index] = 1;
            current = if (parents[index]) |p| @as(usize, p) else null;
        }
        current = start;
        while (current) |index| {
            if (marks[index] != 1) break;
            marks[index] = 2;
            current = if (parents[index]) |p| @as(usize, p) else null;
        }
    }
}

/// Sets `child`'s parent to `parent_entity`, rejecting cycles. On allocation
/// failure the previous relationship and both child lists remain unchanged.
pub fn setParent(comptime WorldT: type, allocator: std.mem.Allocator, world: *WorldT, parent_entity: Entity, child: Entity) HierarchyError!void {
    if (!world.isAlive(parent_entity) or !world.isAlive(child)) return error.NotAlive;
    if (parent_entity.eql(child)) return error.CycleDetected;
    if (isAncestor(WorldT, world, parent_entity, child)) return error.CycleDetected;

    const previous = if (world.getConst(Parent, child)) |p| p.entity else null;
    if (previous) |p| if (p.eql(parent_entity)) return;

    // Stage both replacement lists before mutating the World. A Children value
    // stores an exact-size slice; World itself never destroys its pointees.
    const old_children: ?[]Entity = if (previous) |p| blk: {
        const old = world.getConst(Children, p) orelse return error.NotAChild;
        break :blk old.entities;
    } else null;
    const remaining = if (old_children) |list| try withoutChild(allocator, list, child) else null;
    errdefer if (remaining) |list| allocator.free(list);

    const target_children: ?[]Entity = if (world.getConst(Children, parent_entity)) |c| c.entities else null;
    const target_len: usize = if (target_children) |list| list.len else 0;
    const appended = try allocator.alloc(Entity, target_len + 1);
    errdefer allocator.free(appended);
    if (target_children) |list| @memcpy(appended[0..target_len], list);
    appended[target_len] = child;

    try world.add(Parent, child, .{ .entity = parent_entity });
    errdefer {
        if (previous) |p| {
            // Replacing an existing component does not allocate.
            world.add(Parent, child, .{ .entity = p }) catch unreachable;
        } else {
            _ = world.remove(Parent, child) catch unreachable;
        }
    }
    try world.add(Children, parent_entity, .{ .entities = appended });

    // Nothing below can fail. Reacquire store pointers after a possible grow.
    if (target_children) |list| allocator.free(list);
    if (previous) |p| {
        if (remaining) |list| {
            world.get(Children, p).?.entities = list;
        } else {
            _ = world.remove(Children, p) catch unreachable;
        }
        allocator.free(old_children.?);
    }
}

/// Removes `child` from its parent. The child becomes a root. A failed
/// allocation while shrinking a sibling list leaves the relation unchanged.
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
/// parent (or makes them roots). Call before `world.destroy(entity)`. If an
/// allocation fails, earlier moves remain valid and the operation can be retried.
pub fn onDestroy(comptime WorldT: type, allocator: std.mem.Allocator, world: *WorldT, entity: Entity) !void {
    if (!world.isAlive(entity)) return error.NotAlive;
    const parent_entity = getParent(WorldT, world, entity);
    while (true) {
        const kids = getChildren(WorldT, world, entity);
        if (kids.len == 0) break;
        const kid = kids[kids.len - 1];
        if (parent_entity) |parent| {
            try setParent(WorldT, allocator, world, parent, kid);
        } else {
            try removeParent(WorldT, allocator, world, kid);
        }
    }
    try removeParent(WorldT, allocator, world, entity);
}

/// Removes all hierarchy components and frees their child lists. Call before
/// World.deinit; use the same allocator that was passed to hierarchy methods.
/// As with every pointer-containing component, World does not own the slices.
pub fn clear(comptime WorldT: type, allocator: std.mem.Allocator, world: *WorldT) void {
    while (world.entities(Children).len != 0) {
        const entity = world.entities(Children)[world.entities(Children).len - 1];
        const removed = (world.remove(Children, entity) catch unreachable).?;
        allocator.free(removed.entities);
    }
    while (world.entities(Parent).len != 0) {
        const entity = world.entities(Parent)[world.entities(Parent).len - 1];
        _ = world.remove(Parent, entity) catch unreachable;
    }
}

/// Build an exact-size list, using the existing swap-remove ordering.
fn withoutChild(allocator: std.mem.Allocator, children: []const Entity, child: Entity) !?[]Entity {
    var index: usize = 0;
    while (index < children.len and !children[index].eql(child)) : (index += 1) {}
    if (index == children.len) return error.NotAChild;
    if (children.len == 1) return null;
    const remaining = try allocator.alloc(Entity, children.len - 1);
    @memcpy(remaining, children[0..remaining.len]);
    if (index < remaining.len) remaining[index] = children[children.len - 1];
    return remaining;
}

fn detachChild(comptime WorldT: type, allocator: std.mem.Allocator, world: *WorldT, parent_entity: Entity, child: Entity) !void {
    const c = world.getConst(Children, parent_entity) orelse return error.NotAChild;
    const old = c.entities;
    const remaining = try withoutChild(allocator, old, child);
    if (remaining) |list| {
        world.get(Children, parent_entity).?.entities = list;
    } else {
        _ = world.remove(Children, parent_entity) catch unreachable;
    }
    allocator.free(old);
}

const testing = std.testing;
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
    defer clear(TestWorld, testing.allocator, &world);

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
    defer clear(TestWorld, testing.allocator, &world);

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
    defer clear(TestWorld, testing.allocator, &world);

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
    defer clear(TestWorld, testing.allocator, &world);

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
    defer clear(TestWorld, testing.allocator, &world);

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

test "detaching a last child never frees another parent's list" {
    var world = try TestWorld.init(testing.allocator, 8);
    defer world.deinit();
    defer clear(TestWorld, testing.allocator, &world);
    const p1 = try world.create();
    const p2 = try world.create();
    const c1 = try world.create();
    const c2 = try world.create();
    try setParent(TestWorld, testing.allocator, &world, p1, c1);
    try setParent(TestWorld, testing.allocator, &world, p2, c2);
    try removeParent(TestWorld, testing.allocator, &world, c1);
    try testing.expectEqual(@as(usize, 0), getChildren(TestWorld, &world, p1).len);
    try testing.expectEqual(c2, getChildren(TestWorld, &world, p2)[0]);
    try testing.expectEqual(p2, getParent(TestWorld, &world, c2).?);
}

test "reparenting is atomic across every allocation failure" {
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn probe(allocator: std.mem.Allocator) !void {
            var world = try TestWorld.init(allocator, 8);
            defer world.deinit();
            defer clear(TestWorld, allocator, &world);
            const old = try world.create();
            const new = try world.create();
            const child = try world.create();
            const sibling = try world.create();
            const other = try world.create();
            try setParent(TestWorld, allocator, &world, old, child);
            try setParent(TestWorld, allocator, &world, old, sibling);
            try setParent(TestWorld, allocator, &world, new, other);
            setParent(TestWorld, allocator, &world, new, child) catch |err| {
                try testing.expectEqual(old, getParent(TestWorld, &world, child).?);
                try testing.expectEqual(@as(usize, 2), getChildren(TestWorld, &world, old).len);
                try testing.expectEqual(@as(usize, 1), getChildren(TestWorld, &world, new).len);
                try testing.expectEqual(other, getChildren(TestWorld, &world, new)[0]);
                return err;
            };
            try testing.expectEqual(new, getParent(TestWorld, &world, child).?);
            try testing.expectEqual(sibling, getChildren(TestWorld, &world, old)[0]);
            try testing.expectEqual(@as(usize, 2), getChildren(TestWorld, &world, new).len);
        }
    }.probe, .{});
}

test "parent-index validation handles deep forward references without recursion" {
    const parents = try testing.allocator.alloc(?u32, 4096);
    defer testing.allocator.free(parents);
    for (parents, 0..) |*parent, i| parent.* = if (i + 1 < parents.len) @intCast(i + 1) else null;
    try validateParentIndices(testing.allocator, parents);
    parents[parents.len - 1] = 0;
    try testing.expectError(error.CycleDetected, validateParentIndices(testing.allocator, parents));
    parents[parents.len - 1] = @intCast(parents.len);
    try testing.expectError(error.InvalidParentIndex, validateParentIndices(testing.allocator, parents));
}

test "first parent attachment rolls back if allocation fails" {
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn probe(allocator: std.mem.Allocator) !void {
            var world = try TestWorld.init(allocator, 2);
            defer world.deinit();
            defer clear(TestWorld, allocator, &world);
            const parent = try world.create();
            const child = try world.create();
            setParent(TestWorld, allocator, &world, parent, child) catch |err| {
                try testing.expect(getParent(TestWorld, &world, child) == null);
                try testing.expectEqual(@as(usize, 0), getChildren(TestWorld, &world, parent).len);
                return err;
            };
            try testing.expectEqual(parent, getParent(TestWorld, &world, child).?);
        }
    }.probe, .{});
}

test "onDestroy reparenting stays consistent after allocation failures" {
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn probe(allocator: std.mem.Allocator) !void {
            var world = try TestWorld.init(allocator, 8);
            defer world.deinit();
            defer clear(TestWorld, allocator, &world);
            const root = try world.create();
            const parent = try world.create();
            const a = try world.create();
            const b = try world.create();
            try setParent(TestWorld, allocator, &world, root, parent);
            try setParent(TestWorld, allocator, &world, parent, a);
            try setParent(TestWorld, allocator, &world, parent, b);
            onDestroy(TestWorld, allocator, &world, parent) catch |err| {
                // Earlier moves may have completed, but every surviving link
                // remains reciprocal and the operation can be retried.
                for ([_]Entity{ a, b }) |child| {
                    const current_parent = getParent(TestWorld, &world, child).?;
                    try testing.expect(current_parent.eql(root) or current_parent.eql(parent));
                    var occurrences: usize = 0;
                    for (getChildren(TestWorld, &world, current_parent)) |entry| {
                        if (entry.eql(child)) occurrences += 1;
                    }
                    try testing.expectEqual(@as(usize, 1), occurrences);
                }
                return err;
            };
            try testing.expectEqual(root, getParent(TestWorld, &world, a).?);
            try testing.expectEqual(root, getParent(TestWorld, &world, b).?);
            try testing.expectEqual(@as(usize, 0), getChildren(TestWorld, &world, parent).len);
        }
    }.probe, .{});
}
