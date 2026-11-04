//! Declared smoke scene for the headless executor.
//!
//! This is deliberately not gameplay: it is a tiny deterministic scene used to
//! prove that the Runtime drives real entities, components and systems through
//! the Core lifecycle. It has no assets, scripts, input, window or GPU. The
//! checksum covers entity handles and component values in index order; when
//! present it additionally covers hierarchy and authored/computed 3D state.
const std = @import("std");
const core = @import("corex_core");
const scene = @import("corex_scene");

pub const Position = struct { x: i64, y: i64 };
pub const Velocity = struct { x: i64, y: i64 };
pub const Age = struct { ticks: u64 };
/// Translation delta per fixed tick, in raw Q16.16 parent-space units.
pub const TransformVelocity3D = struct { x: i32 = 0, y: i32 = 0, z: i32 = 0 };

pub const Stores = struct {
    position: scene.SparseSet(Position),
    velocity: scene.SparseSet(Velocity),
    age: scene.SparseSet(Age),
    parent: scene.SparseSet(scene.hierarchy.Parent),
    children: scene.SparseSet(scene.hierarchy.Children),
    local_transform3d: scene.SparseSet(scene.transform3d.LocalTransform3D),
    world_transform3d: scene.SparseSet(scene.transform3d.WorldTransform3D),
    transform_dirty: scene.SparseSet(scene.transform_dirty.TransformDirty),
    transform_velocity3d: scene.SparseSet(TransformVelocity3D),
};

pub const World = scene.World(Stores);
pub const Scene = scene.Scene(World);

pub const config: Scene.Config = .{ .entity_capacity = 16, .system_capacity = 4 };
pub const initial_entities: u32 = 8;

pub fn init(allocator: std.mem.Allocator) !Scene {
    return Scene.init(allocator, config);
}

/// Registration order is execution order: movement first, aging second.
pub fn installSystems(scene_value: *Scene) !void {
    try scene_value.addSystem(.{ .name = "smoke.move", .update_fn = moveSystem });
    try scene_value.addSystem(.{ .name = "smoke.age", .update_fn = ageSystem });
}

/// The scratch value must remain at a stable address until the Scene stops.
/// Register after the other systems so all transform mutations precede the
/// parent-first propagation for each fixed tick.
pub fn installDynamicTransforms(scene_value: *Scene, scratch: *scene.transform_dirty.PropagationScratch) !void {
    try scene_value.addTypedSystem(scene.transform_dirty.PropagationScratch, "smoke.transform3d", scratch, moveTransforms3D);
}

/// Explicit builder step. The caller runs this after `registry.start()` so the
/// scene is already in `running` and owns its World allocations.
pub fn populate(scene_value: *Scene) !void {
    const world = scene_value.world();
    var index: u32 = 0;
    while (index < initial_entities) : (index += 1) {
        const entity = try world.create();
        try world.add(Position, entity, .{
            .x = @as(i64, index) * 10,
            .y = @as(i64, index) * 20,
        });
        try world.add(Velocity, entity, .{
            .x = 1,
            .y = if ((index & 1) == 0) 1 else -1,
        });
        try world.add(Age, entity, .{ .ticks = 0 });
    }
}

/// Computed and transient components are Runtime-owned, never file input.
pub fn validateContent(file: *const scene.content_format.SceneFile) !void {
    for (file.entities) |entity| for (entity.components) |component| {
        if (std.mem.eql(u8, component.kind, "world_transform3d") or
            std.mem.eql(u8, component.kind, "transform_dirty")) return error.InvalidTransformComponent;
    };
}

/// Compute initial world-space matrices after loading and before ticks. All
/// live entities are marked once so the dirty store has capacity for later
/// fixed-tick changes without growing for this fixed-entity Runtime slice.
pub fn prepareTransforms(scene_value: *Scene) !void {
    const world = scene_value.world();
    if (world.componentCount(scene.transform3d.LocalTransform3D) == 0) return;
    // Mark every live entity once. The shared dirty walker coalesces marked
    // subtrees, detects cycles, and handles parents after children in file order.
    var index: u32 = 0;
    while (index < world.highWater()) : (index += 1) {
        const entity = world.entityAt(index) orelse continue;
        try scene.transform_dirty.tryMarkDirty(World, world, entity);
    }
    try scene.transform_dirty.tryPropagateDirtyWithImplicitIdentity(World, world);
}

/// Reserve worst-case traversal storage before ticks only if motion can occur.
/// The Runtime does not create entities, alter the hierarchy or component
/// presence, or change velocities after setup.
pub fn prepareDynamicTransforms(scene_value: *Scene, scratch: *scene.transform_dirty.PropagationScratch) !void {
    const world = scene_value.worldConst();
    for (world.entities(TransformVelocity3D), world.sliceConst(TransformVelocity3D)) |entity, velocity| {
        if (velocity.x == 0 and velocity.y == 0 and velocity.z == 0) continue;
        if (!world.has(scene.transform3d.LocalTransform3D, entity)) continue;
        try scratch.reserve(world.aliveCount());
        return;
    }
}

pub fn entitiesAlive(scene_value: *const Scene) u32 {
    return scene_value.worldConst().aliveCount();
}

pub fn stateChecksum(scene_value: *const Scene) u64 {
    const world = scene_value.worldConst();
    var hash: u64 = 0xcbf29ce484222325;
    var index: u32 = 0;
    while (index < world.highWater()) : (index += 1) {
        const entity = world.entityAt(index) orelse continue;
        hashInt(&hash, entity.index);
        hashInt(&hash, entity.generation);
        if (world.getConst(Position, entity)) |position| {
            hashByte(&hash, 1);
            hashInt(&hash, position.x);
            hashInt(&hash, position.y);
        } else {
            hashByte(&hash, 0);
        }
        if (world.getConst(Velocity, entity)) |velocity| {
            hashByte(&hash, 1);
            hashInt(&hash, velocity.x);
            hashInt(&hash, velocity.y);
        } else {
            hashByte(&hash, 0);
        }
        if (world.getConst(Age, entity)) |age| {
            hashByte(&hash, 1);
            hashInt(&hash, age.ticks);
        } else {
            hashByte(&hash, 0);
        }
    }

    // Preserve the published smoke/flat checksum byte-for-byte. Hierarchical
    // scenes get a domain-separated suffix that includes both reciprocal links
    // and the exposed child order; this pass is allocation-free and runs only
    // when reporting final state, never in the tick path.
    if (world.componentCount(scene.hierarchy.Parent) != 0 or world.componentCount(scene.hierarchy.Children) != 0) {
        hashBytes(&hash, "corex.hierarchy.v1\x00");
        index = 0;
        while (index < world.highWater()) : (index += 1) {
            const entity = world.entityAt(index) orelse continue;
            hashInt(&hash, entity.index);
            hashInt(&hash, entity.generation);
            if (world.getConst(scene.hierarchy.Parent, entity)) |parent| {
                hashByte(&hash, 1);
                hashInt(&hash, parent.entity.index);
                hashInt(&hash, parent.entity.generation);
            } else {
                hashByte(&hash, 0);
            }
            if (world.getConst(scene.hierarchy.Children, entity)) |children| {
                hashByte(&hash, 1);
                hashInt(&hash, @as(u64, @intCast(children.entities.len)));
                for (children.entities) |child| {
                    hashInt(&hash, child.index);
                    hashInt(&hash, child.generation);
                }
            } else {
                hashByte(&hash, 0);
            }
        }
    }

    // A separate, optional suffix preserves all existing smoke, flat and
    // hierarchy-only checksums. Both authored and computed matrices are hashed
    // in index order. Dirty markers are normally empty after setup, but are
    // included if present so this helper still covers transient state.
    if (world.componentCount(scene.transform3d.LocalTransform3D) != 0 or
        world.componentCount(scene.transform3d.WorldTransform3D) != 0 or
        world.componentCount(scene.transform_dirty.TransformDirty) != 0)
    {
        hashBytes(&hash, "corex.transform3d.v1\x00");
        index = 0;
        while (index < world.highWater()) : (index += 1) {
            const entity = world.entityAt(index) orelse continue;
            hashInt(&hash, entity.index);
            hashInt(&hash, entity.generation);
            if (world.getConst(scene.transform3d.LocalTransform3D, entity)) |local| {
                hashByte(&hash, 1);
                hashMatrix(&hash, local.matrix);
            } else {
                hashByte(&hash, 0);
            }
            if (world.getConst(scene.transform3d.WorldTransform3D, entity)) |computed| {
                hashByte(&hash, 1);
                hashMatrix(&hash, computed.matrix);
            } else {
                hashByte(&hash, 0);
            }
            if (world.getConst(scene.transform_dirty.TransformDirty, entity)) |dirty| {
                hashByte(&hash, 1);
                hashByte(&hash, if (dirty.subtree_dirty) 1 else 0);
            } else {
                hashByte(&hash, 0);
            }
        }
    }

    // Do not change any published checksum when no velocity component exists.
    // This suffix also represents inactive/zero deltas as authored state.
    if (world.componentCount(TransformVelocity3D) != 0) {
        hashBytes(&hash, "corex.transform_velocity3d.v1\x00");
        index = 0;
        while (index < world.highWater()) : (index += 1) {
            const entity = world.entityAt(index) orelse continue;
            hashInt(&hash, entity.index);
            hashInt(&hash, entity.generation);
            if (world.getConst(TransformVelocity3D, entity)) |velocity| {
                hashByte(&hash, 1);
                hashInt(&hash, velocity.x);
                hashInt(&hash, velocity.y);
                hashInt(&hash, velocity.z);
            } else {
                hashByte(&hash, 0);
            }
        }
    }
    return hash;
}

fn hashMatrix(hash: *u64, matrix: scene.transform3d.Mat4) void {
    // Freeze the v1 checksum field order rather than implicitly extending it if
    // the matrix type ever gains metadata.
    inline for (.{ "m00", "m01", "m02", "m03", "m10", "m11", "m12", "m13", "m20", "m21", "m22", "m23" }) |name| {
        hashInt(hash, @field(matrix, name));
    }
}

fn moveSystem(world: *World, _: ?*anyopaque, _: core.subsystem.Step) anyerror!void {
    var index: u32 = 0;
    while (index < world.highWater()) : (index += 1) {
        const entity = world.entityAt(index) orelse continue;
        const position = world.get(Position, entity) orelse continue;
        const velocity = world.get(Velocity, entity) orelse continue;
        // Scene content is untrusted. Check both coordinates before changing
        // either one so an overflow does not trap or half-update this entity.
        const next_x = std.math.add(i64, position.x, velocity.x) catch return error.PositionOverflow;
        const next_y = std.math.add(i64, position.y, velocity.y) catch return error.PositionOverflow;
        position.x = next_x;
        position.y = next_y;
    }
}

fn ageSystem(world: *World, _: ?*anyopaque, _: core.subsystem.Step) anyerror!void {
    var index: u32 = 0;
    while (index < world.highWater()) : (index += 1) {
        const entity = world.entityAt(index) orelse continue;
        const age = world.get(Age, entity) orelse continue;
        age.ticks = std.math.add(u64, age.ticks, 1) catch return error.AgeOverflow;
    }
}

fn moveTransforms3D(world: *World, scratch: *scene.transform_dirty.PropagationScratch, _: core.subsystem.Step) anyerror!void {
    // Dense velocity order is deterministic for this fixed-entity scene. We
    // never mutate this store while iterating it. A velocity without a local
    // transform is inert, like the existing position/velocity pair.
    for (world.entities(TransformVelocity3D), world.sliceConst(TransformVelocity3D)) |entity, velocity| {
        if (velocity.x == 0 and velocity.y == 0 and velocity.z == 0) continue;
        const local = world.get(scene.transform3d.LocalTransform3D, entity) orelse continue;
        const x = std.math.add(i32, local.matrix.m03, velocity.x) catch return error.TransformOverflow;
        const y = std.math.add(i32, local.matrix.m13, velocity.y) catch return error.TransformOverflow;
        const z = std.math.add(i32, local.matrix.m23, velocity.z) catch return error.TransformOverflow;
        // Mark before mutation so a failed insertion never leaves an unmarked
        // change. All three coordinates are checked before either is written.
        try scene.transform_dirty.tryMarkDirty(World, world, entity);
        local.matrix.m03 = x;
        local.matrix.m13 = y;
        local.matrix.m23 = z;
    }
    // No marks is O(1); overlapping subtrees are coalesced by the shared
    // checked walker. On failure its root stays marked for diagnosis/retry.
    try scene.transform_dirty.tryPropagateDirtyWithImplicitIdentityUsingScratch(World, world, scratch);
}

fn hashByte(hash: *u64, value: u8) void {
    hash.* ^= value;
    hash.* *%= 0x100000001b3;
}

fn hashBytes(hash: *u64, bytes: []const u8) void {
    for (bytes) |byte| hashByte(hash, byte);
}

fn hashInt(hash: *u64, value: anytype) void {
    var copy = value;
    hashBytes(hash, std.mem.asBytes(&copy));
}

const testing = std.testing;

test "loaded hierarchy preserves links and sibling order without tick allocations" {
    var counter = scene.testing_allocator.CountingAllocator{ .backing = testing.allocator };
    const allocator = counter.allocator();
    var file = try scene.content_format.parse(allocator,
        \\{"entities":[{"parent_index":3,"sibling_index":1,"components":[{"kind":"position","x":1},{"kind":"velocity","x":1}]},{"parent_index":3,"sibling_index":0},{"parent_index":0,"components":[{"kind":"age","ticks":2}]},{}]}
    );
    defer scene.content_format.deinit(allocator, &file);
    var app = try init(allocator);
    defer app.deinit();
    defer scene.hierarchy.clear(World, allocator, app.world());
    var scratch = scene.transform_dirty.PropagationScratch.init(allocator);
    defer scratch.deinit();
    try installSystems(&app);
    try installDynamicTransforms(&app, &scratch);
    try app.start();
    defer app.stop();
    try scene.content_loader.load(Stores, app.world(), &file);

    const world = app.world();
    const first = world.entityAt(0).?;
    const second = world.entityAt(1).?;
    const grandchild = world.entityAt(2).?;
    const root = world.entityAt(3).?;
    try testing.expectEqual(root, scene.hierarchy.getParent(World, world, first).?);
    try testing.expectEqual(root, scene.hierarchy.getParent(World, world, second).?);
    try testing.expectEqual(first, scene.hierarchy.getParent(World, world, grandchild).?);
    const children = world.get(scene.hierarchy.Children, root).?.entities;
    try testing.expectEqualSlices(scene.Entity, &.{ second, first }, children);

    counter.resetCounters();
    try prepareTransforms(&app);
    try prepareDynamicTransforms(&app, &scratch);
    for (0..100) |index| try app.update(.{ .index = index, .dt_ns = 1 });
    try testing.expectEqual(@as(i64, 101), world.getConst(Position, first).?.x);
    try testing.expectEqual(@as(u64, 102), world.getConst(Age, grandchild).?.ticks);
    const original = stateChecksum(&app);
    std.mem.swap(scene.Entity, &children[0], &children[1]);
    try testing.expect(original != stateChecksum(&app));
    std.mem.swap(scene.Entity, &children[0], &children[1]);
    try testing.expectEqual(original, stateChecksum(&app));
    try testing.expectEqual(@as(usize, 0), counter.allocations);
}

test "movement overflow returns an error without half-updating an entity" {
    var world = try World.init(testing.allocator, 4);
    defer world.deinit();
    const entity = try world.create();
    try world.add(Position, entity, .{ .x = std.math.maxInt(i64) - 1, .y = std.math.maxInt(i64) });
    try world.add(Velocity, entity, .{ .x = 1, .y = 1 });
    const step: core.subsystem.Step = .{ .index = 0, .dt_ns = 1 };
    try testing.expectError(error.PositionOverflow, moveSystem(&world, null, step));
    try testing.expectEqual(@as(i64, std.math.maxInt(i64) - 1), world.getConst(Position, entity).?.x);
    try testing.expectEqual(@as(i64, std.math.maxInt(i64)), world.getConst(Position, entity).?.y);
    world.get(Position, entity).?.y = std.math.maxInt(i64) - 1;
    try moveSystem(&world, null, step);
    try testing.expectEqual(@as(i64, std.math.maxInt(i64)), world.getConst(Position, entity).?.x);
    try testing.expectEqual(@as(i64, std.math.maxInt(i64)), world.getConst(Position, entity).?.y);
    world.get(Position, entity).?.x = std.math.minInt(i64);
    world.get(Velocity, entity).?.x = -1;
    try testing.expectError(error.PositionOverflow, moveSystem(&world, null, step));
    try testing.expectEqual(@as(i64, std.math.minInt(i64)), world.getConst(Position, entity).?.x);
}

test "age overflow returns an error and preserves the counter" {
    var world = try World.init(testing.allocator, 4);
    defer world.deinit();
    const entity = try world.create();
    try world.add(Age, entity, .{ .ticks = std.math.maxInt(u64) - 1 });
    const step: core.subsystem.Step = .{ .index = 0, .dt_ns = 1 };
    try ageSystem(&world, null, step);
    try testing.expectEqual(@as(u64, std.math.maxInt(u64)), world.getConst(Age, entity).?.ticks);
    try testing.expectError(error.AgeOverflow, ageSystem(&world, null, step));
    try testing.expectEqual(@as(u64, std.math.maxInt(u64)), world.getConst(Age, entity).?.ticks);
}

test "hierarchy file ordinals remap to reused generational handles" {
    var file = try scene.content_format.parse(testing.allocator,
        \\{"entities":[{"parent_index":2,"sibling_index":1},{"parent_index":2,"sibling_index":0},{}]}
    );
    defer scene.content_format.deinit(testing.allocator, &file);
    var app = try init(testing.allocator);
    defer app.deinit();
    defer scene.hierarchy.clear(World, testing.allocator, app.world());
    const world = app.world();
    const stale_root = try world.create();
    const stale_second = try world.create();
    const stale_first = try world.create();
    const existing = try world.create();
    try world.destroy(stale_root);
    try world.destroy(stale_second);
    try world.destroy(stale_first);

    try scene.content_loader.load(Stores, world, &file);
    const first = world.entityAt(stale_first.index).?;
    const second = world.entityAt(stale_second.index).?;
    const root = world.entityAt(stale_root.index).?;
    try testing.expect(root.generation != stale_root.generation);
    try testing.expectEqual(existing, world.entityAt(existing.index).?);
    try testing.expectEqual(root, scene.hierarchy.getParent(World, world, first).?);
    try testing.expectEqual(root, scene.hierarchy.getParent(World, world, second).?);
    try testing.expectEqualSlices(scene.Entity, &.{ second, first }, scene.hierarchy.getChildren(World, world, root));

    // Verify that generations inside the hierarchy, not just entity indices,
    // contribute to the extension. Restore each link before teardown.
    const original = stateChecksum(&app);
    const parent = world.get(scene.hierarchy.Parent, first).?;
    parent.entity.generation -%= 1;
    try testing.expect(original != stateChecksum(&app));
    parent.entity.generation +%= 1;
    const children = world.get(scene.hierarchy.Children, root).?.entities;
    children[0].generation -%= 1;
    try testing.expect(original != stateChecksum(&app));
    children[0].generation +%= 1;
    try testing.expectEqual(original, stateChecksum(&app));
}

test "3D scene computes parent-first through identity gaps without tick allocations" {
    var counter = scene.testing_allocator.CountingAllocator{ .backing = testing.allocator };
    const allocator = counter.allocator();
    var file = try scene.content_format.parse(allocator,
        \\{"entities":[{"parent_index":1,"components":[{"kind":"local_transform3d","m03":131072}]},{"parent_index":3},{"components":[{"kind":"position","x":4}]},{"components":[{"kind":"local_transform3d","m00":0,"m01":-65536,"m10":65536,"m11":0,"m03":65536}]}]}
    );
    defer scene.content_format.deinit(allocator, &file);
    var app = try init(allocator);
    defer app.deinit();
    defer scene.hierarchy.clear(World, allocator, app.world());
    try installSystems(&app);
    try app.start();
    defer app.stop();
    try validateContent(&file);
    try scene.content_loader.load(Stores, app.world(), &file);
    try prepareTransforms(&app);
    const world = app.world();
    const leaf = world.entityAt(0).?;
    const middle = world.entityAt(1).?;
    const unrelated = world.entityAt(2).?;
    const root = world.entityAt(3).?;
    try testing.expectEqual(@as(usize, 0), world.componentCount(scene.transform_dirty.TransformDirty));
    try testing.expect(!world.has(scene.transform3d.WorldTransform3D, unrelated));
    try testing.expectEqualDeep(world.getConst(scene.transform3d.WorldTransform3D, root).?.matrix, world.getConst(scene.transform3d.WorldTransform3D, middle).?.matrix);
    const leaf_world = world.getConst(scene.transform3d.WorldTransform3D, leaf).?.matrix;
    try testing.expectEqual(@as(i32, 65536), leaf_world.m03);
    try testing.expectEqual(@as(i32, 131072), leaf_world.m13);

    counter.resetCounters();
    const initial = stateChecksum(&app);
    for (0..100) |index| try app.update(.{ .index = index, .dt_ns = 1 });
    try testing.expectEqual(initial, stateChecksum(&app));
    try testing.expectEqual(@as(usize, 0), counter.allocations);

    const local = world.get(scene.transform3d.LocalTransform3D, leaf).?;
    local.matrix.m03 += 1;
    try testing.expect(initial != stateChecksum(&app));
    local.matrix.m03 -= 1;
    const computed = world.get(scene.transform3d.WorldTransform3D, leaf).?;
    computed.matrix.m03 += 1;
    try testing.expect(initial != stateChecksum(&app));
    computed.matrix.m03 -= 1;
    try scene.transform_dirty.tryMarkDirty(World, world, leaf);
    try testing.expect(initial != stateChecksum(&app));
    _ = try world.remove(scene.transform_dirty.TransformDirty, leaf);
    try testing.expectEqual(initial, stateChecksum(&app));
}

test "dynamic 3D transforms propagate parent first without allocations per tick" {
    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    var counter = scene.testing_allocator.CountingAllocator{ .backing = failing.allocator() };
    const allocator = counter.allocator();
    var file = try scene.content_format.parse(allocator,
        \\{"entities":[{"parent_index":1,"components":[{"kind":"local_transform3d","m03":131072},{"kind":"transform_velocity3d","x":65536,"y":-32768}]},{"parent_index":3},{"parent_index":3,"components":[{"kind":"local_transform3d","m13":196608}]},{"components":[{"kind":"local_transform3d","m00":0,"m01":-65536,"m10":65536,"m11":0,"m03":65536},{"kind":"transform_velocity3d","x":32768,"y":65536}]},{"components":[{"kind":"transform_velocity3d","x":17}]},{"components":[{"kind":"local_transform3d","m23":-65536},{"kind":"transform_velocity3d"}]}]}
    );
    defer scene.content_format.deinit(allocator, &file);
    var app = try init(allocator);
    defer app.deinit();
    defer scene.hierarchy.clear(World, allocator, app.world());
    var scratch = scene.transform_dirty.PropagationScratch.init(allocator);
    defer scratch.deinit();
    try installSystems(&app);
    try installDynamicTransforms(&app, &scratch);
    try app.start();
    defer app.stop();
    try validateContent(&file);
    try scene.content_loader.load(Stores, app.world(), &file);
    try prepareTransforms(&app);
    try prepareDynamicTransforms(&app, &scratch);
    const world = app.world();
    const leaf = world.entityAt(0).?;
    const middle = world.entityAt(1).?;
    const sibling = world.entityAt(2).?;
    const root = world.entityAt(3).?;
    const orphan = world.entityAt(4).?;
    const stationary = world.entityAt(5).?;
    const stationary_matrix = world.getConst(scene.transform3d.WorldTransform3D, stationary).?.matrix;

    // Reject allocations and resizes, in addition to counting allocations, so
    // the entire update path is proven not to grow retained buffers.
    failing.fail_index = failing.alloc_index;
    failing.resize_fail_index = failing.resize_index;
    counter.resetCounters();
    for (0..100) |index| try app.update(.{ .index = index, .dt_ns = 1 });
    try testing.expectEqual(@as(usize, 0), counter.allocations);
    try testing.expectEqual(@as(usize, 0), counter.allocation_attempts);
    try testing.expectEqual(@as(usize, 0), counter.resize_attempts);
    try testing.expectEqual(@as(usize, 0), counter.remap_attempts);
    try testing.expectEqual(@as(usize, 0), world.componentCount(scene.transform_dirty.TransformDirty));
    try testing.expect(!world.has(scene.transform3d.LocalTransform3D, orphan));
    try testing.expect(!world.has(scene.transform3d.WorldTransform3D, orphan));
    try testing.expectEqualDeep(stationary_matrix, world.getConst(scene.transform3d.WorldTransform3D, stationary).?.matrix);
    try testing.expectEqualDeep(world.getConst(scene.transform3d.WorldTransform3D, root).?.matrix, world.getConst(scene.transform3d.WorldTransform3D, middle).?.matrix);
    const leaf_world = world.getConst(scene.transform3d.WorldTransform3D, leaf).?.matrix;
    try testing.expectEqual(@as(i32, 65536 + 100 * 65536), leaf_world.m03);
    try testing.expectEqual(@as(i32, 131072 + 100 * 131072), leaf_world.m13);
    const sibling_world = world.getConst(scene.transform3d.WorldTransform3D, sibling).?.matrix;
    try testing.expectEqual(@as(i32, 65536 + 100 * 32768 - 196608), sibling_world.m03);
    try testing.expectEqual(@as(i32, 100 * 65536), sibling_world.m13);

    const checksum = stateChecksum(&app);
    world.get(TransformVelocity3D, orphan).?.x += 1;
    try testing.expect(checksum != stateChecksum(&app));
    world.get(TransformVelocity3D, orphan).?.x -= 1;
    try testing.expectEqual(checksum, stateChecksum(&app));
}

test "3D motion checks all coordinates before mutating or marking" {
    var world = try World.init(testing.allocator, 4);
    defer world.deinit();
    var scratch = scene.transform_dirty.PropagationScratch.init(testing.allocator);
    defer scratch.deinit();
    const entity = try world.create();
    try world.add(scene.transform3d.LocalTransform3D, entity, .{ .matrix = .translation(std.math.maxInt(i32) - 1, std.math.maxInt(i32), 0) });
    try world.add(TransformVelocity3D, entity, .{ .x = 1, .y = 1 });
    const step: core.subsystem.Step = .{ .index = 0, .dt_ns = 1 };
    try testing.expectError(error.TransformOverflow, moveTransforms3D(&world, &scratch, step));
    const local = world.get(scene.transform3d.LocalTransform3D, entity).?;
    try testing.expectEqual(std.math.maxInt(i32) - 1, local.matrix.m03);
    try testing.expectEqual(std.math.maxInt(i32), local.matrix.m13);
    try testing.expect(!world.has(scene.transform_dirty.TransformDirty, entity));
    local.matrix = .translation(std.math.minInt(i32), 0, 0);
    world.get(TransformVelocity3D, entity).?.* = .{ .x = -1 };
    try testing.expectError(error.TransformOverflow, moveTransforms3D(&world, &scratch, step));
    try testing.expectEqual(std.math.minInt(i32), local.matrix.m03);
    try testing.expect(!world.has(scene.transform_dirty.TransformDirty, entity));
    local.matrix = .translation(0, 0, std.math.maxInt(i32));
    world.get(TransformVelocity3D, entity).?.* = .{ .z = 1 };
    try testing.expectError(error.TransformOverflow, moveTransforms3D(&world, &scratch, step));
    try testing.expectEqual(std.math.maxInt(i32), local.matrix.m23);
}

test "failed dirty allocation does not leave an unmarked 3D mutation" {
    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    const allocator = failing.allocator();
    var world = try World.init(allocator, 4);
    defer world.deinit();
    var scratch = scene.transform_dirty.PropagationScratch.init(allocator);
    defer scratch.deinit();
    const entity = try world.create();
    try world.add(scene.transform3d.LocalTransform3D, entity, .{ .matrix = .translation(10, 20, 30) });
    try world.add(TransformVelocity3D, entity, .{ .x = 1, .y = 2, .z = 3 });
    const step: core.subsystem.Step = .{ .index = 0, .dt_ns = 1 };
    failing.fail_index = failing.alloc_index;
    try testing.expectError(error.OutOfMemory, moveTransforms3D(&world, &scratch, step));
    try testing.expectEqualDeep(scene.transform3d.Mat4.translation(10, 20, 30), world.getConst(scene.transform3d.LocalTransform3D, entity).?.matrix);
    try testing.expect(!world.has(scene.transform_dirty.TransformDirty, entity));
    failing.fail_index = std.math.maxInt(usize);
    try moveTransforms3D(&world, &scratch, step);
    try testing.expectEqualDeep(scene.transform3d.Mat4.translation(11, 22, 33), world.getConst(scene.transform3d.WorldTransform3D, entity).?.matrix);
}

test "dynamic world composition overflow keeps a retryable root marker" {
    var app = try init(testing.allocator);
    defer app.deinit();
    defer scene.hierarchy.clear(World, testing.allocator, app.world());
    var scratch = scene.transform_dirty.PropagationScratch.init(testing.allocator);
    defer scratch.deinit();
    try installSystems(&app);
    try installDynamicTransforms(&app, &scratch);
    try app.start();
    defer app.stop();
    const world = app.world();
    const root = try world.create();
    const child = try world.create();
    try world.add(scene.transform3d.LocalTransform3D, root, .{ .matrix = .translation(std.math.maxInt(i32) - 2, 0, 0) });
    try world.add(TransformVelocity3D, root, .{ .x = 2 });
    try world.add(scene.transform3d.LocalTransform3D, child, .{ .matrix = .translation(1, 0, 0) });
    try scene.hierarchy.setParent(World, testing.allocator, world, root, child);
    try prepareTransforms(&app);
    try prepareDynamicTransforms(&app, &scratch);
    try testing.expectError(error.TransformOverflow, app.update(.{ .index = 0, .dt_ns = 1 }));
    try testing.expect(world.has(scene.transform_dirty.TransformDirty, root));
    try testing.expectEqual(std.math.maxInt(i32), world.getConst(scene.transform3d.LocalTransform3D, root).?.matrix.m03);
    try testing.expectEqual(std.math.maxInt(i32) - 1, world.getConst(scene.transform3d.WorldTransform3D, child).?.matrix.m03);
}

test "zero or unmatched 3D velocities require no scratch allocation" {
    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    var counter = scene.testing_allocator.CountingAllocator{ .backing = failing.allocator() };
    const allocator = counter.allocator();
    var app = try init(allocator);
    defer app.deinit();
    defer scene.hierarchy.clear(World, allocator, app.world());
    var scratch = scene.transform_dirty.PropagationScratch.init(allocator);
    defer scratch.deinit();
    try installSystems(&app);
    try installDynamicTransforms(&app, &scratch);
    try app.start();
    defer app.stop();
    const world = app.world();
    const stationary = try world.create();
    const unmatched = try world.create();
    try world.add(scene.transform3d.LocalTransform3D, stationary, .{ .matrix = .translation(7, 0, 0) });
    try world.add(TransformVelocity3D, stationary, .{});
    try world.add(TransformVelocity3D, unmatched, .{ .x = 1 });
    try prepareTransforms(&app);
    counter.resetCounters();
    failing.fail_index = failing.alloc_index;
    failing.resize_fail_index = failing.resize_index;
    try prepareDynamicTransforms(&app, &scratch);
    for (0..100) |index| try app.update(.{ .index = index, .dt_ns = 1 });
    try testing.expectEqual(@as(usize, 0), counter.allocation_attempts);
    try testing.expectEqual(@as(usize, 0), counter.resize_attempts);
    try testing.expectEqual(@as(usize, 0), counter.remap_attempts);
    try testing.expectEqual(@as(i32, 7), world.getConst(scene.transform3d.WorldTransform3D, stationary).?.matrix.m03);
    try testing.expect(!world.has(scene.transform3d.WorldTransform3D, unmatched));
    try testing.expectEqual(@as(usize, 0), scratch.stack.capacity);
}

test "wide and deep dynamic hierarchies update with allocation forbidden" {
    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    var counter = scene.testing_allocator.CountingAllocator{ .backing = failing.allocator() };
    const allocator = counter.allocator();
    var app = try init(allocator);
    defer app.deinit();
    defer scene.hierarchy.clear(World, allocator, app.world());
    var scratch = scene.transform_dirty.PropagationScratch.init(allocator);
    defer scratch.deinit();
    try installSystems(&app);
    try installDynamicTransforms(&app, &scratch);
    try app.start();
    defer app.stop();
    const world = app.world();
    const root = try world.create();
    try world.add(scene.transform3d.LocalTransform3D, root, .{});
    try world.add(TransformVelocity3D, root, .{ .x = 3 });
    var branch: scene.Entity = undefined;
    for (0..128) |index| {
        const child = try world.create();
        try scene.hierarchy.setParent(World, allocator, world, root, child);
        if (index == 0) branch = child;
    }
    for (0..128) |_| {
        const child = try world.create();
        try scene.hierarchy.setParent(World, allocator, world, branch, child);
        branch = child;
    }
    try world.add(scene.transform3d.LocalTransform3D, branch, .{});
    try world.add(TransformVelocity3D, branch, .{ .y = -2 });
    try prepareTransforms(&app);
    try prepareDynamicTransforms(&app, &scratch);
    counter.resetCounters();
    failing.fail_index = failing.alloc_index;
    failing.resize_fail_index = failing.resize_index;
    for (0..10) |index| try app.update(.{ .index = index, .dt_ns = 1 });
    try testing.expectEqual(@as(usize, 0), counter.allocation_attempts);
    try testing.expectEqual(@as(usize, 0), counter.resize_attempts);
    try testing.expectEqual(@as(usize, 0), counter.remap_attempts);
    const leaf_world = world.getConst(scene.transform3d.WorldTransform3D, branch).?.matrix;
    try testing.expectEqual(@as(i32, 30), leaf_world.m03);
    try testing.expectEqual(@as(i32, -20), leaf_world.m13);
    try testing.expectEqual(@as(usize, 0), world.componentCount(scene.transform_dirty.TransformDirty));
}
