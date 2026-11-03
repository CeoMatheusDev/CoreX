//! Incremental 3D transform propagation.
//!
//! `tryMarkDirty` marks an entity and its descendants for recomputation;
//! `markDirty` also marks its ancestors, as in the original void API.
//! `tryPropagateDirty` processes affected subtrees parent-first, regardless of
//! entity slot order. Work scales with marked subtrees and ancestor walks; an
//! empty dirty set takes O(1). Setup may allocate. Use the `try` APIs when
//! errors must be observed; the original void APIs remain best-effort.
const std = @import("std");
const entity_mod = @import("entity.zig");
const Entity = entity_mod.Entity;
const hierarchy = @import("hierarchy.zig");
const t3d = @import("transform3d.zig");

/// Presence marks an entity for recomputation. `subtree_dirty` additionally
/// requests recomputation of every descendant, whether individually marked or
/// not. Call `tryMarkDirty` after changing a local transform or reparenting.
pub const TransformDirty = struct {
    subtree_dirty: bool = false,
};

/// Original best-effort API: mark the entity and every ancestor, so the
/// uppermost ancestor's subtree will be recomputed. Like the original API, it
/// does not report allocation failures and may leave only some markers set.
/// Use `tryMarkDirtyWithAncestors` when failure must be observed.
pub fn markDirty(comptime WorldT: type, world: *WorldT, entity: Entity) void {
    markAncestors(WorldT, world, entity, true) catch {};
}

/// Marks only an entity and implicitly its subtree. Ancestors are not marked.
/// No mutation occurs on failure; their world transforms must already be valid.
pub fn tryMarkDirty(comptime WorldT: type, world: *WorldT, entity: Entity) !void {
    if (!world.isAlive(entity)) return error.InvalidEntity;
    if (world.get(TransformDirty, entity)) |dirty| {
        dirty.subtree_dirty = true;
    } else {
        try world.add(TransformDirty, entity, .{ .subtree_dirty = true });
    }
}

/// Fallible equivalent of `markDirty`: mark the entity and its ancestors.
/// On error, earlier markers remain set; correct the problem and retry before
/// propagation. Cycles and stale parent handles are rejected without recursion.
pub fn tryMarkDirtyWithAncestors(comptime WorldT: type, world: *WorldT, entity: Entity) !void {
    try markAncestors(WorldT, world, entity, false);
}

fn markAncestors(comptime WorldT: type, world: *WorldT, entity: Entity, comptime best_effort: bool) !void {
    if (!world.isAlive(entity)) return error.InvalidEntity;
    var current: ?Entity = entity;
    var visited: u32 = 0;
    const alive = world.aliveCount();
    while (current) |node| {
        if (!world.isAlive(node)) return error.InvalidHierarchy;
        if (visited >= alive) return error.CycleDetected;
        visited += 1;
        if (best_effort) {
            // The legacy API attempts every ancestor even if one insert fails.
            tryMarkDirty(WorldT, world, node) catch {};
        } else {
            try tryMarkDirty(WorldT, world, node);
        }
        current = hierarchy.getParent(WorldT, world, node);
    }
}

/// Original best-effort API. Use `tryPropagateDirty` to observe failures;
/// on failure a marker remains available for retry rather than being lost.
pub fn propagateDirty(comptime WorldT: type, world: *WorldT) void {
    tryPropagateDirty(WorldT, world) catch {};
}

/// Recompute dirty subtrees parent-first using an iterative stack. On failure,
/// the current subtree's root remains dirty, so a caller can retry. Some world
/// transforms may already have been updated; treat them as provisional until
/// the call succeeds. The hierarchy must have reciprocal, live parent links.
pub fn tryPropagateDirty(comptime WorldT: type, world: *WorldT) !void {
    var stack: std.ArrayList(Entity) = .empty;
    defer stack.deinit(world.allocator);

    while (world.componentCount(TransformDirty) != 0) {
        const marked = world.entities(TransformDirty);
        const candidate = marked[marked.len - 1];
        var root = candidate;
        var ancestor = candidate;
        var depth: u32 = 0;
        while (hierarchy.getParent(WorldT, world, ancestor)) |parent| {
            if (!world.isAlive(parent)) return error.InvalidHierarchy;
            if (depth >= world.highWater()) return error.CycleDetected;
            depth += 1;
            if (world.has(TransformDirty, parent)) root = parent;
            ancestor = parent;
        }

        const include_subtree = world.getConst(TransformDirty, root).?.subtree_dirty;
        if (!include_subtree) {
            try recompute(WorldT, world, root);
            _ = try world.remove(TransformDirty, root);
            continue;
        }

        stack.clearRetainingCapacity();
        try stack.append(world.allocator, root);
        var visited: usize = 0;
        const alive: usize = world.aliveCount();
        while (stack.pop()) |entity| {
            if (!world.isAlive(entity) or visited >= alive) return error.InvalidHierarchy;
            visited += 1;
            try recompute(WorldT, world, entity);
            const children = hierarchy.getChildren(WorldT, world, entity);
            // A valid tree cannot visit or queue more nodes than the World has.
            // This bounds malformed duplicate/cyclic child lists without a scan
            // or per-entity scratch allocation for a healthy small subtree.
            if (children.len > alive - visited - stack.items.len) return error.InvalidHierarchy;
            // LIFO stack; reverse push preserves the exposed child order.
            var i = children.len;
            while (i > 0) {
                i -= 1;
                const child = children[i];
                if (!world.isAlive(child)) return error.InvalidHierarchy;
                const parent = hierarchy.getParent(WorldT, world, child) orelse return error.InvalidHierarchy;
                if (!parent.eql(entity)) return error.InvalidHierarchy;
                try stack.append(world.allocator, child);
            }
            // Keep the root marked until the whole subtree succeeds; after a
            // failure it covers any descendant markers already cleared.
            if (!entity.eql(root)) _ = try world.remove(TransformDirty, entity);
        }
        _ = try world.remove(TransformDirty, root);
    }
}

fn recompute(comptime WorldT: type, world: *WorldT, entity: Entity) !void {
    const local = world.getConst(t3d.LocalTransform3D, entity) orelse return;
    const local_matrix = local.matrix;
    const parent = hierarchy.getParent(WorldT, world, entity);
    const matrix: t3d.Mat4 = if (parent) |p| blk: {
        if (!world.isAlive(p)) return error.InvalidHierarchy;
        const parent_world = world.getConst(t3d.WorldTransform3D, p) orelse break :blk local_matrix;
        break :blk parent_world.matrix.mul(local_matrix);
    } else local_matrix;
    if (world.get(t3d.WorldTransform3D, entity)) |computed| {
        computed.matrix = matrix;
    } else {
        try world.add(t3d.WorldTransform3D, entity, .{ .matrix = matrix });
    }
}

/// Counts currently marked entities, not every implicit descendant.
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
    defer hierarchy.clear(TestWorld, testing.allocator, &world);

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
    defer hierarchy.clear(TestWorld, testing.allocator, &world);

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

test "dirty subtree propagates parent-first when children have lower slots" {
    var world = try TestWorld.init(testing.allocator, 8);
    defer world.deinit();
    defer hierarchy.clear(TestWorld, testing.allocator, &world);
    const grandchild = try world.create();
    const child = try world.create();
    const parent = try world.create();
    try world.add(t3d.LocalTransform3D, parent, .{ .matrix = .translation(10, 0, 0) });
    try world.add(t3d.LocalTransform3D, child, .{ .matrix = .translation(5, 0, 0) });
    try world.add(t3d.LocalTransform3D, grandchild, .{ .matrix = .translation(2, 0, 0) });
    try hierarchy.setParent(TestWorld, testing.allocator, &world, parent, child);
    try hierarchy.setParent(TestWorld, testing.allocator, &world, child, grandchild);
    try tryMarkDirty(TestWorld, &world, parent);
    try tryPropagateDirty(TestWorld, &world);
    try testing.expectEqual(@as(i32, 17), world.getConst(t3d.WorldTransform3D, grandchild).?.matrix.m03);
    world.get(t3d.LocalTransform3D, parent).?.matrix = .translation(100, 0, 0);
    // Mark in the order that exposes a parent/child ordering bug.
    try tryMarkDirty(TestWorld, &world, parent);
    try tryMarkDirty(TestWorld, &world, child);
    try tryPropagateDirty(TestWorld, &world);
    try testing.expectEqual(@as(i32, 105), world.getConst(t3d.WorldTransform3D, child).?.matrix.m03);
    try testing.expectEqual(@as(i32, 107), world.getConst(t3d.WorldTransform3D, grandchild).?.matrix.m03);
    try testing.expectEqual(@as(usize, 0), dirtyCount(TestWorld, &world));
}

test "marking a leaf does not recompute its parent or sibling" {
    var world = try TestWorld.init(testing.allocator, 8);
    defer world.deinit();
    defer hierarchy.clear(TestWorld, testing.allocator, &world);
    const parent = try world.create();
    const child = try world.create();
    const sibling = try world.create();
    try world.add(t3d.LocalTransform3D, parent, .{ .matrix = .translation(10, 0, 0) });
    try world.add(t3d.LocalTransform3D, child, .{ .matrix = .translation(5, 0, 0) });
    try world.add(t3d.LocalTransform3D, sibling, .{ .matrix = .translation(7, 0, 0) });
    try hierarchy.setParent(TestWorld, testing.allocator, &world, parent, child);
    try hierarchy.setParent(TestWorld, testing.allocator, &world, parent, sibling);
    try tryMarkDirty(TestWorld, &world, parent);
    try tryPropagateDirty(TestWorld, &world);
    world.get(t3d.WorldTransform3D, sibling).?.matrix.m03 = 777;
    world.get(t3d.LocalTransform3D, child).?.matrix = .translation(8, 0, 0);
    try tryMarkDirty(TestWorld, &world, child);
    try testing.expectEqual(@as(usize, 1), dirtyCount(TestWorld, &world));
    try tryPropagateDirty(TestWorld, &world);
    try testing.expectEqual(@as(i32, 18), world.getConst(t3d.WorldTransform3D, child).?.matrix.m03);
    try testing.expectEqual(@as(i32, 10), world.getConst(t3d.WorldTransform3D, parent).?.matrix.m03);
    try testing.expectEqual(@as(i32, 777), world.getConst(t3d.WorldTransform3D, sibling).?.matrix.m03);
}

test "single-node dirty flag does not force descendants" {
    var world = try TestWorld.init(testing.allocator, 4);
    defer world.deinit();
    defer hierarchy.clear(TestWorld, testing.allocator, &world);
    const root = try world.create();
    const child = try world.create();
    try world.add(t3d.LocalTransform3D, root, .{ .matrix = .translation(3, 0, 0) });
    try world.add(t3d.LocalTransform3D, child, .{ .matrix = .translation(2, 0, 0) });
    try hierarchy.setParent(TestWorld, testing.allocator, &world, root, child);
    try world.add(t3d.WorldTransform3D, child, .{ .matrix = .translation(99, 0, 0) });
    try world.add(TransformDirty, root, .{ .subtree_dirty = false });
    try tryPropagateDirty(TestWorld, &world);
    try testing.expectEqual(@as(i32, 3), world.getConst(t3d.WorldTransform3D, root).?.matrix.m03);
    try testing.expectEqual(@as(i32, 99), world.getConst(t3d.WorldTransform3D, child).?.matrix.m03);
}

test "dirty propagation reports cycles and stale entities without clearing flags" {
    var world = try TestWorld.init(testing.allocator, 4);
    defer world.deinit();
    defer hierarchy.clear(TestWorld, testing.allocator, &world);
    const a = try world.create();
    const b = try world.create();
    try world.add(hierarchy.Parent, a, .{ .entity = b });
    try world.add(hierarchy.Parent, b, .{ .entity = a });
    try tryMarkDirty(TestWorld, &world, a);
    try testing.expectError(error.CycleDetected, tryPropagateDirty(TestWorld, &world));
    try testing.expectEqual(@as(usize, 1), dirtyCount(TestWorld, &world));
    _ = try world.remove(hierarchy.Parent, b);
    try world.destroy(b);
    try testing.expectError(error.InvalidHierarchy, tryPropagateDirty(TestWorld, &world));
    try testing.expectError(error.InvalidEntity, tryMarkDirty(TestWorld, &world, b));
}

test "allocation failures are recoverable and preserve a retryable marker" {
    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    const allocator = failing.allocator();
    var world = try TestWorld.init(allocator, 8);
    defer world.deinit();
    defer hierarchy.clear(TestWorld, allocator, &world);
    const parent = try world.create();
    const child = try world.create();
    try world.add(t3d.LocalTransform3D, parent, .{ .matrix = .translation(10, 0, 0) });
    try world.add(t3d.LocalTransform3D, child, .{ .matrix = .translation(5, 0, 0) });
    try hierarchy.setParent(TestWorld, allocator, &world, parent, child);
    failing.fail_index = failing.alloc_index;
    try testing.expectError(error.OutOfMemory, tryMarkDirty(TestWorld, &world, parent));
    try testing.expectEqual(@as(usize, 0), dirtyCount(TestWorld, &world));
    failing.fail_index = std.math.maxInt(usize);
    try tryMarkDirty(TestWorld, &world, parent);
    // Fail after stack allocation and during the first world-transform insert.
    failing.fail_index = failing.alloc_index + 2;
    try testing.expectError(error.OutOfMemory, tryPropagateDirty(TestWorld, &world));
    try testing.expect(world.has(TransformDirty, parent));
    failing.fail_index = std.math.maxInt(usize);
    try tryPropagateDirty(TestWorld, &world);
    try testing.expectEqual(@as(i32, 15), world.getConst(t3d.WorldTransform3D, child).?.matrix.m03);
    try testing.expectEqual(@as(usize, 0), dirtyCount(TestWorld, &world));
}

test "dirty propagation cleans up on every allocation failure" {
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn probe(allocator: std.mem.Allocator) !void {
            var world = try TestWorld.init(allocator, 8);
            defer world.deinit();
            defer hierarchy.clear(TestWorld, allocator, &world);
            const parent = try world.create();
            const child = try world.create();
            try world.add(t3d.LocalTransform3D, parent, .{ .matrix = .translation(9, 0, 0) });
            try world.add(t3d.LocalTransform3D, child, .{ .matrix = .translation(4, 0, 0) });
            try hierarchy.setParent(TestWorld, allocator, &world, parent, child);
            try tryMarkDirty(TestWorld, &world, parent);
            tryPropagateDirty(TestWorld, &world) catch |err| {
                try testing.expect(world.has(TransformDirty, parent));
                return err;
            };
            try testing.expectEqual(@as(i32, 13), world.getConst(t3d.WorldTransform3D, child).?.matrix.m03);
        }
    }.probe, .{});
}

test "empty dirty propagation performs no allocation" {
    var counter = @import("../testing_allocator.zig").CountingAllocator{ .backing = testing.allocator };
    var world = try TestWorld.init(counter.allocator(), 4);
    defer world.deinit();
    defer hierarchy.clear(TestWorld, counter.allocator(), &world);
    counter.resetCounters();
    try tryPropagateDirty(TestWorld, &world);
    try testing.expectEqual(@as(usize, 0), counter.allocations);
}

test "malformed duplicate children are bounded and leave the root dirty" {
    var world = try TestWorld.init(testing.allocator, 4);
    defer world.deinit();
    defer hierarchy.clear(TestWorld, testing.allocator, &world);
    const root = try world.create();
    const child = try world.create();
    try world.add(hierarchy.Parent, child, .{ .entity = root });
    const list = try testing.allocator.dupe(Entity, &.{ child, child });
    world.add(hierarchy.Children, root, .{ .entities = list }) catch |err| {
        testing.allocator.free(list);
        return err;
    };
    try tryMarkDirty(TestWorld, &world, root);
    try testing.expectError(error.InvalidHierarchy, tryPropagateDirty(TestWorld, &world));
    try testing.expect(world.has(TransformDirty, root));
}

test "dirty propagation matches full tree recomputation across shuffled graphs" {
    const n = 64;
    var world = try TestWorld.init(testing.allocator, n);
    defer world.deinit();
    defer hierarchy.clear(TestWorld, testing.allocator, &world);
    var nodes: [n]Entity = undefined;
    var order: [n]usize = undefined;
    for (&nodes, 0..) |*entity, i| {
        entity.* = try world.create();
        try world.add(t3d.LocalTransform3D, entity.*, .{ .matrix = .translation(@intCast(i + 1), 0, 0) });
        order[i] = i;
    }
    var prng = std.Random.DefaultPrng.init(20261103);
    const random = prng.random();
    var i: usize = n;
    while (i > 1) {
        i -= 1;
        const j = random.uintLessThan(usize, i + 1);
        std.mem.swap(usize, &order[i], &order[j]);
    }
    for (order[1..], 1..) |child, position| {
        const parent = order[random.uintLessThan(usize, position)];
        try hierarchy.setParent(TestWorld, testing.allocator, &world, nodes[parent], nodes[child]);
    }
    try tryMarkDirty(TestWorld, &world, nodes[order[0]]);
    try tryPropagateDirty(TestWorld, &world);
    for (0..40) |_| {
        for (0..3) |_| {
            const entity = nodes[random.uintLessThan(usize, n)];
            world.get(t3d.LocalTransform3D, entity).?.matrix.m03 = @intCast(random.uintLessThan(u32, 100) + 1);
            try tryMarkDirty(TestWorld, &world, entity);
        }
        try tryPropagateDirty(TestWorld, &world);
        var expected: [n]i32 = @splat(0);
        for (order) |index| {
            const entity = nodes[index];
            const local = world.getConst(t3d.LocalTransform3D, entity).?.matrix.m03;
            const parent = hierarchy.getParent(TestWorld, &world, entity);
            expected[index] = local + if (parent) |p| expected[p.index] else 0;
            try testing.expectEqual(expected[index], world.getConst(t3d.WorldTransform3D, entity).?.matrix.m03);
        }
    }
}

test "legacy marking preserves ancestor markers and recomputes their subtrees" {
    var world = try TestWorld.init(testing.allocator, 8);
    defer world.deinit();
    defer hierarchy.clear(TestWorld, testing.allocator, &world);
    // Children deliberately precede their ancestors in slot order.
    const leaf = try world.create();
    const sibling = try world.create();
    const child = try world.create();
    const root = try world.create();
    try world.add(t3d.LocalTransform3D, root, .{ .matrix = .translation(1, 0, 0) });
    try world.add(t3d.LocalTransform3D, child, .{ .matrix = .translation(2, 0, 0) });
    try world.add(t3d.LocalTransform3D, leaf, .{ .matrix = .translation(3, 0, 0) });
    try world.add(t3d.LocalTransform3D, sibling, .{ .matrix = .translation(4, 0, 0) });
    try hierarchy.setParent(TestWorld, testing.allocator, &world, root, child);
    try hierarchy.setParent(TestWorld, testing.allocator, &world, child, leaf);
    try hierarchy.setParent(TestWorld, testing.allocator, &world, root, sibling);
    try tryMarkDirty(TestWorld, &world, root);
    try tryPropagateDirty(TestWorld, &world);

    world.get(t3d.LocalTransform3D, root).?.matrix.m03 = 100;
    world.get(t3d.LocalTransform3D, child).?.matrix.m03 = 10;
    world.get(t3d.LocalTransform3D, leaf).?.matrix.m03 = 5;
    world.get(t3d.LocalTransform3D, sibling).?.matrix.m03 = 7;
    // Existing false flags must become true, as in the original API.
    try world.add(TransformDirty, child, .{ .subtree_dirty = false });
    markDirty(TestWorld, &world, leaf);
    try testing.expectEqual(@as(usize, 3), dirtyCount(TestWorld, &world));
    for ([_]Entity{ leaf, child, root }) |e| {
        try testing.expect(world.getConst(TransformDirty, e).?.subtree_dirty);
    }
    try testing.expect(!world.has(TransformDirty, sibling));
    propagateDirty(TestWorld, &world);
    try testing.expectEqual(@as(usize, 0), dirtyCount(TestWorld, &world));
    try testing.expectEqual(@as(i32, 100), world.getConst(t3d.WorldTransform3D, root).?.matrix.m03);
    try testing.expectEqual(@as(i32, 110), world.getConst(t3d.WorldTransform3D, child).?.matrix.m03);
    try testing.expectEqual(@as(i32, 115), world.getConst(t3d.WorldTransform3D, leaf).?.matrix.m03);
    try testing.expectEqual(@as(i32, 107), world.getConst(t3d.WorldTransform3D, sibling).?.matrix.m03);
}

test "checked ancestor marking retains partial marks on allocation failure and can retry" {
    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    const allocator = failing.allocator();
    var world = try TestWorld.init(allocator, 8);
    defer world.deinit();
    defer hierarchy.clear(TestWorld, allocator, &world);
    var chain: [5]Entity = undefined;
    for (&chain, 0..) |*entity, index| {
        entity.* = try world.create();
        try world.add(t3d.LocalTransform3D, entity.*, .{ .matrix = .translation(1, 0, 0) });
        if (index > 0) try hierarchy.setParent(TestWorld, allocator, &world, chain[index - 1], entity.*);
    }
    // First insertion allocates two dense buffers. Growing beyond four marks
    // is the next allocation, so the root remains unmarked on this failure.
    failing.fail_index = failing.alloc_index + 2;
    try testing.expectError(error.OutOfMemory, tryMarkDirtyWithAncestors(TestWorld, &world, chain[4]));
    try testing.expectEqual(@as(usize, 4), dirtyCount(TestWorld, &world));
    try testing.expect(!world.has(TransformDirty, chain[0]));
    for (chain[1..]) |entity| try testing.expect(world.has(TransformDirty, entity));

    failing.fail_index = std.math.maxInt(usize);
    try tryMarkDirtyWithAncestors(TestWorld, &world, chain[4]);
    try testing.expectEqual(@as(usize, 5), dirtyCount(TestWorld, &world));
    try tryPropagateDirty(TestWorld, &world);
    try testing.expectEqual(@as(i32, 5), world.getConst(t3d.WorldTransform3D, chain[4]).?.matrix.m03);
    try testing.expectEqual(@as(usize, 0), dirtyCount(TestWorld, &world));
}

test "legacy void APIs remain best effort on invalid handles and allocation failure" {
    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    const allocator = failing.allocator();
    var world = try TestWorld.init(allocator, 4);
    defer world.deinit();
    defer hierarchy.clear(TestWorld, allocator, &world);
    const root = try world.create();
    const stale = try world.create();
    try world.destroy(stale);
    try world.add(t3d.LocalTransform3D, root, .{ .matrix = .translation(7, 0, 0) });
    markDirty(TestWorld, &world, stale);
    try testing.expectError(error.InvalidEntity, tryMarkDirtyWithAncestors(TestWorld, &world, stale));
    failing.fail_index = failing.alloc_index;
    markDirty(TestWorld, &world, root); // Must not panic on OOM.
    try testing.expectEqual(@as(usize, 0), dirtyCount(TestWorld, &world));

    failing.fail_index = std.math.maxInt(usize);
    markDirty(TestWorld, &world, root);
    failing.fail_index = failing.alloc_index;
    propagateDirty(TestWorld, &world); // The pending root remains retryable.
    try testing.expect(world.has(TransformDirty, root));
    failing.fail_index = std.math.maxInt(usize);
    propagateDirty(TestWorld, &world);
    try testing.expectEqual(@as(i32, 7), world.getConst(t3d.WorldTransform3D, root).?.matrix.m03);
    try testing.expectEqual(@as(usize, 0), dirtyCount(TestWorld, &world));
}

test "ancestor marking bounds cycles and detects stale parent handles" {
    var world = try TestWorld.init(testing.allocator, 4);
    defer world.deinit();
    defer hierarchy.clear(TestWorld, testing.allocator, &world);
    const a = try world.create();
    const b = try world.create();
    try world.add(hierarchy.Parent, a, .{ .entity = b });
    try world.add(hierarchy.Parent, b, .{ .entity = a });
    try testing.expectError(error.CycleDetected, tryMarkDirtyWithAncestors(TestWorld, &world, a));
    try testing.expectEqual(@as(usize, 2), dirtyCount(TestWorld, &world));
    markDirty(TestWorld, &world, a); // A corrupt cycle must not loop forever.
    propagateDirty(TestWorld, &world); // Nor panic when validation fails.
    try testing.expectEqual(@as(usize, 2), dirtyCount(TestWorld, &world));
    _ = try world.remove(hierarchy.Parent, b);
    try world.destroy(b);
    try testing.expectError(error.InvalidHierarchy, tryMarkDirtyWithAncestors(TestWorld, &world, a));
}

test "remarking an existing ancestor chain does not allocate" {
    var counter = @import("../testing_allocator.zig").CountingAllocator{ .backing = testing.allocator };
    const allocator = counter.allocator();
    var world = try TestWorld.init(allocator, 4);
    defer world.deinit();
    defer hierarchy.clear(TestWorld, allocator, &world);
    const root = try world.create();
    const child = try world.create();
    try hierarchy.setParent(TestWorld, allocator, &world, root, child);
    try tryMarkDirtyWithAncestors(TestWorld, &world, child);
    counter.resetCounters();
    markDirty(TestWorld, &world, child);
    try testing.expectEqual(@as(usize, 0), counter.allocations);
    try testing.expectEqual(@as(usize, 2), dirtyCount(TestWorld, &world));
}

test "legacy marking attempts existing ancestors after a child allocation fails" {
    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    const allocator = failing.allocator();
    var world = try TestWorld.init(allocator, 8);
    defer world.deinit();
    defer hierarchy.clear(TestWorld, allocator, &world);
    const root = try world.create();
    const parent = try world.create();
    const leaf = try world.create();
    const filler1 = try world.create();
    const filler2 = try world.create();
    try hierarchy.setParent(TestWorld, allocator, &world, root, parent);
    try hierarchy.setParent(TestWorld, allocator, &world, parent, leaf);
    for ([_]Entity{ root, parent, filler1, filler2 }) |entity| {
        try world.add(TransformDirty, entity, .{ .subtree_dirty = false });
    }
    // The dense set has four slots, so inserting the leaf needs to grow it.
    failing.fail_index = failing.alloc_index;
    markDirty(TestWorld, &world, leaf);
    try testing.expect(!world.has(TransformDirty, leaf));
    try testing.expect(world.getConst(TransformDirty, parent).?.subtree_dirty);
    try testing.expect(world.getConst(TransformDirty, root).?.subtree_dirty);
}

test "checked ancestor marking releases resources at every allocation failure" {
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn probe(allocator: std.mem.Allocator) !void {
            var world = try TestWorld.init(allocator, 8);
            defer world.deinit();
            defer hierarchy.clear(TestWorld, allocator, &world);
            var previous: ?Entity = null;
            for (0..5) |_| {
                const entity = try world.create();
                if (previous) |parent| try hierarchy.setParent(TestWorld, allocator, &world, parent, entity);
                previous = entity;
            }
            try tryMarkDirtyWithAncestors(TestWorld, &world, previous.?);
            try testing.expectEqual(@as(usize, 5), dirtyCount(TestWorld, &world));
        }
    }.probe, .{});
}
