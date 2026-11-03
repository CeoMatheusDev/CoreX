//! Content-scene serializer: writes a `World(StoresT)` state back to the
//! content-format JSON descriptor. This is the inverse of `content_loader`:
//! round-tripping load → serialize must produce an equivalent scene.
//!
//! Determinism: entities are emitted in ascending index order (the World's
//! `highWater`/`entityAt` contract), components in store declaration order.
//! The output is stable for a given World state — no hash-map iteration.
const std = @import("std");
const world_mod = @import("ecs/world.zig");
const format = @import("content_format.zig");
const hierarchy = @import("ecs/hierarchy.zig");
const transform3d = @import("ecs/transform3d.zig");
const transform_dirty = @import("ecs/transform_dirty.zig");

pub const SerializeError = error{
    OutOfMemory,
    InvalidSceneData,
    InvalidHierarchy,
    HierarchyUnsupported,
    UnsupportedComponentType,
    InvalidUtf8,
} || std.Io.Writer.Error;

/// Serializes the world into a caller-owned JSON slice. Hierarchy references
/// are file positions, not generational entity handles. Invalid or inconsistent
/// hierarchy state is rejected rather than silently producing a broken file.
pub fn serialize(comptime StoresT: type, allocator: std.mem.Allocator, world: *const world_mod.World(StoresT), system_capacity: u32) ![]u8 {
    return serializeImpl(StoresT, allocator, world, system_capacity, false);
}

/// Serialize authored state while omitting computed WorldTransform3D and
/// transient TransformDirty components. The consumer must recompute these;
/// every other unsupported component still fails rather than being discarded.
pub fn serializeAuthored(comptime StoresT: type, allocator: std.mem.Allocator, world: *const world_mod.World(StoresT), system_capacity: u32) ![]u8 {
    return serializeImpl(StoresT, allocator, world, system_capacity, true);
}

fn serializeImpl(comptime StoresT: type, allocator: std.mem.Allocator, world: *const world_mod.World(StoresT), system_capacity: u32, comptime authored: bool) ![]u8 {
    if (world.entityCapacity() == 0 or world.entityCapacity() > format.max_entities) return error.InvalidSceneData;
    const links = try collectParents(StoresT, allocator, world);
    defer if (links) |refs| {
        allocator.free(refs.parents);
        allocator.free(refs.siblings);
    };

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    writeWorld(StoresT, &aw.writer, world, system_capacity, links, authored) catch |err| switch (err) {
        // Allocating.Writer's only write failure is an allocation failure.
        error.WriteFailed => return error.OutOfMemory,
        else => return err,
    };
    return aw.toOwnedSlice();
}

const HierarchyRefs = struct { parents: []?u32, siblings: []u32 };

/// Translate sparse live handles to dense file ordinals and validate that the
/// bidirectional hierarchy is consistent. Complexity is O(highWater + edges).
fn collectParents(comptime StoresT: type, allocator: std.mem.Allocator, world: *const world_mod.World(StoresT)) !?HierarchyRefs {
    const has_parent = comptime hierarchy.hasStore(StoresT, hierarchy.Parent);
    const has_children = comptime hierarchy.hasStore(StoresT, hierarchy.Children);
    if (comptime !has_parent or !has_children) {
        if (comptime has_parent) {
            if (world.componentCount(hierarchy.Parent) != 0) return error.HierarchyUnsupported;
        }
        if (comptime has_children) {
            if (world.componentCount(hierarchy.Children) != 0) return error.HierarchyUnsupported;
        }
        return null;
    } else {
        if (world.componentCount(hierarchy.Parent) == 0 and world.componentCount(hierarchy.Children) == 0) return null;

        const no_ordinal = std.math.maxInt(u32);
        const ordinals = try allocator.alloc(u32, world.highWater());
        defer allocator.free(ordinals);
        @memset(ordinals, no_ordinal);
        var ordinal: u32 = 0;
        for (ordinals, 0..) |*slot, index| {
            if (world.entityAt(@intCast(index)) != null) {
                slot.* = ordinal;
                ordinal += 1;
            }
        }
        const parents = try allocator.alloc(?u32, ordinal);
        errdefer allocator.free(parents);
        @memset(parents, null);
        for (ordinals, 0..) |file_index, index| {
            if (file_index == no_ordinal) continue;
            const entity = world.entityAt(@intCast(index)).?;
            if (world.getConst(hierarchy.Parent, entity)) |parent| {
                if (!world.isAlive(parent.entity)) return error.InvalidHierarchy;
                parents[file_index] = ordinals[parent.entity.index];
            }
        }
        hierarchy.validateParentIndices(allocator, parents) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidHierarchy,
        };

        const siblings = try allocator.alloc(u32, parents.len);
        errdefer allocator.free(siblings);
        @memset(siblings, no_ordinal);
        for (ordinals, 0..) |owner_ordinal, index| {
            if (owner_ordinal == no_ordinal) continue;
            const owner = world.entityAt(@intCast(index)).?;
            const children = world.getConst(hierarchy.Children, owner) orelse continue;
            for (children.entities, 0..) |child, sibling_index| {
                if (!world.isAlive(child)) return error.InvalidHierarchy;
                const child_ordinal = ordinals[child.index];
                if (siblings[child_ordinal] != no_ordinal or parents[child_ordinal] == null or parents[child_ordinal].? != owner_ordinal) return error.InvalidHierarchy;
                siblings[child_ordinal] = @intCast(sibling_index);
            }
        }
        for (parents, 0..) |parent, i| {
            if (parent != null and siblings[i] == no_ordinal) return error.InvalidHierarchy;
        }
        return .{ .parents = parents, .siblings = siblings };
    }
}

fn writeWorld(comptime StoresT: type, w: *std.Io.Writer, world: *const world_mod.World(StoresT), system_capacity: u32, links: ?HierarchyRefs, comptime authored: bool) SerializeError!void {
    try w.writeAll("{\"entity_capacity\": ");
    try w.print("{d}", .{world.entityCapacity()});
    try w.print(", \"system_capacity\": {d}, \"entities\": [", .{system_capacity});

    var first_entity = true;
    var index: u32 = 0;
    var file_index: usize = 0;
    while (index < world.highWater()) : (index += 1) {
        const entity = world.entityAt(index) orelse continue;
        if (!first_entity) try w.writeAll(", ");
        first_entity = false;
        try w.writeAll("{");
        if (links) |refs| {
            if (refs.parents[file_index]) |parent| {
                try w.print("\"parent_index\": {d}, \"sibling_index\": {d}, ", .{ parent, refs.siblings[file_index] });
            }
        }
        try w.writeAll("\"components\": [");
        try writeComponents(StoresT, w, world, entity, authored);
        try w.writeAll("]}");
        file_index += 1;
    }
    try w.writeAll("]}");
}

fn writeComponents(comptime StoresT: type, w: *std.Io.Writer, world: *const world_mod.World(StoresT), entity: anytype, comptime authored: bool) !void {
    const stores_info = @typeInfo(StoresT).@"struct";
    var first = true;
    inline for (stores_info.field_names, stores_info.field_types) |store_name, FieldType| {
        const Component = FieldType.Component;
        if (comptime Component != hierarchy.Parent and Component != hierarchy.Children and
            (!authored or (Component != transform3d.WorldTransform3D and Component != transform_dirty.TransformDirty)))
        {
            if (world.getConst(Component, entity)) |value| {
                if (comptime Component != transform3d.LocalTransform3D and !format.supportsComponent(Component)) {
                    return error.UnsupportedComponentType;
                } else {
                    if (!first) try w.writeAll(", ");
                    first = false;
                    try w.writeAll("{\"kind\": ");
                    if (!std.unicode.utf8ValidateSlice(store_name)) return error.InvalidUtf8;
                    try std.json.Stringify.value(@as([]const u8, store_name), .{}, w);
                    if (comptime Component == transform3d.LocalTransform3D) {
                        try writeFields(w, &value.matrix);
                    } else {
                        try writeFields(w, value);
                    }
                    try w.writeAll("}");
                }
            }
        }
    }
}

fn writeFields(w: *std.Io.Writer, value: anytype) !void {
    const info = @typeInfo(@TypeOf(value.*)).@"struct";
    inline for (info.field_names, info.field_types) |fname, Field| {
        try w.writeAll(", ");
        if (!std.unicode.utf8ValidateSlice(fname)) return error.InvalidUtf8;
        try std.json.Stringify.value(@as([]const u8, fname), .{}, w);
        try w.writeAll(": ");
        try writeValue(w, Field, @field(value, fname));
    }
}

fn writeValue(w: *std.Io.Writer, comptime T: type, value: T) !void {
    if (T == []const u8) {
        if (!std.unicode.utf8ValidateSlice(value)) return error.InvalidUtf8;
        try std.json.Stringify.value(value, .{}, w);
    } else if (T == bool) {
        try w.writeAll(if (value) "true" else "false");
    } else {
        // All remaining supported fields are integers of at most 64 bits.
        try w.print("{d}", .{value});
    }
}

const testing = std.testing;
const sparse_set = @import("ecs/sparse_set.zig");

const Position = struct { x: i64, y: i64 };
const Velocity = struct { x: i64, y: i64 };
const Age = struct { ticks: u64 };

const TestStores = struct {
    position: sparse_set.SparseSet(Position),
    velocity: sparse_set.SparseSet(Velocity),
    age: sparse_set.SparseSet(Age),
};

const TestWorld = world_mod.World(TestStores);

test "serialize produces valid JSON that round-trips through the loader" {
    var world = try TestWorld.init(testing.allocator, 8);
    defer world.deinit();

    const e0 = try world.create();
    try world.add(Position, e0, .{ .x = 10, .y = 20 });
    try world.add(Velocity, e0, .{ .x = 1, .y = -1 });
    try world.add(Age, e0, .{ .ticks = 5 });

    const e1 = try world.create();
    try world.add(Position, e1, .{ .x = -5, .y = 0 });

    const json = try serialize(TestStores, testing.allocator, &world, 4);
    defer testing.allocator.free(json);

    // Parse it back and verify.
    var file = try format.parse(testing.allocator, json);
    defer format.deinit(testing.allocator, &file);
    try testing.expectEqual(@as(usize, 2), file.entities.len);

    var world2 = try TestWorld.init(testing.allocator, 8);
    defer world2.deinit();
    const loader = @import("content_loader.zig");
    try loader.load(TestStores, &world2, &file);
    try testing.expectEqual(@as(u32, 2), world2.aliveCount());

    const r0 = world2.entityAt(0).?;
    try testing.expectEqual(@as(i64, 10), world2.getConst(Position, r0).?.x);
    try testing.expectEqual(@as(i64, -1), world2.getConst(Velocity, r0).?.y);
    try testing.expectEqual(@as(u64, 5), world2.getConst(Age, r0).?.ticks);
}

test "serialize empty world produces valid empty entities array" {
    var world = try TestWorld.init(testing.allocator, 4);
    defer world.deinit();
    const json = try serialize(TestStores, testing.allocator, &world, 2);
    defer testing.allocator.free(json);
    try testing.expect(std.mem.indexOf(u8, json, "\"entities\": []") != null);
}

test "serialization is deterministic for the same world state" {
    var world = try TestWorld.init(testing.allocator, 8);
    defer world.deinit();
    const e = try world.create();
    try world.add(Position, e, .{ .x = 1, .y = 2 });
    const a = try serialize(TestStores, testing.allocator, &world, 4);
    defer testing.allocator.free(a);
    const b = try serialize(TestStores, testing.allocator, &world, 4);
    defer testing.allocator.free(b);
    try testing.expectEqualStrings(a, b);
}

const HierarchyStores = struct {
    position: sparse_set.SparseSet(Position),
    links_up: sparse_set.SparseSet(hierarchy.Parent),
    links_down: sparse_set.SparseSet(hierarchy.Children),
};
const HierarchyWorld = world_mod.World(HierarchyStores);

test "hierarchy round-trips holes, recycled handles, forward parents and sibling order" {
    var world = try HierarchyWorld.init(testing.allocator, 8);
    defer world.deinit();
    defer hierarchy.clear(HierarchyWorld, testing.allocator, &world);
    const child = try world.create(); // slot 0
    const hole = try world.create(); // slot 1
    const old_parent = try world.create(); // slot 2
    const grandchild = try world.create(); // slot 3
    const sibling = try world.create(); // slot 4
    try world.destroy(hole);
    try world.destroy(old_parent);
    const parent = try world.create(); // slot 2, new generation; slot 1 stays dead
    try testing.expectEqual(old_parent.index, parent.index);
    try testing.expect(parent.generation != old_parent.generation);
    try world.add(Position, child, .{ .x = 10, .y = 1 });
    try world.add(Position, parent, .{ .x = 20, .y = 2 });
    try world.add(Position, grandchild, .{ .x = 30, .y = 3 });
    try world.add(Position, sibling, .{ .x = 40, .y = 4 });
    // Append in the opposite order to file order; it must survive the round-trip.
    try hierarchy.setParent(HierarchyWorld, testing.allocator, &world, parent, sibling);
    try hierarchy.setParent(HierarchyWorld, testing.allocator, &world, parent, child);
    try hierarchy.setParent(HierarchyWorld, testing.allocator, &world, child, grandchild);

    const json = try serialize(HierarchyStores, testing.allocator, &world, 3);
    defer testing.allocator.free(json);
    const same_json = try serialize(HierarchyStores, testing.allocator, &world, 3);
    defer testing.allocator.free(same_json);
    try testing.expectEqualStrings(json, same_json);
    var file = try format.parse(testing.allocator, json);
    defer format.deinit(testing.allocator, &file);
    try testing.expectEqual(@as(usize, 4), file.entities.len);
    try testing.expectEqual(@as(?u32, 1), file.entities[0].parent_index);
    try testing.expectEqual(@as(?u32, 1), file.entities[0].sibling_index);
    try testing.expectEqual(@as(?u32, null), file.entities[1].parent_index);
    try testing.expectEqual(@as(?u32, 0), file.entities[2].parent_index);
    try testing.expectEqual(@as(?u32, 0), file.entities[3].sibling_index);
    for (file.entities) |entity| try testing.expectEqual(@as(usize, 1), entity.components.len);

    // Load into a nonempty World whose free-list returns a reused slot first.
    var loaded = try HierarchyWorld.init(testing.allocator, 8);
    defer loaded.deinit();
    defer hierarchy.clear(HierarchyWorld, testing.allocator, &loaded);
    const existing = try loaded.create();
    try loaded.add(Position, existing, .{ .x = 999, .y = 0 });
    const freed = try loaded.create();
    try loaded.destroy(freed);
    try @import("content_loader.zig").load(HierarchyStores, &loaded, &file);
    try testing.expectEqual(@as(u32, 5), loaded.aliveCount());
    try testing.expectEqual(@as(i64, 999), loaded.getConst(Position, existing).?.x);
    const loaded_child = loaded.entityAt(1).?;
    const loaded_parent = loaded.entityAt(2).?;
    const loaded_grandchild = loaded.entityAt(3).?;
    const loaded_sibling = loaded.entityAt(4).?;
    try testing.expect(loaded_child.generation != freed.generation);
    try testing.expectEqual(loaded_parent, hierarchy.getParent(HierarchyWorld, &loaded, loaded_child).?);
    try testing.expectEqual(loaded_child, hierarchy.getParent(HierarchyWorld, &loaded, loaded_grandchild).?);
    const children = hierarchy.getChildren(HierarchyWorld, &loaded, loaded_parent);
    try testing.expectEqual(loaded_sibling, children[0]);
    try testing.expectEqual(loaded_child, children[1]);
    try testing.expectEqual(@as(i64, 40), loaded.getConst(Position, loaded_sibling).?.x);
}

test "serializer refuses stale parents, cycles and inconsistent children" {
    var world = try HierarchyWorld.init(testing.allocator, 8);
    defer world.deinit();
    defer hierarchy.clear(HierarchyWorld, testing.allocator, &world);
    const a = try world.create();
    const b = try world.create();
    try world.add(hierarchy.Parent, a, .{ .entity = b });
    try world.add(hierarchy.Parent, b, .{ .entity = a });
    try testing.expectError(error.InvalidHierarchy, serialize(HierarchyStores, testing.allocator, &world, 2));
    _ = try world.remove(hierarchy.Parent, b);
    // Parent exists but the reciprocal Children list is missing.
    try testing.expectError(error.InvalidHierarchy, serialize(HierarchyStores, testing.allocator, &world, 2));
    try world.destroy(b);
    // The parent handle is now stale, even if its slot is later reused.
    const reused = try world.create();
    try testing.expectEqual(b.index, reused.index);
    try testing.expectError(error.InvalidHierarchy, serialize(HierarchyStores, testing.allocator, &world, 2));
}

test "hierarchy serializer cleans every allocation failure" {
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn probe(allocator: std.mem.Allocator) !void {
            var world = try HierarchyWorld.init(allocator, 8);
            defer world.deinit();
            defer hierarchy.clear(HierarchyWorld, allocator, &world);
            const parent = try world.create();
            const child = try world.create();
            try hierarchy.setParent(HierarchyWorld, allocator, &world, parent, child);
            try world.add(Position, child, .{ .x = 3, .y = -4 });
            const json = try serialize(HierarchyStores, allocator, &world, 4);
            defer allocator.free(json);
            var file = try format.parse(allocator, json);
            defer format.deinit(allocator, &file);
            try testing.expectEqual(@as(?u32, 0), file.entities[1].parent_index);
        }
    }.probe, .{});
}

test "ordinary stores named parent remain regular components" {
    const Plain = struct { x: i32 };
    const PlainStores = struct { parent: sparse_set.SparseSet(Plain) };
    const PlainWorld = world_mod.World(PlainStores);
    var world = try PlainWorld.init(testing.allocator, 4);
    defer world.deinit();
    const entity = try world.create();
    try world.add(Plain, entity, .{ .x = -42 });
    const json = try serialize(PlainStores, testing.allocator, &world, 1);
    defer testing.allocator.free(json);
    var file = try format.parse(testing.allocator, json);
    defer format.deinit(testing.allocator, &file);
    var loaded = try PlainWorld.init(testing.allocator, 4);
    defer loaded.deinit();
    try @import("content_loader.zig").load(PlainStores, &loaded, &file);
    try testing.expectEqual(@as(i32, -42), loaded.getConst(Plain, loaded.entityAt(0).?).?.x);
}

test "text, booleans and full-width integers round-trip safely" {
    const Data = struct { text: []const u8, enabled: bool, small: i32, large: u64 };
    const DataStores = struct { data: sparse_set.SparseSet(Data) };
    const DataWorld = world_mod.World(DataStores);
    var world = try DataWorld.init(testing.allocator, 4);
    defer world.deinit();
    const e = try world.create();
    try world.add(Data, e, .{ .text = "Olá\x00\n\\\"", .enabled = true, .small = std.math.minInt(i32), .large = std.math.maxInt(u64) });
    const json = try serialize(DataStores, testing.allocator, &world, 1);
    defer testing.allocator.free(json);
    var file = try format.parse(testing.allocator, json);
    defer format.deinit(testing.allocator, &file);
    var loaded = try DataWorld.init(testing.allocator, 4);
    defer loaded.deinit();
    try @import("content_loader.zig").load(DataStores, &loaded, &file);
    const actual = loaded.getConst(Data, loaded.entityAt(0).?).?;
    try testing.expectEqualStrings("Olá\x00\n\\\"", actual.text);
    try testing.expect(actual.enabled);
    try testing.expectEqual(std.math.minInt(i32), actual.small);
    try testing.expectEqual(std.math.maxInt(u64), actual.large);
}

test "unsupported components and invalid UTF-8 are reported explicitly" {
    const Nested = struct { inner: struct { x: i32 } };
    const Data = struct { text: []const u8 };
    const MixedStores = struct { nested: sparse_set.SparseSet(Nested), text: sparse_set.SparseSet(Data) };
    const MixedWorld = world_mod.World(MixedStores);
    var world = try MixedWorld.init(testing.allocator, 4);
    defer world.deinit();
    const e = try world.create();
    try world.add(Nested, e, .{ .inner = .{ .x = 1 } });
    try testing.expectError(error.UnsupportedComponentType, serialize(MixedStores, testing.allocator, &world, 1));
    _ = try world.remove(Nested, e);
    try world.add(Data, e, .{ .text = &.{0xff} });
    try testing.expectError(error.InvalidUtf8, serialize(MixedStores, testing.allocator, &world, 1));
}

test "serializer rejects duplicate child references" {
    var world = try HierarchyWorld.init(testing.allocator, 4);
    defer world.deinit();
    defer hierarchy.clear(HierarchyWorld, testing.allocator, &world);
    const parent = try world.create();
    const child = try world.create();
    try world.add(hierarchy.Parent, child, .{ .entity = parent });
    const list = try testing.allocator.dupe(@import("ecs/entity.zig").Entity, &.{ child, child });
    world.add(hierarchy.Children, parent, .{ .entities = list }) catch |err| {
        testing.allocator.free(list);
        return err;
    };
    try testing.expectError(error.InvalidHierarchy, serialize(HierarchyStores, testing.allocator, &world, 1));
}

test "shuffled forests round-trip canonically with gaps and sibling order" {
    var prng = std.Random.DefaultPrng.init(4155738);
    const random = prng.random();
    for (0..12) |_| {
        var source = try HierarchyWorld.init(testing.allocator, 64);
        defer source.deinit();
        defer hierarchy.clear(HierarchyWorld, testing.allocator, &source);
        var nodes: [64]@import("ecs/entity.zig").Entity = undefined;
        var order: [64]usize = undefined;
        var alive: usize = 0;
        for (&nodes, 0..) |*entity, index| {
            entity.* = try source.create();
            try source.add(Position, entity.*, .{ .x = @intCast(index), .y = 100 });
        }
        for (nodes, 0..) |entity, index| {
            if (index % 5 == 1) {
                try source.destroy(entity);
            } else {
                order[alive] = index;
                alive += 1;
            }
        }
        var i = alive;
        while (i > 1) {
            i -= 1;
            const j = random.uintLessThan(usize, i + 1);
            std.mem.swap(usize, &order[i], &order[j]);
        }
        for (order[1..alive], 1..) |child, position| {
            if (random.uintLessThan(u8, 4) == 0) continue;
            const parent = order[random.uintLessThan(usize, position)];
            try hierarchy.setParent(HierarchyWorld, testing.allocator, &source, nodes[parent], nodes[child]);
        }
        const json = try serialize(HierarchyStores, testing.allocator, &source, 4);
        defer testing.allocator.free(json);
        var file = try format.parse(testing.allocator, json);
        defer format.deinit(testing.allocator, &file);
        var target = try HierarchyWorld.init(testing.allocator, 64);
        defer target.deinit();
        defer hierarchy.clear(HierarchyWorld, testing.allocator, &target);
        try @import("content_loader.zig").load(HierarchyStores, &target, &file);
        const json_again = try serialize(HierarchyStores, testing.allocator, &target, 4);
        defer testing.allocator.free(json_again);
        try testing.expectEqualStrings(json, json_again);
        try testing.expectEqual(@as(u32, @intCast(alive)), target.aliveCount());
    }
}

test "flat descriptor output remains byte-compatible" {
    var world = try TestWorld.init(testing.allocator, 8);
    defer world.deinit();
    const entity = try world.create();
    try world.add(Position, entity, .{ .x = 1, .y = 2 });
    const json = try serialize(TestStores, testing.allocator, &world, 4);
    defer testing.allocator.free(json);
    try testing.expectEqualStrings("{\"entity_capacity\": 8, \"system_capacity\": 4, \"entities\": [{\"components\": [{\"kind\": \"position\", \"x\": 1, \"y\": 2}]}]}", json);
}

test "partial hierarchy stores never silently serialize links" {
    const ParentOnly = struct { up: sparse_set.SparseSet(hierarchy.Parent) };
    const ParentWorld = world_mod.World(ParentOnly);
    var parents = try ParentWorld.init(testing.allocator, 4);
    defer parents.deinit();
    const root = try parents.create();
    const child = try parents.create();
    const flat = try serialize(ParentOnly, testing.allocator, &parents, 0);
    defer testing.allocator.free(flat);
    try parents.add(hierarchy.Parent, child, .{ .entity = root });
    try testing.expectError(error.HierarchyUnsupported, serialize(ParentOnly, testing.allocator, &parents, 0));

    const ChildrenOnly = struct { down: sparse_set.SparseSet(hierarchy.Children) };
    const ChildrenWorld = world_mod.World(ChildrenOnly);
    var children = try ChildrenWorld.init(testing.allocator, 4);
    defer children.deinit();
    const only = try children.create();
    const list = try testing.allocator.alloc(@import("ecs/entity.zig").Entity, 0);
    defer testing.allocator.free(list);
    try children.add(hierarchy.Children, only, .{ .entities = list });
    try testing.expectError(error.HierarchyUnsupported, serialize(ChildrenOnly, testing.allocator, &children, 0));
}

const TransformCodecStores = struct {
    parent: sparse_set.SparseSet(hierarchy.Parent),
    children: sparse_set.SparseSet(hierarchy.Children),
    local_transform3d: sparse_set.SparseSet(transform3d.LocalTransform3D),
    world_transform3d: sparse_set.SparseSet(transform3d.WorldTransform3D),
    dirty: sparse_set.SparseSet(transform_dirty.TransformDirty),
};
const TransformCodecWorld = world_mod.World(TransformCodecStores);

test "3D authored serialization round-trips matrices and excludes computed state" {
    var world = try TransformCodecWorld.init(testing.allocator, 8);
    defer world.deinit();
    defer hierarchy.clear(TransformCodecWorld, testing.allocator, &world);
    const leaf = try world.create();
    const middle = try world.create();
    const root = try world.create();
    const sibling = try world.create();
    try world.add(transform3d.LocalTransform3D, root, .{ .matrix = .{ .m03 = 65536, .m11 = -65536, .m23 = std.math.minInt(i32) } });
    try world.add(transform3d.LocalTransform3D, leaf, .{ .matrix = .translation(131072, 0, 0) });
    try hierarchy.setParent(TransformCodecWorld, testing.allocator, &world, root, sibling);
    try hierarchy.setParent(TransformCodecWorld, testing.allocator, &world, root, middle);
    try hierarchy.setParent(TransformCodecWorld, testing.allocator, &world, middle, leaf);
    // Ordinary serialization supports authored locals when no computed state is
    // present; its previous rejection of nested derived components remains.
    const local_json = try serialize(TransformCodecStores, testing.allocator, &world, 4);
    defer testing.allocator.free(local_json);
    try transform_dirty.tryMarkDirty(TransformCodecWorld, &world, root);
    try transform_dirty.tryPropagateDirtyWithImplicitIdentity(TransformCodecWorld, &world);
    try transform_dirty.tryMarkDirty(TransformCodecWorld, &world, leaf);
    try testing.expectError(error.UnsupportedComponentType, serialize(TransformCodecStores, testing.allocator, &world, 4));

    const json = try serializeAuthored(TransformCodecStores, testing.allocator, &world, 4);
    defer testing.allocator.free(json);
    try testing.expectEqualStrings(local_json, json);
    try testing.expect(std.mem.indexOf(u8, json, "world_transform3d") == null);
    try testing.expect(std.mem.indexOf(u8, json, "dirty") == null);
    var file = try format.parse(testing.allocator, json);
    defer format.deinit(testing.allocator, &file);
    var loaded = try TransformCodecWorld.init(testing.allocator, 8);
    defer loaded.deinit();
    defer hierarchy.clear(TransformCodecWorld, testing.allocator, &loaded);
    try @import("content_loader.zig").load(TransformCodecStores, &loaded, &file);
    const loaded_leaf = loaded.entityAt(0).?;
    const loaded_middle = loaded.entityAt(1).?;
    const loaded_root = loaded.entityAt(2).?;
    const loaded_sibling = loaded.entityAt(3).?;
    try testing.expectEqualSlices(@import("ecs/entity.zig").Entity, &.{ loaded_sibling, loaded_middle }, hierarchy.getChildren(TransformCodecWorld, &loaded, loaded_root));
    try testing.expectEqual(loaded_middle, hierarchy.getParent(TransformCodecWorld, &loaded, loaded_leaf).?);
    try testing.expectEqualDeep(world.getConst(transform3d.LocalTransform3D, root).?.matrix, loaded.getConst(transform3d.LocalTransform3D, loaded_root).?.matrix);
    try testing.expectEqualDeep(world.getConst(transform3d.LocalTransform3D, leaf).?.matrix, loaded.getConst(transform3d.LocalTransform3D, loaded_leaf).?.matrix);
    try testing.expectEqual(@as(usize, 0), loaded.componentCount(transform3d.WorldTransform3D));
    try testing.expectEqual(@as(usize, 0), loaded.componentCount(transform_dirty.TransformDirty));
    try transform_dirty.tryMarkDirty(TransformCodecWorld, &loaded, loaded_root);
    try transform_dirty.tryPropagateDirtyWithImplicitIdentity(TransformCodecWorld, &loaded);
    try testing.expectEqualDeep(world.getConst(transform3d.WorldTransform3D, leaf).?.matrix, loaded.getConst(transform3d.WorldTransform3D, loaded_leaf).?.matrix);
}

test "3D authored serialization frees all resources on allocation failure" {
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn probe(allocator: std.mem.Allocator) !void {
            var world = try TransformCodecWorld.init(allocator, 4);
            defer world.deinit();
            defer hierarchy.clear(TransformCodecWorld, allocator, &world);
            const root = try world.create();
            const child = try world.create();
            try world.add(transform3d.LocalTransform3D, root, .{ .matrix = .translation(12, 0, 0) });
            try world.add(transform3d.LocalTransform3D, child, .{ .matrix = .translation(-2, 0, 0) });
            try hierarchy.setParent(TransformCodecWorld, allocator, &world, root, child);
            try transform_dirty.tryMarkDirty(TransformCodecWorld, &world, root);
            try transform_dirty.tryPropagateDirtyWithImplicitIdentity(TransformCodecWorld, &world);
            const json = try serializeAuthored(TransformCodecStores, allocator, &world, 4);
            defer allocator.free(json);
            var file = try format.parse(allocator, json);
            defer format.deinit(allocator, &file);
            try testing.expectEqual(@as(usize, 2), file.entities.len);
        }
    }.probe, .{});
}

test "authored filtering is explicit and legacy scalar dirty serialization is unchanged" {
    const DirtyStores = struct { dirty: sparse_set.SparseSet(transform_dirty.TransformDirty) };
    const DirtyWorld = world_mod.World(DirtyStores);
    var source = try DirtyWorld.init(testing.allocator, 4);
    defer source.deinit();
    const entity = try source.create();
    try source.add(transform_dirty.TransformDirty, entity, .{ .subtree_dirty = true });
    const legacy = try serialize(DirtyStores, testing.allocator, &source, 1);
    defer testing.allocator.free(legacy);
    var file = try format.parse(testing.allocator, legacy);
    defer format.deinit(testing.allocator, &file);
    var loaded = try DirtyWorld.init(testing.allocator, 4);
    defer loaded.deinit();
    try @import("content_loader.zig").load(DirtyStores, &loaded, &file);
    try testing.expect(loaded.getConst(transform_dirty.TransformDirty, loaded.entityAt(0).?).?.subtree_dirty);

    const authored = try serializeAuthored(DirtyStores, testing.allocator, &source, 1);
    defer testing.allocator.free(authored);
    try testing.expect(std.mem.indexOf(u8, authored, "dirty") == null);

    const Nested = struct { vector: struct { x: i32 } };
    const NestedStores = struct { nested: sparse_set.SparseSet(Nested) };
    const NestedWorld = world_mod.World(NestedStores);
    var nested = try NestedWorld.init(testing.allocator, 4);
    defer nested.deinit();
    const other = try nested.create();
    try nested.add(Nested, other, .{ .vector = .{ .x = 1 } });
    try testing.expectError(error.UnsupportedComponentType, serializeAuthored(NestedStores, testing.allocator, &nested, 1));
}
