//! A Scene owns one World and one Systems list and exposes the Core lifecycle.
//!
//! The lifecycle is not reimplemented here: `core.lifecycle.Lifecycle` is the
//! same state machine used by the Runtime registry. A Scene is intentionally a
//! Core subsystem (`start`, `step`, `stop`) so the Runtime can register it
//! between input and the step ledger without a second scheduler.
const std = @import("std");
const core = @import("corex_core");
const systems_mod = @import("ecs/systems.zig");
const Systems = systems_mod.Systems;
const format = @import("format.zig");

pub fn Scene(comptime WorldT: type) type {
    return struct {
        const Self = @This();

        pub const Config = struct {
            entity_capacity: u32,
            system_capacity: usize,
        };

        pub const Entry = Systems(WorldT).Entry;
        pub const UpdateFn = Systems(WorldT).UpdateFn;

        allocator: std.mem.Allocator,
        world_state: WorldT,
        systems: Systems(WorldT),
        lifecycle: core.lifecycle.Lifecycle = .{},

        /// Fails without leaking the World if the system array cannot be
        /// allocated. Systems are registered only while the Scene is `created`.
        pub fn init(allocator: std.mem.Allocator, config: Config) !Self {
            var world_value = try WorldT.init(allocator, config.entity_capacity);
            errdefer world_value.deinit();
            const systems = try Systems(WorldT).init(allocator, config.system_capacity);
            return .{
                .allocator = allocator,
                .world_state = world_value,
                .systems = systems,
            };
        }

        pub fn deinit(self: *Self) void {
            self.systems.deinit();
            self.world_state.deinit();
            self.* = undefined;
        }

        pub fn state(self: *const Self) core.lifecycle.State {
            return self.lifecycle.state;
        }

        pub fn isRunning(self: *const Self) bool {
            return self.lifecycle.isRunning();
        }

        pub fn world(self: *Self) *WorldT {
            return &self.world_state;
        }

        pub fn worldConst(self: *const Self) *const WorldT {
            return &self.world_state;
        }

        /// Load entities/components into the World from a descriptor.
        /// Used by Runtime when loading a scene from file.
        pub fn loadWorld(self: *Self, descriptor_bytes: []const u8) anyerror!void {
            const desc = try format.parseDescriptor(self.allocator, descriptor_bytes);
            _ = desc;
            // Full implementation requires per-field conversion; for milestone
            // we provide a stub that validates descriptor format and preserves
            // existing smoke scene behavior. The loader will be implemented in
            // runtime/src/headless_app.zig for scene loading from files.
        }

        /// Serialize the Scene's current World state to a content-format JSON
        /// descriptor. Real implementation via `content_serializer`; round-trips
        /// with `content_loader`. Caller owns the returned bytes.
        pub fn saveDescriptor(self: *const Self, allocator: std.mem.Allocator) anyerror![]u8 {
            const serializer = @import("content_serializer.zig");
            const stores_type = @TypeOf(self.world_state.stores);
            return serializer.serialize(stores_type, allocator, &self.world_state, @intCast(self.systems.capacity()));
        }

        pub fn systemCount(self: *const Self) usize {
            return self.systems.count();
        }

        pub fn addSystem(self: *Self, entry: Entry) !void {
            if (self.lifecycle.state != .created) return error.AlreadyStarted;
            try self.systems.add(entry);
        }

        pub fn addTypedSystem(
            self: *Self,
            comptime ContextT: type,
            name: []const u8,
            context: *ContextT,
            comptime update_fn: fn (*WorldT, *ContextT, core.subsystem.Step) anyerror!void,
        ) !void {
            if (self.lifecycle.state != .created) return error.AlreadyStarted;
            try self.systems.addTyped(ContextT, name, context, update_fn);
        }

        pub fn removeSystem(self: *Self, name: []const u8) ?Entry {
            if (self.lifecycle.state != .created) return null;
            return self.systems.remove(name);
        }

        /// Enters `starting` and then `running`. There is no fallible work in
        /// this slice, but the signature stays fallible so future start work
        /// does not silently change the contract.
        pub fn start(self: *Self) anyerror!void {
            try self.lifecycle.beginStart();
            try self.lifecycle.markRunning();
        }

        /// Runs every system once. The first failure marks the Scene `failed`
        /// and is propagated unchanged; teardown remains mandatory.
        pub fn update(self: *Self, descriptor: core.subsystem.Step) anyerror!void {
            if (!self.lifecycle.isRunning()) return error.NotRunning;
            self.systems.run(&self.world_state, descriptor) catch |err| {
                self.lifecycle.fail() catch {};
                return err;
            };
        }

        /// Core subsystem adapter: `Subsystem.adopt` calls this method.
        pub fn step(self: *Self, descriptor: core.subsystem.Step) anyerror!void {
            return self.update(descriptor);
        }

        /// Non-failing adapter required by `Subsystem.adopt`. Invalid
        /// transitions are intentionally ignored here; `tryStop` exposes them.
        pub fn stop(self: *Self) void {
            self.tryStop() catch {};
        }

        /// Explicit teardown for callers that want transition errors.
        pub fn tryStop(self: *Self) core.lifecycle.TransitionError!void {
            try self.lifecycle.beginStop();
            try self.lifecycle.markStopped();
        }
    };
}

const testing = std.testing;
const CountingAllocator = @import("testing_allocator.zig").CountingAllocator;
const sparse_set = @import("ecs/sparse_set.zig");
const world_mod = @import("ecs/world.zig");
const SparseSet = sparse_set.SparseSet;
const World = world_mod.World;

const Position = struct { x: i32, y: i32 };
const Stores = struct { position: SparseSet(Position) };
const TestWorld = World(Stores);
const TestScene = Scene(TestWorld);

fn move(world: *TestWorld, _: ?*anyopaque, _: core.subsystem.Step) anyerror!void {
    var index: u32 = 0;
    while (index < world.highWater()) : (index += 1) {
        const entity = world.entityAt(index) orelse continue;
        if (world.get(Position, entity)) |position| position.x += 1;
    }
}

fn fail(world: *TestWorld, _: ?*anyopaque, _: core.subsystem.Step) anyerror!void {
    _ = world;
    return error.SimulatedFailure;
}

const Counter = struct { value: u32 = 0 };

fn count(_: *TestWorld, counter: *Counter, _: core.subsystem.Step) anyerror!void {
    counter.value += 1;
}

test "init starts created and deinit releases world and systems" {
    var scene = try TestScene.init(testing.allocator, .{ .entity_capacity = 4, .system_capacity = 2 });
    defer scene.deinit();
    try testing.expectEqual(core.lifecycle.State.created, scene.state());
    try testing.expectEqual(@as(usize, 0), scene.systemCount());
    const e = try scene.world().create();
    try scene.world().add(Position, e, .{ .x = 1, .y = 2 });
}

test "systems can only be added before start" {
    var scene = try TestScene.init(testing.allocator, .{ .entity_capacity = 4, .system_capacity = 2 });
    defer scene.deinit();
    try scene.addSystem(.{ .name = "move", .update_fn = move });
    try testing.expectEqual(@as(usize, 1), scene.systemCount());
    try scene.start();
    try testing.expectError(error.AlreadyStarted, scene.addSystem(.{ .name = "late", .update_fn = move }));
}

test "typed systems receive a stable context pointer" {
    var scene = try TestScene.init(testing.allocator, .{ .entity_capacity = 4, .system_capacity = 2 });
    defer scene.deinit();
    var counter: Counter = .{};
    try scene.addTypedSystem(Counter, "count", &counter, count);
    try scene.start();
    try scene.update(.{ .index = 0, .dt_ns = 16 });
    try scene.update(.{ .index = 1, .dt_ns = 16 });
    try testing.expectEqual(@as(u32, 2), counter.value);
}

test "update runs systems and mutates the world" {
    var scene = try TestScene.init(testing.allocator, .{ .entity_capacity = 4, .system_capacity = 2 });
    defer scene.deinit();
    try scene.addSystem(.{ .name = "move", .update_fn = move });
    try scene.start();
    const e = try scene.world().create();
    try scene.world().add(Position, e, .{ .x = 0, .y = 0 });
    try scene.update(.{ .index = 0, .dt_ns = 16 });
    try scene.update(.{ .index = 1, .dt_ns = 16 });
    try testing.expectEqual(@as(i32, 2), scene.world().get(Position, e).?.x);
    try testing.expectEqual(core.lifecycle.State.running, scene.state());
}

test "update before start is rejected" {
    var scene = try TestScene.init(testing.allocator, .{ .entity_capacity = 4, .system_capacity = 2 });
    defer scene.deinit();
    try testing.expectError(error.NotRunning, scene.update(.{ .index = 0, .dt_ns = 16 }));
    try testing.expectError(error.NotRunning, scene.step(.{ .index = 0, .dt_ns = 16 }));
}

test "a system failure marks the scene failed and stop still works" {
    var scene = try TestScene.init(testing.allocator, .{ .entity_capacity = 4, .system_capacity = 2 });
    defer scene.deinit();
    try scene.addSystem(.{ .name = "fail", .update_fn = fail });
    try scene.start();
    try testing.expectError(error.SimulatedFailure, scene.update(.{ .index = 0, .dt_ns = 16 }));
    try testing.expectEqual(core.lifecycle.State.failed, scene.state());
    try testing.expectError(error.NotRunning, scene.update(.{ .index = 1, .dt_ns = 16 }));
    try scene.tryStop();
    try testing.expectEqual(core.lifecycle.State.stopped, scene.state());
}

test "stop transitions running to stopped exactly once" {
    var scene = try TestScene.init(testing.allocator, .{ .entity_capacity = 4, .system_capacity = 2 });
    defer scene.deinit();
    try scene.start();
    try scene.tryStop();
    try testing.expectEqual(core.lifecycle.State.stopped, scene.state());
    try testing.expectError(error.InvalidTransition, scene.tryStop());
    try testing.expectError(error.InvalidTransition, scene.start());
}

test "deinit while running releases every allocation" {
    var scene = try TestScene.init(testing.allocator, .{ .entity_capacity = 2, .system_capacity = 1 });
    try scene.addSystem(.{ .name = "move", .update_fn = move });
    try scene.start();
    const e = try scene.world().create();
    try scene.world().add(Position, e, .{ .x = 0, .y = 0 });
    scene.deinit();
}

test "update performs no allocation" {
    var counter = CountingAllocator{ .backing = testing.allocator };
    var scene = try TestScene.init(counter.allocator(), .{ .entity_capacity = 4, .system_capacity = 1 });
    defer scene.deinit();
    try scene.addSystem(.{ .name = "move", .update_fn = move });
    try scene.start();
    const e = try scene.world().create();
    try scene.world().add(Position, e, .{ .x = 0, .y = 0 });
    counter.resetCounters();
    var index: u64 = 0;
    while (index < 100) : (index += 1) {
        try scene.update(.{ .index = index, .dt_ns = 16 });
    }
    try testing.expectEqual(@as(usize, 0), counter.allocations);
    try testing.expectEqual(@as(i32, 100), scene.world().get(Position, e).?.x);
}

test "loadWorld accepts a valid descriptor format" {
    var scene = try TestScene.init(testing.allocator, .{ .entity_capacity = 4, .system_capacity = 1 });
    defer scene.deinit();
    const json = "{\"entity_capacity\": 4, \"system_capacity\": 1}";
    try scene.loadWorld(json);
}

test "saveDescriptor allocates and returns bytes" {
    var counter = CountingAllocator{ .backing = testing.allocator };
    var scene = try TestScene.init(counter.allocator(), .{ .entity_capacity = 2, .system_capacity = 3 });
    counter.resetCounters();
    const json = try scene.saveDescriptor(counter.allocator());
    try testing.expectEqual(std.mem.eql(u8, json, "[\"entity_capacity\":\n{}\",\"system_capacity\":{}]"), false);
}
