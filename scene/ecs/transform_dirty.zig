//! Incremental 3D transform propagation.
//!
//! `tryMarkDirty` marks an entity and its descendants for recomputation;
//! `tryPropagateDirty` processes affected subtrees parent-first, regardless of
//! entity slot order. The work scales with the marked subtrees plus ancestor
//! walks; an empty dirty set takes O(1). Setup may allocate. Errors are exposed
//! by the `try` APIs; the original void APIs remain available and fail fast.
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

/// Original void API. For recoverable errors, use `tryMarkDirty` instead.
pub fn markDirty(comptime WorldT: type, world: *WorldT, entity: Entity) void {
    tryMarkDirty(WorldT, world, entity) catch |err| {
        std.debug.panic("markDirty failed: {s}; use tryMarkDirty to handle errors", .{@errorName(err)});
    };
}

/// Marks an entity and implicitly its subtree. No mutation occurs on failure.
pub fn tryMarkDirty(comptime WorldT: type, world: *WorldT, entity: Entity) !void {
    if (!world.isAlive(entity)) return error.InvalidEntity;
    if (world.get(TransformDirty, entity)) |dirty| {
        dirty.subtree_dirty = true;
    } else {
        try world.add(TransformDirty, entity, .{ .subtree_dirty = true });
    }
}

/// Original void API. For recoverable errors, use `tryPropagateDirty` instead.
pub fn propagateDirty(comptime WorldT: type, world: *WorldT) void {
    tryPropagateDirty(WorldT, world) catch |err| {
        std.debug.panic("propagateDirty failed: {s}; use tryPropagateDirty to handle errors", .{@errorName(err)});
    };
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
