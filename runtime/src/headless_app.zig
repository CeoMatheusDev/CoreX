//! Declared smoke scene for the headless executor.
//!
//! This is deliberately not gameplay: it is a tiny deterministic scene used to
//! prove that the Runtime drives real entities, components and systems through
//! the Core lifecycle. It has no assets, scripts, input, window or GPU. The
//! checksum covers entity handles and component values in index order; when
//! hierarchy is present it additionally covers parent links and sibling order.
const std = @import("std");
const core = @import("corex_core");
const scene = @import("corex_scene");

pub const Position = struct { x: i64, y: i64 };
pub const Velocity = struct { x: i64, y: i64 };
pub const Age = struct { ticks: u64 };

pub const Stores = struct {
    position: scene.SparseSet(Position),
    velocity: scene.SparseSet(Velocity),
    age: scene.SparseSet(Age),
    parent: scene.SparseSet(scene.hierarchy.Parent),
    children: scene.SparseSet(scene.hierarchy.Children),
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
    return hash;
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
    try installSystems(&app);
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
