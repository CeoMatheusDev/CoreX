//! Content-scene file format: a minimal, deterministic JSON descriptor.
//!
//! This is the on-disk contract for a content scene (not the embedded smoke
//! scene). The format is intentionally small and explicit: capacities plus a
//! list of entities, each with named components. Parsing is strict — unknown
//! fields are rejected, numbers must be integers in range, and the document
//! must be a single JSON object. No asset references, no scripts, no GPU data.
const std = @import("std");

pub const max_entities: u32 = 65536;

pub const SceneFile = struct {
    entity_capacity: u32 = 8,
    system_capacity: u32 = 4,
    entities: []EntityData,
};

pub const EntityData = struct {
    name: ?[]const u8 = null,
    /// Parent position in `SceneFile.entities` (not a World's slot index).
    /// Null means root. Forward references are allowed.
    parent_index: ?u32 = null,
    /// Optional position within the parent's child list. If supplied for one
    /// sibling, it must be supplied for all siblings of that parent.
    sibling_index: ?u32 = null,
    components: []ComponentData,
};

pub const ComponentData = struct {
    kind: []const u8,
    fields: []FieldData,
};

pub const FieldData = struct {
    name: []const u8,
    value: Value,
};

pub const Value = union(enum) {
    integer: i64,
    unsigned: u64,
    boolean: bool,
    text: []const u8,
};

pub const ParseError = error{
    OutOfMemory,
    ParseError,
    InvalidSceneData,
    TooManyEntities,
    DuplicateComponent,
    UnknownField,
};

/// Strict JSON parser for the content-scene format. All strings are duped
/// into caller-owned memory; the caller must call `deinit` exactly once.
pub fn parse(allocator: std.mem.Allocator, bytes: []const u8) ParseError!SceneFile {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{ .allocate = .alloc_always }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.ParseError,
    };
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return error.InvalidSceneData;

    var file: SceneFile = .{ .entities = &.{} };
    errdefer freeSceneFile(allocator, &file);

    var iter = root.object.iterator();
    while (iter.next()) |entry| {
        const key = entry.key_ptr.*;
        const value = entry.value_ptr.*;
        if (std.mem.eql(u8, key, "entity_capacity")) {
            file.entity_capacity = try parseU32(value);
            if (file.entity_capacity == 0 or file.entity_capacity > max_entities) return error.InvalidSceneData;
        } else if (std.mem.eql(u8, key, "system_capacity")) {
            file.system_capacity = try parseU32(value);
        } else if (std.mem.eql(u8, key, "entities")) {
            if (value != .array) return error.InvalidSceneData;
            const items = value.array.items;
            if (items.len > max_entities) return error.TooManyEntities;
            const entities = try allocator.alloc(EntityData, items.len);
            errdefer allocator.free(entities);
            var filled: usize = 0;
            errdefer for (entities[0..filled]) |*e| freeEntity(allocator, e);
            for (items) |item| {
                entities[filled] = try parseEntity(allocator, item);
                filled += 1;
            }
            file.entities = entities;
        } else {
            return error.UnknownField;
        }
    }
    return file;
}

pub fn deinit(allocator: std.mem.Allocator, file: *SceneFile) void {
    freeSceneFile(allocator, file);
}

fn parseEntity(allocator: std.mem.Allocator, value: std.json.Value) ParseError!EntityData {
    if (value != .object) return error.InvalidSceneData;
    var entity: EntityData = .{ .components = &.{} };
    errdefer freeEntity(allocator, &entity);
    var components: std.ArrayList(ComponentData) = .empty;
    errdefer {
        for (components.items) |*component| freeComponent(allocator, component);
        components.deinit(allocator);
    }

    var iter = value.object.iterator();
    while (iter.next()) |entry| {
        const key = entry.key_ptr.*;
        const val = entry.value_ptr.*;
        if (std.mem.eql(u8, key, "name")) {
            if (val != .string) return error.InvalidSceneData;
            entity.name = try allocator.dupe(u8, val.string);
        } else if (std.mem.eql(u8, key, "parent_index")) {
            entity.parent_index = if (val == .null) null else try parseU32(val);
        } else if (std.mem.eql(u8, key, "sibling_index")) {
            entity.sibling_index = if (val == .null) null else try parseU32(val);
        } else if (std.mem.eql(u8, key, "components")) {
            if (val != .array) return error.InvalidSceneData;
            for (val.array.items) |comp| {
                var parsed_component = try parseComponent(allocator, comp);
                errdefer freeComponent(allocator, &parsed_component);
                try components.append(allocator, parsed_component);
            }
        } else {
            return error.UnknownField;
        }
    }
    entity.components = try components.toOwnedSlice(allocator);
    return entity;
}

fn parseComponent(allocator: std.mem.Allocator, value: std.json.Value) ParseError!ComponentData {
    if (value != .object) return error.InvalidSceneData;
    var comp: ComponentData = .{ .kind = "", .fields = &.{} };
    errdefer freeComponent(allocator, &comp);
    var fields: std.ArrayList(FieldData) = .empty;
    errdefer {
        for (fields.items) |*field| freeField(allocator, field);
        fields.deinit(allocator);
    }

    var iter = value.object.iterator();
    while (iter.next()) |entry| {
        const key = entry.key_ptr.*;
        const val = entry.value_ptr.*;
        if (std.mem.eql(u8, key, "kind")) {
            if (val != .string) return error.InvalidSceneData;
            comp.kind = try allocator.dupe(u8, val.string);
        } else {
            const name = try allocator.dupe(u8, key);
            errdefer allocator.free(name);
            const field_value = try parseValue(allocator, val);
            errdefer freeValue(allocator, field_value);
            try fields.append(allocator, .{ .name = name, .value = field_value });
        }
    }
    comp.fields = try fields.toOwnedSlice(allocator);
    return comp;
}

fn parseValue(allocator: std.mem.Allocator, value: std.json.Value) ParseError!Value {
    return switch (value) {
        .integer => |v| .{ .integer = v },
        .float => error.InvalidSceneData, // floats not allowed in scene format
        .string => |s| .{ .text = try allocator.dupe(u8, s) },
        .bool => |b| .{ .boolean = b },
        .number_string => |s| .{ .unsigned = std.fmt.parseInt(u64, s, 10) catch return error.InvalidSceneData },
        .null, .array, .object => error.InvalidSceneData,
    };
}

fn parseU32(value: std.json.Value) ParseError!u32 {
    if (value != .integer) return error.InvalidSceneData;
    const v = value.integer;
    if (v < 0 or v > std.math.maxInt(u32)) return error.InvalidSceneData;
    return @intCast(v);
}

fn freeSceneFile(allocator: std.mem.Allocator, file: *SceneFile) void {
    for (file.entities) |*e| freeEntity(allocator, e);
    allocator.free(file.entities);
    file.entities = &.{};
}

fn freeEntity(allocator: std.mem.Allocator, e: *EntityData) void {
    if (e.name) |n| allocator.free(n);
    for (e.components) |*c| freeComponent(allocator, c);
    allocator.free(e.components);
    e.components = &.{};
}

fn freeComponent(allocator: std.mem.Allocator, c: *ComponentData) void {
    allocator.free(c.kind);
    for (c.fields) |*f| freeField(allocator, f);
    allocator.free(c.fields);
    c.fields = &.{};
}

fn freeField(allocator: std.mem.Allocator, f: *FieldData) void {
    allocator.free(f.name);
    freeValue(allocator, f.value);
}

fn freeValue(allocator: std.mem.Allocator, value: Value) void {
    switch (value) {
        .text => |t| allocator.free(t),
        else => {},
    }
}

/// Generic scalar component support shared by loader and serializer. A
/// type-specific codec may additionally support a particular nested type;
/// arbitrary nested structs and pointer-bearing values other than borrowed
/// UTF-8 text remain unsupported.
pub fn supportsComponent(comptime T: type) bool {
    const info = @typeInfo(T);
    if (info != .@"struct") return false;
    inline for (info.@"struct".field_types) |Field| {
        if (Field == bool or Field == []const u8) continue;
        switch (@typeInfo(Field)) {
            .int => |integer| if (integer.bits > 64) return false,
            else => return false,
        }
    }
    return true;
}

const testing = std.testing;

test "parses a minimal valid scene file" {
    const json = "{\"entity_capacity\": 16, \"system_capacity\": 4, \"entities\": []}";
    var file = try parse(testing.allocator, json);
    defer deinit(testing.allocator, &file);
    try testing.expectEqual(@as(u32, 16), file.entity_capacity);
    try testing.expectEqual(@as(u32, 4), file.system_capacity);
    try testing.expectEqual(@as(usize, 0), file.entities.len);
}

test "parses entities with components and fields" {
    const json = "{\"entities\": [{\"name\": \"player\", \"components\": [{\"kind\": \"Position\", \"x\": 10, \"y\": 20}]}]}";
    var file = try parse(testing.allocator, json);
    defer deinit(testing.allocator, &file);
    try testing.expectEqual(@as(usize, 1), file.entities.len);
    try testing.expectEqualStrings("player", file.entities[0].name.?);
    try testing.expectEqual(@as(usize, 1), file.entities[0].components.len);
    try testing.expectEqualStrings("Position", file.entities[0].components[0].kind);
    try testing.expectEqual(@as(usize, 2), file.entities[0].components[0].fields.len);
}

test "rejects unknown top-level fields" {
    const json = "{\"unknown\": 1}";
    try testing.expectError(error.UnknownField, parse(testing.allocator, json));
}

test "rejects non-object root" {
    try testing.expectError(error.InvalidSceneData, parse(testing.allocator, "[1,2,3]"));
}

test "rejects zero entity capacity" {
    const json = "{\"entity_capacity\": 0}";
    try testing.expectError(error.InvalidSceneData, parse(testing.allocator, json));
}

test "rejects float values" {
    const json = "{\"entities\": [{\"components\": [{\"kind\": \"X\", \"v\": 1.5}]}]}";
    try testing.expectError(error.InvalidSceneData, parse(testing.allocator, json));
}

test "parent indices are optional file positions and the parser stays strict" {
    var file = try parse(testing.allocator,
        \\{"entities":[{"components":[]},{"parent_index":0,"components":[]},{"parent_index":null,"components":[]}]}
    );
    defer deinit(testing.allocator, &file);
    try testing.expectEqual(@as(?u32, null), file.entities[0].parent_index);
    try testing.expectEqual(@as(?u32, 0), file.entities[1].parent_index);
    try testing.expectEqual(@as(?u32, null), file.entities[2].parent_index);
    try testing.expectError(error.UnknownField, parse(testing.allocator, "{\"entities\":[{\"index\":0}]}"));
    try testing.expectError(error.InvalidSceneData, parse(testing.allocator, "{\"entities\":[{\"parent_index\":-1}]}"));
    try testing.expectError(error.InvalidSceneData, parse(testing.allocator, "{\"entities\":[{\"parent_index\":1.5}]}"));
    try testing.expectError(error.InvalidSceneData, parse(testing.allocator, "{\"entities\":[{\"parent_index\":4294967296}]}"));
}

test "parse cleans nested objects on invalid fields and allocation failure" {
    try testing.expectError(error.UnknownField, parse(testing.allocator,
        \\{"entities":[{"name":"child","components":[{"kind":"position","x":1},{"kind":"text","label":"yes"}],"bad":true}]}
    ));
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn probe(allocator: std.mem.Allocator) !void {
            var file = try parse(allocator,
                \\{"entities":[{"name":"parent","components":[{"kind":"position","x":1},{"kind":"text","label":"yes"}]},{"parent_index":0,"components":[]}]}
            );
            defer deinit(allocator, &file);
            try testing.expectEqual(@as(?u32, 0), file.entities[1].parent_index);
        }
    }.probe, .{});
}
