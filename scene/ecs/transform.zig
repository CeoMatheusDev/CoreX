//! Transform hierarchy: local and world transforms propagated through the
//! entity parent/child graph. Built on top of `hierarchy.zig` — no changes
//! to the World required, just two more `SparseSet` components.
//!
//! `LocalTransform` is authored (position relative to parent).
//! `WorldTransform` is computed by `propagateTransforms` (roots use their
//! local as world; children add parent's world). Deterministic: parents are
//! always processed before children because we walk in ascending entity
//! index order and parents are created first in practice — for full safety
//! the propagation iterates until stable or uses the hierarchy depth.
const std = @import("std");
const entity_mod = @import("entity.zig");
const Entity = entity_mod.Entity;
const hierarchy = @import("hierarchy.zig");

/// Position relative to the parent entity.
pub const LocalTransform = struct {
    x: i64 = 0,
    y: i64 = 0,
};

/// Computed world-space position.
pub const WorldTransform = struct {
    x: i64 = 0,
    y: i64 = 0,
};

/// Propagates local transforms to world transforms through the hierarchy.
/// Roots: world = local. Children: world = parent.world + local.
/// Iterates in ascending entity index order; because setParent prevents
/// cycles and parents are typically created before children, a single pass
/// in index order suffices. For robustness against out-of-order creation,
/// we do up to `highWater` passes (bounded, deterministic).
pub fn propagateTransforms(comptime WorldT: type, world: *WorldT) void {
    const hw = world.highWater();
    var pass: u32 = 0;
    while (pass < hw) : (pass += 1) {
        var index: u32 = 0;
        while (index < hw) : (index += 1) {
            const entity = world.entityAt(index) orelse continue;
            const local = world.getConst(LocalTransform, entity) orelse continue;
            const parent_entity = hierarchy.getParent(WorldT, world, entity);
            if (parent_entity) |p| {
                if (world.getConst(WorldTransform, p)) |pw| {
                    if (world.get(WorldTransform, entity)) |ew| {
                        ew.x = pw.x + local.x;
                        ew.y = pw.y + local.y;
                    } else {
                        world.add(WorldTransform, entity, .{ .x = pw.x + local.x, .y = pw.y + local.y }) catch {};
                    }
                }
                // If parent has no WorldTransform yet, skip this pass.
            } else {
                // Root: world = local.
                if (world.get(WorldTransform, entity)) |ew| {
                    ew.x = local.x;
                    ew.y = local.y;
                } else {
                    world.add(WorldTransform, entity, .{ .x = local.x, .y = local.y }) catch {};
                }
            }
        }
    }
}

/// Convenience: computes the world transform of a single entity on demand.
pub fn worldPosition(comptime WorldT: type, world: *const WorldT, entity: Entity) ?WorldTransform {
    return world.getConst(WorldTransform, entity);
}

const testing = std.testing;
const sparse_set = @import("sparse_set.zig");
const world_mod = @import("world.zig");

const TransformStores = struct {
    parent: sparse_set.SparseSet(hierarchy.Parent),
    children: sparse_set.SparseSet(hierarchy.Children),
    local: sparse_set.SparseSet(LocalTransform),
    world_t: sparse_set.SparseSet(WorldTransform),
};

const TestWorld = world_mod.World(TransformStores);

test "root entity world transform equals local" {
    var world = try TestWorld.init(testing.allocator, 8);
    defer world.deinit();
    defer hierarchy.clear(TestWorld, testing.allocator, &world);

    const root = try world.create();
    try world.add(LocalTransform, root, .{ .x = 10, .y = 20 });

    propagateTransforms(TestWorld, &world);
    const wt = world.getConst(WorldTransform, root).?;
    try testing.expectEqual(@as(i64, 10), wt.x);
    try testing.expectEqual(@as(i64, 20), wt.y);
}

test "child world transform is parent world plus local" {
    var world = try TestWorld.init(testing.allocator, 8);
    defer world.deinit();
    defer hierarchy.clear(TestWorld, testing.allocator, &world);

    const parent_e = try world.create();
    try world.add(LocalTransform, parent_e, .{ .x = 100, .y = 0 });

    const child = try world.create();
    try world.add(LocalTransform, child, .{ .x = 5, .y = 7 });
    try hierarchy.setParent(TestWorld, testing.allocator, &world, parent_e, child);

    propagateTransforms(TestWorld, &world);

    const pw = world.getConst(WorldTransform, parent_e).?;
    try testing.expectEqual(@as(i64, 100), pw.x);

    const cw = world.getConst(WorldTransform, child).?;
    try testing.expectEqual(@as(i64, 105), cw.x);
    try testing.expectEqual(@as(i64, 7), cw.y);
}

test "grandchild accumulates through the chain" {
    var world = try TestWorld.init(testing.allocator, 8);
    defer world.deinit();
    defer hierarchy.clear(TestWorld, testing.allocator, &world);

    const a = try world.create();
    try world.add(LocalTransform, a, .{ .x = 1, .y = 1 });
    const b = try world.create();
    try world.add(LocalTransform, b, .{ .x = 2, .y = 2 });
    const c = try world.create();
    try world.add(LocalTransform, c, .{ .x = 3, .y = 3 });

    try hierarchy.setParent(TestWorld, testing.allocator, &world, a, b);
    try hierarchy.setParent(TestWorld, testing.allocator, &world, b, c);

    propagateTransforms(TestWorld, &world);

    try testing.expectEqual(@as(i64, 1), world.getConst(WorldTransform, a).?.x);
    try testing.expectEqual(@as(i64, 3), world.getConst(WorldTransform, b).?.x);
    try testing.expectEqual(@as(i64, 6), world.getConst(WorldTransform, c).?.x);
    try testing.expectEqual(@as(i64, 6), world.getConst(WorldTransform, c).?.y);
}

test "moving parent updates children after re-propagation" {
    var world = try TestWorld.init(testing.allocator, 8);
    defer world.deinit();
    defer hierarchy.clear(TestWorld, testing.allocator, &world);

    const p = try world.create();
    try world.add(LocalTransform, p, .{ .x = 0, .y = 0 });
    const c = try world.create();
    try world.add(LocalTransform, c, .{ .x = 10, .y = 0 });
    try hierarchy.setParent(TestWorld, testing.allocator, &world, p, c);

    propagateTransforms(TestWorld, &world);
    try testing.expectEqual(@as(i64, 10), world.getConst(WorldTransform, c).?.x);

    // Move parent.
    world.get(LocalTransform, p).?.x = 50;
    propagateTransforms(TestWorld, &world);
    try testing.expectEqual(@as(i64, 60), world.getConst(WorldTransform, c).?.x);
}
