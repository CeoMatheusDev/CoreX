//! Dirty-flag optimization for transform propagation.
//!
//! Instead of recomputing every entity's world transform every frame, callers
//! mark entities dirty when their LocalTransform changes (`markDirty`). The
//! `propagateDirty` function recomputes only dirty entities and their
//! descendants, then clears the flags. This turns O(n) per frame into O(dirty).
//!
//! Usage:
//!   1. After modifying a LocalTransform, call `markDirty(world, entity)`.
//!   2. Call `propagateDirty(world)` once per frame before reading WorldTransform.
const std = @import("std");
const entity_mod = @import("entity.zig");
const Entity = entity_mod.Entity;
const hierarchy = @import("hierarchy.zig");
const t3d = @import("transform3d.zig");

/// Component: presence means the entity's world transform needs recompute.
pub const TransformDirty = struct {
    /// Set when a descendant is also dirty (propagated flag).
    subtree_dirty: bool = false,
};

/// Marks an entity (and implicitly its subtree) as dirty.
pub fn markDirty(comptime WorldT: type, world: *WorldT, entity: Entity) void {
    // Mark the entity itself as dirty with subtree_dirty so its children
    // are also recomputed.
    if (world.get(TransformDirty, entity)) |d| {
        d.subtree_dirty = true;
    } else {
        world.add(TransformDirty, entity, .{ .subtree_dirty = true }) catch {};
    }
    // Mark ancestors' subtree_dirty so the cascade reaches this entity.
    var current = hierarchy.getParent(WorldT, world, entity);
    while (current) |p| : (current = hierarchy.getParent(WorldT, world, p)) {
        if (world.get(TransformDirty, p)) |d| {
            d.subtree_dirty = true;
        } else {
            world.add(TransformDirty, p, .{ .subtree_dirty = true }) catch {};
        }
    }
}

/// Recomputes world transforms only for dirty entities and their descendants.
/// Clears dirty flags afterward. Entities not marked dirty keep their last
/// computed WorldTransform.
pub fn propagateDirty(comptime WorldT: type, world: *WorldT) void {
    const hw = world.highWater();
    // First: cascade subtree_dirty flags to children so they get recomputed.
    var index: u32 = 0;
    while (index < hw) : (index += 1) {
        const entity = world.entityAt(index) orelse continue;
        const d = world.getConst(TransformDirty, entity) orelse continue;
        if (d.subtree_dirty) {
            for (hierarchy.getChildren(WorldT, world, entity)) |child| {
                if (!world.has(TransformDirty, child)) {
                    world.add(TransformDirty, child, .{ .subtree_dirty = true }) catch {};
                } else if (world.get(TransformDirty, child)) |cd| {
                    cd.subtree_dirty = true;
                }
            }
        }
    }
    // Multiple passes: a child may be processed before its dirty parent in
    // index order, so we iterate until no dirty entities remain.
    var pass: u32 = 0;
    while (pass < hw) : (pass += 1) {
        var any_dirty = false;
        index = 0;
        while (index < hw) : (index += 1) {
            const entity = world.entityAt(index) orelse continue;
            const dirty = world.getConst(TransformDirty, entity) orelse continue;
            _ = dirty;
            any_dirty = true;

            const local = world.getConst(t3d.LocalTransform3D, entity) orelse {
                _ = world.remove(TransformDirty, entity) catch null;
                continue;
            };
            const parent_entity = hierarchy.getParent(WorldT, world, entity);
            const world_matrix: t3d.Mat4 = if (parent_entity) |p| blk: {
                const pw = world.getConst(t3d.WorldTransform3D, p) orelse break :blk local.matrix;
                break :blk pw.matrix.mul(local.matrix);
            } else local.matrix;

            if (world.get(t3d.WorldTransform3D, entity)) |ew| {
                ew.matrix = world_matrix;
            } else {
                world.add(t3d.WorldTransform3D, entity, .{ .matrix = world_matrix }) catch {};
            }
            _ = world.remove(TransformDirty, entity) catch null;
        }
        if (!any_dirty) break;
    }
}

/// Counts currently dirty entities (for diagnostics/tests).
pub fn dirtyCount(comptime WorldT: type, world: *const WorldT) usize {
    return world.componentCount(TransformDirty);
}

const testing = std.testing;
const sparse_set = @import("sparse_set.zig");
const world_mod = @import("world.zig");

const Stores = struct {
    parent: sparse_set.SparseSet(hierarchy.Parent),
    children: sparse_set.SparseSet(hierarchy.Children),
    local: sparse_set.SparseSet(t3d.LocalTransform3D),
    world_t: sparse_set.SparseSet(t3d.WorldTransform3D),
    dirty: sparse_set.SparseSet(TransformDirty),
};

const TestWorld = world_mod.World(Stores);

test "dirty propagation recomputes only marked entities" {
    var world = try TestWorld.init(testing.allocator, 8);
    defer world.deinit();

    const p = try world.create();
    try world.add(t3d.LocalTransform3D, p, .{ .matrix = .translation(10, 0, 0) });
    const c = try world.create();
    try world.add(t3d.LocalTransform3D, c, .{ .matrix = .translation(5, 0, 0) });
    try hierarchy.setParent(TestWorld, testing.allocator, &world, p, c);

    // Full propagation first.
    t3d.propagateTransforms3D(TestWorld, &world);
    try testing.expectEqual(@as(i32, 15), world.getConst(t3d.WorldTransform3D, c).?.matrix.m03);
    try testing.expectEqual(@as(usize, 0), dirtyCount(TestWorld, &world));

    // Mark parent dirty, propagate dirty only.
    markDirty(TestWorld, &world, p);
    try testing.expect(dirtyCount(TestWorld, &world) > 0);
    propagateDirty(TestWorld, &world);
    try testing.expectEqual(@as(usize, 0), dirtyCount(TestWorld, &world));

    // Change parent local and re-propagate dirty.
    world.get(t3d.LocalTransform3D, p).?.matrix = .translation(100, 0, 0);
    markDirty(TestWorld, &world, p);
    propagateDirty(TestWorld, &world);
    try testing.expectEqual(@as(i32, 105), world.getConst(t3d.WorldTransform3D, c).?.matrix.m03);
}

test "unmarked entities keep their world transform" {
    var world = try TestWorld.init(testing.allocator, 8);
    defer world.deinit();

    const a = try world.create();
    try world.add(t3d.LocalTransform3D, a, .{ .matrix = .translation(1, 0, 0) });
    const b = try world.create();
    try world.add(t3d.LocalTransform3D, b, .{ .matrix = .translation(2, 0, 0) });

    t3d.propagateTransforms3D(TestWorld, &world);
    try testing.expectEqual(@as(i32, 1), world.getConst(t3d.WorldTransform3D, a).?.matrix.m03);
    try testing.expectEqual(@as(i32, 2), world.getConst(t3d.WorldTransform3D, b).?.matrix.m03);

    // Mark only A dirty, change A.
    world.get(t3d.LocalTransform3D, a).?.matrix = .translation(50, 0, 0);
    markDirty(TestWorld, &world, a);
    propagateDirty(TestWorld, &world);

    try testing.expectEqual(@as(i32, 50), world.getConst(t3d.WorldTransform3D, a).?.matrix.m03);
    // B was not dirty — unchanged.
    try testing.expectEqual(@as(i32, 2), world.getConst(t3d.WorldTransform3D, b).?.matrix.m03);
}
