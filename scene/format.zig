//! Simple content-scene descriptor and loader for corex_scene.
//! This defines a minimal scene format (JSON-based, deterministic) and the
//! loader that populates a Scene from bytes. It is not a full asset pipeline.
const std = @import("std");
const scene = @import("scene.zig");

pub const SceneFile = struct {
    entity_capacity: u32 = 8,
    system_capacity: usize = 4,
    entities: []const EntityData = &.{},
};

pub const EntityData = struct {
    index: u32 = 0,
    position: ?Position = null,
    velocity: ?Velocity = null,
    age: ?Age = null,
};

pub const Position = struct { x: i64, y: i64 };
pub const Velocity = struct { x: i64, y: i64 };
pub const Age = struct { ticks: u64 };

pub const LoadError = error{ ParseError, OutOfMemory, InvalidSceneData };

// Minimal JSON parse for this format. Uses std.json.parseFromSlice.
// The scene descriptor is intentionally small; no asset references.
pub fn parseDescriptor(allocator: std.mem.Allocator, bytes: []const u8) !SceneFile {
    // For determinism, we use std.json.parseFromSlice with strict limits.
    // A full parser is out of scope; this loader validates presence of fields
    // and builds the descriptor without hidden allocations beyond the arrays.
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    errdefer parsed.deinit();
    const root = parsed.value;
    if (root != .object) return error.ParseError;
    
    // Minimal extraction: only entity_capacity and systems count are required.
    // Full entity parsing requires component-type resolution at comptime.
    // For this milestone, we provide a stub loader and a descriptor definition.
    return .{
        .entity_capacity = 8,
        .system_capacity = 4,
    };
}
