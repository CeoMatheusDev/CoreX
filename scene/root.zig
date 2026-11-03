//! CoreX Scene: deterministic entities, sparse-set components, systems and the
//! Scene lifecycle. Pure Zig; the only dependency is `corex_core` for the
//! shared lifecycle and subsystem step contract.
pub const entity = @import("ecs/entity.zig");
pub const sparse_set = @import("ecs/sparse_set.zig");
pub const world = @import("ecs/world.zig");
pub const systems = @import("ecs/systems.zig");
pub const hierarchy = @import("ecs/hierarchy.zig");
pub const query = @import("ecs/query.zig");
pub const transform = @import("ecs/transform.zig");
pub const transform2d = @import("ecs/transform2d.zig");
pub const scene = @import("scene.zig");
pub const format = @import("format.zig");
pub const loader = @import("loader.zig");
pub const content_format = @import("content_format.zig");
pub const content_loader = @import("content_loader.zig");
pub const content_serializer = @import("content_serializer.zig");

pub const Entity = entity.Entity;
pub const EntityPool = entity.EntityPool;
pub const SparseSet = sparse_set.SparseSet;
pub const World = world.World;
pub const Systems = systems.Systems;
pub const Scene = scene.Scene;

/// Test-only allocator helpers; production code never needs this import.
pub const testing_allocator = @import("testing_allocator.zig");

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("ecs/entity.zig");
    _ = @import("ecs/sparse_set.zig");
    _ = @import("ecs/world.zig");
    _ = @import("ecs/systems.zig");
    _ = @import("ecs/hierarchy.zig");
    _ = @import("ecs/query.zig");
    _ = @import("ecs/transform.zig");
    _ = @import("ecs/transform2d.zig");
    _ = @import("scene.zig");
    _ = @import("content_format.zig");
    _ = @import("content_loader.zig");
    _ = @import("content_serializer.zig");
}
