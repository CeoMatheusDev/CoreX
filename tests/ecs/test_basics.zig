const std = @import("std");
const World = @import("../../src/ecs/ecs.zig").World;

pub fn main() !void {
    var world = World.init(std.heap.page_allocator);
    const e1 = world.createEntity();
    const e2 = world.createEntity();
    std.debug.assert(e1 == 1);
    std.debug.assert(e2 == 2);
    std.debug.print("ECS básico OK: entidades {d} e {d}\n", .{e1, e2});
}
