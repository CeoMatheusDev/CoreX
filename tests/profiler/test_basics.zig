const std = @import("std");
const Profiler = @import("../../src/profiler/profiler.zig").Profiler;

pub fn main() !void {
    var p = Profiler.init();
    p.start();
    // simulação de código
    _ = p.stop();
    std.debug.print("Profiler OK\n", .{});
}
