//! Content-scene loader: populates a generic `World(Stores)` from a parsed
//! `content_format.SceneFile`. Component kinds in the file are matched to
//! the World's comptime store fields by name; numeric fields are written via
//! reflection over the component struct fields.
//!
//! Ownership: the caller owns the descriptor and the World owns its component
//! storage. Text component fields borrow descriptor strings; the descriptor
//! must outlive those fields. Children slices belong to the hierarchy caller
//! and must be released with hierarchy.clear before World.deinit.
const std = @import("std");
const format = @import("content_format.zig");
const world_mod = @import("ecs/world.zig");
const Entity = @import("ecs/entity.zig").Entity;
const hierarchy = @import("ecs/hierarchy.zig");

pub const LoadError = error{
    UnknownComponentKind,
    UnknownFieldName,
    TypeMismatch,
    DuplicateEntityComponent,
} || anyerror;

/// Loads entities in file order. `parent_index` refers to that order, not to
/// the World's reusable slot index. Existing entities are left untouched; on
/// error all entities created by this call and their hierarchy lists are freed.
/// A failed load can still grow capacity or advance generations/free-list order.
/// Text component fields borrow the descriptor and must not outlive it.
pub fn load(comptime StoresT: type, world: *world_mod.World(StoresT), file: *const format.SceneFile) LoadError!void {
    if (file.entities.len > format.max_entities) return error.TooManyEntities;
    var has_links = false;
    for (file.entities) |entity_data| {
        if (entity_data.parent_index != null) {
            has_links = true;
        } else if (entity_data.sibling_index != null) {
            return error.InvalidSiblingIndex;
        }
    }

    var parents: ?[]?u32 = null;
    defer if (parents) |indices| world.allocator.free(indices);
    if (has_links) {
        if (comptime !hierarchy.hasStore(StoresT, hierarchy.Parent) or !hierarchy.hasStore(StoresT, hierarchy.Children)) {
            return error.HierarchyUnsupported;
        }
        const indices = try world.allocator.alloc(?u32, file.entities.len);
        parents = indices;
        for (file.entities, 0..) |entity_data, i| indices[i] = entity_data.parent_index;
        try hierarchy.validateParentIndices(world.allocator, indices);
    }

    const created = try world.allocator.alloc(Entity, file.entities.len);
    defer world.allocator.free(created);
    var created_count: usize = 0;
    errdefer rollbackCreated(StoresT, world, created[0..created_count]);

    for (file.entities) |*entity_data| {
        const entity = try world.create();
        created[created_count] = entity;
        created_count += 1;
        for (entity_data.components) |*comp| try loadComponent(StoresT, world, entity, comp);
    }

    if (comptime hierarchy.hasStore(StoresT, hierarchy.Parent) and hierarchy.hasStore(StoresT, hierarchy.Children)) {
        if (parents) |indices| try attachParentLinks(StoresT, world, created, indices, file.entities);
    }
}

fn rollbackCreated(comptime StoresT: type, world: *world_mod.World(StoresT), created: []const Entity) void {
    if (comptime hierarchy.hasStore(StoresT, hierarchy.Children)) {
        for (created) |entity| {
            if (world.remove(hierarchy.Children, entity) catch unreachable) |children| {
                world.allocator.free(children.entities);
            }
        }
    }
    for (created) |entity| world.destroy(entity) catch unreachable;
}

/// Build the two hierarchy stores in bulk for newly-created, unique entities.
/// Counts and exact-size lists avoid repeated copying for wide hierarchies.
/// The caller rolls back all created entities if any insertion fails.
fn attachParentLinks(comptime StoresT: type, world: *world_mod.World(StoresT), created: []const Entity, parents: []const ?u32, entity_data: []const format.EntityData) !void {
    const allocator = world.allocator;
    const ParentInfo = struct { count: usize = 0, cursor: usize = 0, explicit_order: ?bool = null };
    const info = try allocator.alloc(ParentInfo, created.len);
    defer allocator.free(info);
    @memset(info, .{});
    for (parents, 0..) |parent, i| if (parent) |p| {
        info[p].count += 1;
        const explicit = entity_data[i].sibling_index != null;
        if (info[p].explicit_order) |previous| {
            if (previous != explicit) return error.InvalidSiblingIndex;
        } else {
            info[p].explicit_order = explicit;
        }
    };

    const lists = try allocator.alloc(?[]Entity, created.len);
    defer allocator.free(lists);
    @memset(lists, null);
    defer for (lists) |maybe_list| if (maybe_list) |list| {
        allocator.free(list);
    };
    const empty_slot = Entity{ .index = std.math.maxInt(u32), .generation = 0 };
    for (info, 0..) |parent_info, i| {
        if (parent_info.count != 0) {
            lists[i] = try allocator.alloc(Entity, parent_info.count);
            @memset(lists[i].?, empty_slot);
        }
    }
    for (parents, 0..) |parent, i| if (parent) |p| {
        const sibling: usize = if (entity_data[i].sibling_index) |order| order else blk: {
            const order = info[p].cursor;
            info[p].cursor += 1;
            break :blk order;
        };
        const list = lists[p].?;
        if (sibling >= list.len or list[sibling].index != empty_slot.index) return error.InvalidSiblingIndex;
        list[sibling] = created[i];
    };

    for (lists, 0..) |*entry, i| {
        if (entry.*) |list| {
            try world.add(hierarchy.Children, created[i], .{ .entities = list });
            entry.* = null; // ownership transferred to the hierarchy
        }
    }
    for (parents, 0..) |parent, i| if (parent) |p| {
        try world.add(hierarchy.Parent, created[i], .{ .entity = created[p] });
    };
}

fn loadComponent(comptime StoresT: type, world: *world_mod.World(StoresT), entity: Entity, comp: *const format.ComponentData) LoadError!void {
    const stores_info = @typeInfo(StoresT).@"struct";
    inline for (stores_info.field_names, stores_info.field_types) |store_name, FieldType| {
        const Component = FieldType.Component;
        if (std.mem.eql(u8, comp.kind, store_name)) {
            if (comptime Component == hierarchy.Parent or Component == hierarchy.Children) {
                // These are derived solely from parent_index, never raw handles.
                return error.InvalidHierarchyComponent;
            } else if (comptime !format.supportsComponent(Component)) {
                return error.UnsupportedComponentType;
            } else {
                if (world.has(Component, entity)) return error.DuplicateEntityComponent;
                var value: Component = undefined;
                inline for (@typeInfo(Component).@"struct".field_names, @typeInfo(Component).@"struct".field_types) |fname, Field| {
                    if (Field == []const u8) {
                        @field(value, fname) = "";
                    } else if (Field == bool) {
                        @field(value, fname) = false;
                    } else {
                        @field(value, fname) = 0;
                    }
                }
                for (comp.fields) |*field| try setField(Component, &value, field);
                try world.add(Component, entity, value);
                return;
            }
        }
    }
    return error.UnknownComponentKind;
}

fn setField(comptime T: type, value: *T, field: *const format.FieldData) LoadError!void {
    const info = @typeInfo(T).@"struct";
    inline for (info.field_names, info.field_types) |fname, Field| {
        if (std.mem.eql(u8, field.name, fname)) {
            @field(value, fname) = try convertValue(Field, field.value);
            return;
        }
    }
    return error.UnknownFieldName;
}

fn convertValue(comptime T: type, v: format.Value) LoadError!T {
    if (T == bool) return switch (v) {
        .boolean => |b| b,
        else => error.TypeMismatch,
    };
    if (T == []const u8) return switch (v) {
        .text => |text| text,
        else => error.TypeMismatch,
    };
    return switch (@typeInfo(T)) {
        .int => switch (v) {
            .integer => |n| std.math.cast(T, n) orelse error.TypeMismatch,
            .unsigned => |n| std.math.cast(T, n) orelse error.TypeMismatch,
            else => error.TypeMismatch,
        },
        else => unreachable, // supportsComponent has already rejected this field
    };
}

const testing = std.testing;
const sparse_set = @import("ecs/sparse_set.zig");

const Position = struct { x: i64, y: i64 };
const Velocity = struct { x: i64, y: i64 };
const Age = struct { ticks: u64 };

const Stores = struct {
    position: sparse_set.SparseSet(Position),
    velocity: sparse_set.SparseSet(Velocity),
    age: sparse_set.SparseSet(Age),
};

const TestWorld = world_mod.World(Stores);

test "loads entities and components from a scene file" {
    const json = "{\"entity_capacity\": 8, \"entities\": [{\"name\": \"e0\", \"components\": [{\"kind\": \"position\", \"x\": 10, \"y\": 20}, {\"kind\": \"velocity\", \"x\": 1, \"y\": -1}]}, {\"name\": \"e1\", \"components\": [{\"kind\": \"age\", \"ticks\": 5}]}]}";
    var file = try format.parse(testing.allocator, json);
    defer format.deinit(testing.allocator, &file);

    var world = try TestWorld.init(testing.allocator, 8);
    defer world.deinit();

    try load(Stores, &world, &file);
    try testing.expectEqual(@as(u32, 2), world.aliveCount());

    const e0 = world.entityAt(0).?;
    const pos = world.getConst(Position, e0).?;
    try testing.expectEqual(@as(i64, 10), pos.x);
    try testing.expectEqual(@as(i64, 20), pos.y);
    const vel = world.getConst(Velocity, e0).?;
    try testing.expectEqual(@as(i64, 1), vel.x);
    try testing.expectEqual(@as(i64, -1), vel.y);

    const e1 = world.entityAt(1).?;
    const age = world.getConst(Age, e1).?;
    try testing.expectEqual(@as(u64, 5), age.ticks);
}

test "rejects unknown component kind" {
    const json = "{\"entities\": [{\"components\": [{\"kind\": \"unknown\", \"x\": 1}]}]}";
    var file = try format.parse(testing.allocator, json);
    defer format.deinit(testing.allocator, &file);

    var world = try TestWorld.init(testing.allocator, 8);
    defer world.deinit();

    try testing.expectError(error.UnknownComponentKind, load(Stores, &world, &file));
}

test "rejects unknown field name" {
    const json = "{\"entities\": [{\"components\": [{\"kind\": \"position\", \"z\": 1}]}]}";
    var file = try format.parse(testing.allocator, json);
    defer format.deinit(testing.allocator, &file);

    var world = try TestWorld.init(testing.allocator, 8);
    defer world.deinit();

    try testing.expectError(error.UnknownFieldName, load(Stores, &world, &file));
}

test "round-trip with hierarchy (parent_index)" {
    const json = "{\"entities\": [{\"components\": [{\"kind\": \"position\", \"x\": 1, \"y\": 2}]}, {\"parent_index\": 0, \"components\": [{\"kind\": \"position\", \"x\": 3, \"y\": 4}]}]}";
    var file = try format.parse(testing.allocator, json);
    defer format.deinit(testing.allocator, &file);

    const HierStores = struct {
        position: sparse_set.SparseSet(Position),
        parent: sparse_set.SparseSet(@import("ecs/hierarchy.zig").Parent),
        children: sparse_set.SparseSet(@import("ecs/hierarchy.zig").Children),
    };
    const HierWorld = world_mod.World(HierStores);
    var world = try HierWorld.init(testing.allocator, 8);
    defer world.deinit();
    defer hierarchy.clear(HierWorld, testing.allocator, &world);

    try load(HierStores, &world, &file);
    try testing.expectEqual(@as(u32, 2), world.aliveCount());

    const hierarchy_mod = @import("ecs/hierarchy.zig");
    const e0 = world.entityAt(0).?;
    const e1 = world.entityAt(1).?;
    try testing.expectEqual(e0, hierarchy_mod.getParent(HierWorld, &world, e1).?);
    try testing.expectEqual(@as(usize, 1), hierarchy_mod.getChildren(HierWorld, &world, e0).len);
}

test "rejects type mismatch" {
    const json = "{\"entities\": [{\"components\": [{\"kind\": \"position\", \"x\": true}]}]}";
    var file = try format.parse(testing.allocator, json);
    defer format.deinit(testing.allocator, &file);

    var world = try TestWorld.init(testing.allocator, 8);
    defer world.deinit();

    try testing.expectError(error.TypeMismatch, load(Stores, &world, &file));
}

const HierarchyStores = struct {
    position: sparse_set.SparseSet(Position),
    links_up: sparse_set.SparseSet(hierarchy.Parent),
    links_down: sparse_set.SparseSet(hierarchy.Children),
};
const HierarchyWorld = world_mod.World(HierarchyStores);

test "invalid parent references and cycles do not change an existing World" {
    const cases = [_]struct { json: []const u8, expected: anyerror }{
        .{ .json = "{\"entities\":[{\"parent_index\":1}]}", .expected = error.InvalidParentIndex },
        .{ .json = "{\"entities\":[{\"parent_index\":0}]}", .expected = error.CycleDetected },
        .{ .json = "{\"entities\":[{\"parent_index\":1},{\"parent_index\":0}]}", .expected = error.CycleDetected },
        .{ .json = "{\"entities\":[{\"parent_index\":2},{\"parent_index\":0},{\"parent_index\":1}]}", .expected = error.CycleDetected },
    };
    for (cases) |case| {
        var file = try format.parse(testing.allocator, case.json);
        defer format.deinit(testing.allocator, &file);
        var world = try HierarchyWorld.init(testing.allocator, 8);
        defer world.deinit();
        defer hierarchy.clear(HierarchyWorld, testing.allocator, &world);
        const existing = try world.create();
        try world.add(Position, existing, .{ .x = 77, .y = -5 });
        try testing.expectError(case.expected, load(HierarchyStores, &world, &file));
        try testing.expectEqual(@as(u32, 1), world.aliveCount());
        try testing.expectEqual(@as(i64, 77), world.getConst(Position, existing).?.x);
    }
}

test "hierarchy requires both component types and rejects raw handles" {
    var file = try format.parse(testing.allocator, "{\"entities\":[{}, {\"parent_index\":0}]}");
    defer format.deinit(testing.allocator, &file);
    var plain = try TestWorld.init(testing.allocator, 8);
    defer plain.deinit();
    try testing.expectError(error.HierarchyUnsupported, load(Stores, &plain, &file));
    try testing.expectEqual(@as(u32, 0), plain.aliveCount());

    const ParentOnly = struct { links_up: sparse_set.SparseSet(hierarchy.Parent) };
    var partial = try world_mod.World(ParentOnly).init(testing.allocator, 8);
    defer partial.deinit();
    try testing.expectError(error.HierarchyUnsupported, load(ParentOnly, &partial, &file));

    const ChildrenOnly = struct { links_down: sparse_set.SparseSet(hierarchy.Children) };
    var partial_children = try world_mod.World(ChildrenOnly).init(testing.allocator, 8);
    defer partial_children.deinit();
    try testing.expectError(error.HierarchyUnsupported, load(ChildrenOnly, &partial_children, &file));

    var raw = try format.parse(testing.allocator, "{\"entities\":[{\"components\":[{\"kind\":\"links_up\"}]}]}");
    defer format.deinit(testing.allocator, &raw);
    var world = try HierarchyWorld.init(testing.allocator, 8);
    defer world.deinit();
    defer hierarchy.clear(HierarchyWorld, testing.allocator, &world);
    try testing.expectError(error.InvalidHierarchyComponent, load(HierarchyStores, &world, &raw));
    try testing.expectEqual(@as(u32, 0), world.aliveCount());
}

test "component failure rolls back new entities and preserves existing data" {
    var file = try format.parse(testing.allocator,
        \\{"entities":[{"components":[{"kind":"position","x":5}]},{"parent_index":0,"components":[{"kind":"position","bad":3}]}]}
    );
    defer format.deinit(testing.allocator, &file);
    var world = try HierarchyWorld.init(testing.allocator, 8);
    defer world.deinit();
    defer hierarchy.clear(HierarchyWorld, testing.allocator, &world);
    const root = try world.create();
    const child = try world.create();
    try world.add(Position, root, .{ .x = 123, .y = 4 });
    try hierarchy.setParent(HierarchyWorld, testing.allocator, &world, root, child);
    try testing.expectError(error.UnknownFieldName, load(HierarchyStores, &world, &file));
    try testing.expectEqual(@as(u32, 2), world.aliveCount());
    try testing.expectEqual(root, hierarchy.getParent(HierarchyWorld, &world, child).?);
    try testing.expectEqual(@as(i64, 123), world.getConst(Position, root).?.x);
}

test "duplicate components are rejected without replacing the first" {
    var file = try format.parse(testing.allocator,
        \\{"entities":[{"components":[{"kind":"position","x":1},{"kind":"position","x":2}]}]}
    );
    defer format.deinit(testing.allocator, &file);
    var world = try TestWorld.init(testing.allocator, 8);
    defer world.deinit();
    try testing.expectError(error.DuplicateEntityComponent, load(Stores, &world, &file));
    try testing.expectEqual(@as(u32, 0), world.aliveCount());
}

test "hierarchy load rolls back on every allocation failure" {
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn probe(allocator: std.mem.Allocator) !void {
            var file = try format.parse(allocator,
                \\{"entities":[{"parent_index":2,"components":[{"kind":"position","x":1}]},{"parent_index":2},{"components":[]},{"parent_index":0}]}
            );
            defer format.deinit(allocator, &file);
            var world = try HierarchyWorld.init(allocator, 8);
            defer world.deinit();
            defer hierarchy.clear(HierarchyWorld, allocator, &world);
            const root = try world.create();
            const existing = try world.create();
            try hierarchy.setParent(HierarchyWorld, allocator, &world, root, existing);
            load(HierarchyStores, &world, &file) catch |err| {
                try testing.expectEqual(@as(u32, 2), world.aliveCount());
                try testing.expectEqual(root, hierarchy.getParent(HierarchyWorld, &world, existing).?);
                try testing.expectEqual(@as(usize, 1), hierarchy.getChildren(HierarchyWorld, &world, root).len);
                return err;
            };
            try testing.expectEqual(@as(u32, 6), world.aliveCount());
            const e0 = world.entityAt(2).?;
            const e1 = world.entityAt(3).?;
            const e2 = world.entityAt(4).?;
            const e3 = world.entityAt(5).?;
            try testing.expectEqual(e2, hierarchy.getParent(HierarchyWorld, &world, e0).?);
            try testing.expectEqual(e2, hierarchy.getParent(HierarchyWorld, &world, e1).?);
            try testing.expectEqual(e0, hierarchy.getParent(HierarchyWorld, &world, e3).?);
        }
    }.probe, .{});
}

test "wide hierarchy loading allocates child lists in bulk" {
    const count: usize = 2048;
    const entities = try testing.allocator.alloc(format.EntityData, count);
    defer testing.allocator.free(entities);
    for (entities, 0..) |*entity, i| {
        entity.* = .{ .parent_index = if (i == 0) null else 0, .components = &.{} };
    }
    const file: format.SceneFile = .{ .entity_capacity = count, .entities = entities };
    var counter = @import("testing_allocator.zig").CountingAllocator{ .backing = testing.allocator };
    var world = try HierarchyWorld.init(counter.allocator(), count);
    defer world.deinit();
    defer hierarchy.clear(HierarchyWorld, counter.allocator(), &world);
    counter.resetCounters();
    try load(HierarchyStores, &world, &file);
    try testing.expectEqual(count - 1, hierarchy.getChildren(HierarchyWorld, &world, world.entityAt(0).?).len);
    try testing.expect(counter.allocations < 128);
}

test "sibling order must be complete, unique, and in range" {
    const cases = [_][]const u8{
        "{\"entities\":[{\"sibling_index\":0}]}",
        "{\"entities\":[{},{\"parent_index\":0,\"sibling_index\":0},{\"parent_index\":0}]}",
        "{\"entities\":[{},{\"parent_index\":0,\"sibling_index\":0},{\"parent_index\":0,\"sibling_index\":0}]}",
        "{\"entities\":[{},{\"parent_index\":0,\"sibling_index\":2},{\"parent_index\":0,\"sibling_index\":0}]}",
    };
    for (cases) |json| {
        var file = try format.parse(testing.allocator, json);
        defer format.deinit(testing.allocator, &file);
        var world = try HierarchyWorld.init(testing.allocator, 8);
        defer world.deinit();
        defer hierarchy.clear(HierarchyWorld, testing.allocator, &world);
        const existing = try world.create();
        try testing.expectError(error.InvalidSiblingIndex, load(HierarchyStores, &world, &file));
        try testing.expectEqual(@as(u32, 1), world.aliveCount());
        try testing.expect(world.isAlive(existing));
    }
}

test "without sibling indices children follow file order" {
    var file = try format.parse(testing.allocator,
        \\{"entities":[{"parent_index":2},{"parent_index":2},{}]}
    );
    defer format.deinit(testing.allocator, &file);
    var world = try HierarchyWorld.init(testing.allocator, 8);
    defer world.deinit();
    defer hierarchy.clear(HierarchyWorld, testing.allocator, &world);
    try load(HierarchyStores, &world, &file);
    const children = hierarchy.getChildren(HierarchyWorld, &world, world.entityAt(2).?);
    try testing.expectEqual(@as(usize, 2), children.len);
    try testing.expectEqual(world.entityAt(0).?, children[0]);
    try testing.expectEqual(world.entityAt(1).?, children[1]);
}

test "primitive defaults and integer ranges are validated" {
    const Data = struct { label: []const u8, enabled: bool, n: i32, byte: u8 };
    const DataStores = struct { data: sparse_set.SparseSet(Data) };
    const DataWorld = world_mod.World(DataStores);
    var file = try format.parse(testing.allocator, "{\"entities\":[{\"components\":[{\"kind\":\"data\"}]}]}");
    defer format.deinit(testing.allocator, &file);
    var world = try DataWorld.init(testing.allocator, 4);
    defer world.deinit();
    try load(DataStores, &world, &file);
    const value = world.getConst(Data, world.entityAt(0).?).?;
    try testing.expectEqualStrings("", value.label);
    try testing.expect(!value.enabled);
    try testing.expectEqual(@as(i32, 0), value.n);
    try testing.expectEqual(@as(u8, 0), value.byte);
    var overflow = try format.parse(testing.allocator, "{\"entities\":[{\"components\":[{\"kind\":\"data\",\"byte\":256}]}]}");
    defer format.deinit(testing.allocator, &overflow);
    try testing.expectError(error.TypeMismatch, load(DataStores, &world, &overflow));
    try testing.expectEqual(@as(u32, 1), world.aliveCount());
}

test "non-scalar component fields fail cleanly rather than failing compilation" {
    const Nested = struct { inner: struct { x: i32 } };
    const NestedStores = struct { nested: sparse_set.SparseSet(Nested) };
    var file = try format.parse(testing.allocator, "{\"entities\":[{\"components\":[{\"kind\":\"nested\"}]}]}");
    defer format.deinit(testing.allocator, &file);
    var world = try world_mod.World(NestedStores).init(testing.allocator, 4);
    defer world.deinit();
    try testing.expectError(error.UnsupportedComponentType, load(NestedStores, &world, &file));
    try testing.expectEqual(@as(u32, 0), world.aliveCount());
}
