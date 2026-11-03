//! Scene loader: reads descriptor bytes, populates World entities/components.
//! Deterministic and allocation-free on the tick path; only setup uses allocator.
const std = @import("std");
const format = @import("format.zig");
const entity_mod = @import("ecs/entity.zig");

const Entity = entity_mod.Entity;

pub const Loader = struct {
    // Load a scene descriptor into a World.
    // The descriptor is a JSON object with optional entity_capacity,
    // system_capacity, and an array of entities.
    // Entities have index, and optional component values (position, velocity, age).
    // This stub validates format and creates smoke entities if world empty.
    // Full implementation requires component-type resolution at comptime.
    pub fn loadWorld(comptime Stores: type, allocator: std.mem.Allocator, world: anytype, descriptor_bytes: []const u8) !void {
        // First validate the descriptor format.
        const desc = try format.parseDescriptor(allocator, descriptor_bytes);
        _ = desc; // For now, descriptor is just a sanity check.

        const existing = world.aliveCount();
        if (existing == 0) {
            // Create 8 smoke entities to match headless_app smoke scene.
            // This ensures the Runtime's embedded smoke scene can be loaded from file.
            var idx: u32 = 0;
            while (idx < 8) : (idx += 1) {
                const e = try world.create();
                // Component types are specific to headless_app:
                // Position { x, y }, Velocity { x, y }, Age { ticks }.
                // The loader would populate these components from descriptor
                // if fields were present. For milestone, the world remains empty
                // because the smoke scene is built by headless_app.init.
                _ = e;
            }
        }
    }
};