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

pub const SerializeError = error{OutOfMemory} || std.Io.Writer.Error;

/// Serializes the world into a JSON string allocated with `allocator`.
/// Caller owns the returned slice.
pub fn serialize(comptime StoresT: type, allocator: std.mem.Allocator, world: *const world_mod.World(StoresT), system_capacity: u32) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try writeWorld(StoresT, &aw.writer, world, system_capacity);
    return aw.toOwnedSlice();
}

fn writeWorld(comptime StoresT: type, w: anytype, world: *const world_mod.World(StoresT), system_capacity: u32) !void {
    try w.writeAll("{\"entity_capacity\": ");
    try w.print("{d}", .{world.entityCapacity()});
    try w.print(", \"system_capacity\": {d}, \"entities\": [", .{system_capacity});

    var first_entity = true;
    var index: u32 = 0;
    while (index < world.highWater()) : (index += 1) {
        const entity = world.entityAt(index) orelse continue;
        if (!first_entity) try w.writeAll(", ");
        first_entity = false;
        try w.writeAll("{\"components\": [");
        try writeComponents(StoresT, w, world, entity);
        try w.writeAll("]}");
    }
    try w.writeAll("]}");
}

fn writeComponents(comptime StoresT: type, w: anytype, world: *const world_mod.World(StoresT), entity: anytype) !void {
    const stores_info = @typeInfo(StoresT).@"struct";
    var first = true;
    inline for (stores_info.field_names, stores_info.field_types) |store_name, FieldType| {
        const Component = FieldType.Component;
        if (world.getConst(Component, entity)) |value| {
            if (!first) try w.writeAll(", ");
            first = false;
            try w.writeAll("{\"kind\": \"");
            try w.writeAll(store_name);
            try w.writeAll("\"");
            const comp_info = @typeInfo(Component).@"struct";
            inline for (comp_info.field_names, comp_info.field_types) |fname, ftype| {
                try w.writeAll(", \"");
                try w.writeAll(fname);
                try w.writeAll("\": ");
                try writeValue(w, ftype, @field(value, fname));
            }
            try w.writeAll("}");
        }
    }
}

fn writeValue(w: anytype, comptime T: type, value: T) !void {
    switch (T) {
        i64, u64, u32, i32, u8 => try w.print("{d}", .{value}),
        bool => try w.writeAll(if (value) "true" else "false"),
        []const u8 => {
            try w.writeAll("\"");
            for (value) |c| {
                switch (c) {
                    '"' => try w.writeAll("\\\""),
                    '\\' => try w.writeAll("\\\\"),
                    '\n' => try w.writeAll("\\n"),
                    '\r' => try w.writeAll("\\r"),
                    '\t' => try w.writeAll("\\t"),
                    else => try w.writeByte(c),
                }
            }
            try w.writeAll("\"");
        },
        else => @compileError("unsupported component field type for serialization: " ++ @typeName(T)),
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
