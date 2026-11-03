//! Deterministic system list for one World type.
//!
//! Registration order is execution order. The array is allocated once at
//! `init`; `run` never allocates. Removing a system shifts the remaining
//! entries, which is acceptable because removal is setup-only. The first
//! failing system stops the pass and propagates its error unchanged.
const std = @import("std");
const core = @import("corex_core");

pub fn Systems(comptime WorldT: type) type {
    return struct {
        const Self = @This();

        pub const Step = core.subsystem.Step;
        pub const UpdateFn = *const fn (*WorldT, ?*anyopaque, Step) anyerror!void;

        pub const Entry = struct {
            name: []const u8,
            context: ?*anyopaque = null,
            update_fn: UpdateFn,
        };

        allocator: std.mem.Allocator,
        entries: []Entry,
        len: usize = 0,

        pub fn init(allocator: std.mem.Allocator, system_capacity: usize) !Self {
            return .{
                .allocator = allocator,
                .entries = try allocator.alloc(Entry, system_capacity),
            };
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.entries);
            self.* = undefined;
        }

        pub fn count(self: *const Self) usize {
            return self.len;
        }

        pub fn capacity(self: *const Self) usize {
            return self.entries.len;
        }

        pub fn entryAt(self: *const Self, index: usize) ?Entry {
            if (index >= self.len) return null;
            return self.entries[index];
        }

        pub fn add(self: *Self, entry: Entry) !void {
            if (entry.name.len == 0) return error.EmptyName;
            for (self.entries[0..self.len]) |existing| {
                if (std.mem.eql(u8, existing.name, entry.name)) return error.DuplicateName;
            }
            if (self.len == self.entries.len) return error.CapacityExceeded;
            self.entries[self.len] = entry;
            self.len += 1;
        }

        /// Type-safe convenience wrapper around `add`. The context pointer and
        /// the function stay valid for the list's lifetime; the list never
        /// copies the context value.
        pub fn addTyped(
            self: *Self,
            comptime ContextT: type,
            name: []const u8,
            context: *ContextT,
            comptime update: fn (*WorldT, *ContextT, Step) anyerror!void,
        ) !void {
            const Bridge = struct {
                fn call(world: *WorldT, opaque_context: ?*anyopaque, step: Step) anyerror!void {
                    const typed: *ContextT = @ptrCast(@alignCast(opaque_context.?));
                    return update(world, typed, step);
                }
            };
            try self.add(.{
                .name = name,
                .context = @ptrCast(context),
                .update_fn = Bridge.call,
            });
        }

        /// Removes by name and shifts the tail, preserving registration order.
        pub fn remove(self: *Self, name: []const u8) ?Entry {
            for (self.entries[0..self.len], 0..) |entry, index| {
                if (!std.mem.eql(u8, entry.name, name)) continue;
                const removed = entry;
                const remaining = self.len - index - 1;
                std.mem.copyForwards(Entry, self.entries[index..][0..remaining], self.entries[index + 1 .. self.len]);
                self.len -= 1;
                return removed;
            }
            return null;
        }

        pub fn run(self: *Self, world: *WorldT, step: Step) anyerror!void {
            for (self.entries[0..self.len]) |entry| {
                try entry.update_fn(world, entry.context, step);
            }
        }
    };
}

const testing = std.testing;
const CountingAllocator = @import("../testing_allocator.zig").CountingAllocator;

const TestWorld = struct { value: i32 = 0 };

fn addOne(world: *TestWorld, _: ?*anyopaque, _: core.subsystem.Step) anyerror!void {
    world.value += 1;
}

fn addTen(world: *TestWorld, context: ?*anyopaque, _: core.subsystem.Step) anyerror!void {
    const amount: *const i32 = @ptrCast(@alignCast(context.?));
    world.value += amount.*;
}

fn addTypedTen(world: *TestWorld, amount: *i32, _: core.subsystem.Step) anyerror!void {
    world.value += amount.*;
}

fn failAtThree(world: *TestWorld, _: ?*anyopaque, _: core.subsystem.Step) anyerror!void {
    world.value += 1;
    if (world.value == 3) return error.SimulatedFailure;
}

test "systems run in registration order" {
    var systems = try Systems(TestWorld).init(testing.allocator, 4);
    defer systems.deinit();
    try systems.add(.{ .name = "first", .update_fn = addOne });
    var ten: i32 = 10;
    try systems.add(.{ .name = "second", .context = @ptrCast(&ten), .update_fn = addTen });
    var world: TestWorld = .{};
    try systems.run(&world, .{ .index = 0, .dt_ns = 1 });
    try testing.expectEqual(@as(i32, 11), world.value);
    try testing.expectEqual(@as(usize, 2), systems.count());
}

test "typed systems receive their context" {
    var systems = try Systems(TestWorld).init(testing.allocator, 2);
    defer systems.deinit();
    var ten: i32 = 10;
    try systems.addTyped(i32, "typed", &ten, addTypedTen);
    var world: TestWorld = .{};
    try systems.run(&world, .{ .index = 0, .dt_ns = 1 });
    try testing.expectEqual(@as(i32, 10), world.value);
}

test "removal preserves the order of the remaining systems" {
    var systems = try Systems(TestWorld).init(testing.allocator, 4);
    defer systems.deinit();
    try systems.add(.{ .name = "a", .update_fn = addOne });
    try systems.add(.{ .name = "b", .update_fn = addOne });
    try systems.add(.{ .name = "c", .update_fn = addOne });
    const removed = systems.remove("b").?;
    try testing.expectEqualStrings("b", removed.name);
    try testing.expectEqualStrings("a", systems.entryAt(0).?.name);
    try testing.expectEqualStrings("c", systems.entryAt(1).?.name);
    try testing.expect(systems.remove("missing") == null);
    var world: TestWorld = .{};
    try systems.run(&world, .{ .index = 0, .dt_ns = 1 });
    try testing.expectEqual(@as(i32, 2), world.value);
}

test "duplicate names, empty names and capacity are rejected" {
    var systems = try Systems(TestWorld).init(testing.allocator, 1);
    defer systems.deinit();
    try systems.add(.{ .name = "only", .update_fn = addOne });
    try testing.expectError(error.DuplicateName, systems.add(.{ .name = "only", .update_fn = addOne }));
    try testing.expectError(error.EmptyName, systems.add(.{ .name = "", .update_fn = addOne }));
    try testing.expectError(error.CapacityExceeded, systems.add(.{ .name = "other", .update_fn = addOne }));
}

test "the first failing system stops the pass and propagates the error" {
    var systems = try Systems(TestWorld).init(testing.allocator, 3);
    defer systems.deinit();
    try systems.add(.{ .name = "one", .update_fn = addOne });
    try systems.add(.{ .name = "fail", .update_fn = failAtThree });
    try systems.add(.{ .name = "never", .update_fn = addTen });
    var world: TestWorld = .{ .value = 1 };
    try testing.expectError(error.SimulatedFailure, systems.run(&world, .{ .index = 0, .dt_ns = 1 }));
    try testing.expectEqual(@as(i32, 3), world.value);
}

test "run performs no allocation" {
    var counter = CountingAllocator{ .backing = testing.allocator };
    var systems = try Systems(TestWorld).init(counter.allocator(), 2);
    defer systems.deinit();
    try systems.add(.{ .name = "one", .update_fn = addOne });
    var world: TestWorld = .{};
    counter.allocations = 0;
    var index: u64 = 0;
    while (index < 100) : (index += 1) {
        try systems.run(&world, .{ .index = index, .dt_ns = 1 });
    }
    try testing.expectEqual(@as(usize, 0), counter.allocations);
    try testing.expectEqual(@as(i32, 100), world.value);
}

test "deinit releases the system array" {
    var systems = try Systems(TestWorld).init(testing.allocator, 3);
    try systems.add(.{ .name = "one", .update_fn = addOne });
    systems.deinit();
}
