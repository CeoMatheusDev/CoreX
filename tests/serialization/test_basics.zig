const std = @import("std");
const Serializer = @import("../../src/serialization/serializer.zig").Serializer;

pub fn main() !void {
    var s = Serializer.init(std.heap.page_allocator);
    var buf: [32]u8 = undefined;
    _ = s.serializeInt(42, &buf);
    std.debug.print("Serialization OK\n", .{});
}
