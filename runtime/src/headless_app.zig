//! Declared smoke scene for the headless executor.
//!
//! This is deliberately not gameplay: it is a tiny deterministic scene used to
//! prove that the Runtime drives real entities, components and systems through
//! the Core lifecycle. It has no assets, scripts, input, window or GPU. The
//! checksum covers entity handles and every component value in index order.
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
    return hash;
}

fn moveSystem(world: *World, _: ?*anyopaque, _: core.subsystem.Step) anyerror!void {
    var index: u32 = 0;
    while (index < world.highWater()) : (index += 1) {
        const entity = world.entityAt(index) orelse continue;
        const position = world.get(Position, entity) orelse continue;
        const velocity = world.get(Velocity, entity) orelse continue;
        position.x += velocity.x;
        position.y += velocity.y;
    }
}

fn ageSystem(world: *World, _: ?*anyopaque, _: core.subsystem.Step) anyerror!void {
    var index: u32 = 0;
    while (index < world.highWater()) : (index += 1) {
        const entity = world.entityAt(index) orelse continue;
        const age = world.get(Age, entity) orelse continue;
        age.ticks += 1;
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
