const std = @import("std");
const Engine = @import("../src/core/engine.zig").Engine;

test "Engine inicia e para corretamente" {
    const allocator = std.heap.page_allocator;
    var engine = try Engine.init(allocator);
    engine.start();
    try std.testing.expect(engine.running);
    engine.tick();
    engine.stop();
    try std.testing.expect(!engine.running);
}
