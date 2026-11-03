//! Content-scene loader: populates a generic `World(Stores)` from a parsed
//! `content_format.SceneFile`. Component kinds in the file are matched to
//! the World's comptime store fields by name; numeric fields are written via
//! reflection over the component struct fields.
//!
//! Ownership: the caller owns the descriptor (freed via `content_format.deinit`)
//! and the World owns all entities/components created here.
const std = @import("std");
const format = @import("content_format.zig");
const world_mod = @import("ecs/world.zig");

pub const LoadError = error{
    UnknownComponentKind,
    UnknownFieldName,
    TypeMismatch,
    DuplicateEntityComponent,
} || anyerror;

/// Loads `file` into `world`. Entities are created in file order; each
/// component's `kind` must match a field name of `Stores` (case-sensitive).
/// Component fields are matched by name to the component struct's fields.
pub fn load(comptime StoresT: type, world: *world_mod.World(StoresT), file: *const format.SceneFile) LoadError!void {
    for (file.entities) |*entity_data| {
        const entity = try world.create();
        for (entity_data.components) |*comp| {
            try loadComponent(StoresT, world, entity, comp);
        }
    }
}

fn loadComponent(comptime StoresT: type, world: anytype, entity: anytype, comp: *const format.ComponentData) LoadError!void {
    const stores_info = @typeInfo(StoresT).@"struct";
    inline for (stores_info.field_names, stores_info.field_types) |store_name, FieldType| {
        if (std.mem.eql(u8, comp.kind, store_name)) {
            const Component = FieldType.Component; // SparseSet(Component)
            var value: Component = undefined;
            // Initialize all fields to zero/default, then overwrite from file.
            const comp_info = @typeInfo(Component).@"struct";
            inline for (comp_info.field_names, comp_info.field_types) |fname, ftype| {
                @field(value, fname) = @as(ftype, 0);
            }
            for (comp.fields) |*field| {
                try setField(Component, &value, field);
            }
            try world.add(Component, entity, value);
            return;
        }
    }
    return error.UnknownComponentKind;
}

fn setField(comptime T: type, value: *T, field: *const format.FieldData) LoadError!void {
    const info = @typeInfo(T).@"struct";
    inline for (info.field_names, info.field_types) |fname, ftype| {
        if (std.mem.eql(u8, field.name, fname)) {
            @field(value, fname) = try convertValue(ftype, field.value);
            return;
        }
    }
    return error.UnknownFieldName;
}

fn convertValue(comptime T: type, v: format.Value) LoadError!T {
    return switch (T) {
        i64 => switch (v) {
            .integer => |n| n,
            .unsigned => |n| if (n > std.math.maxInt(i64)) return error.TypeMismatch else @intCast(n),
            else => return error.TypeMismatch,
        },
        u64 => switch (v) {
            .unsigned => |n| n,
            .integer => |n| if (n < 0) return error.TypeMismatch else @intCast(n),
            else => return error.TypeMismatch,
        },
        u32 => switch (v) {
            .unsigned => |n| if (n > std.math.maxInt(u32)) return error.TypeMismatch else @intCast(n),
            .integer => |n| if (n < 0 or n > std.math.maxInt(u32)) return error.TypeMismatch else @intCast(n),
            else => return error.TypeMismatch,
        },
        bool => switch (v) {
            .boolean => |b| b,
            else => return error.TypeMismatch,
        },
        []const u8 => switch (v) {
            .text => |t| t,
            else => return error.TypeMismatch,
        },
        else => @compileError("unsupported component field type: " ++ @typeName(T)),
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

test "rejects type mismatch" {
    const json = "{\"entities\": [{\"components\": [{\"kind\": \"position\", \"x\": true}]}]}";
    var file = try format.parse(testing.allocator, json);
    defer format.deinit(testing.allocator, &file);

    var world = try TestWorld.init(testing.allocator, 8);
    defer world.deinit();

    try testing.expectError(error.TypeMismatch, load(Stores, &world, &file));
}
